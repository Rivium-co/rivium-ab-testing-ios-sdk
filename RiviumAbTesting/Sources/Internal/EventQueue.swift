import Foundation

/// The events waiting to be sent. Kept on disk, at most `maxQueueSize` (the
/// oldest go first), and sent `ApiClient.maxEventsPerRequest` at a time by
/// one flush at a time.
///
/// An event stays in the queue until the service has answered for it, so a
/// crash or a failed request loses nothing and nothing is sent twice.
///
/// An event whose `variantId` is empty is parked: it was recorded before the
/// service could say which variant the user has (no user token yet). It is
/// not sent until `resolve` fills the variant in.
internal class EventQueue {
    static let maxQueueSize = 1000
    static let persistenceFileName = "rivium_ab_testing_pending_events.json"
    private static let maxBackoff: TimeInterval = 15 * 60
    private static let defaultRateLimitPause: TimeInterval = 60

    /// Sends one chunk as `userId`. Nil: there is no user token to send it under, so wait.
    typealias Send = (_ userId: String, _ events: [TrackEvent], _ completion: @escaping (Result<Void, ApiFailure>?) -> Void) -> Void

    /// The current send interval; guarded by `lock`.
    private var flushInterval: TimeInterval
    /// The signed-in user; only their events may be sent.
    private let currentUserId: () -> String?
    private let send: Send
    private let fileURL: URL?
    private let legacyFileURL: URL?

    private var events: [TrackEvent] = []
    private var inFlight = Set<String>()
    private var isFlushing = false
    private var pausedUntil: TimeInterval = 0
    private var pausedForNetwork = false
    private var failures = 0
    private let lock = NSLock()
    private let disk = DispatchQueue(label: "co.rivium.abtesting.eventqueue")

    /// Where the queue is kept: Application Support, which the user does not
    /// see and iCloud Drive does not show (earlier versions used Documents).
    static var defaultFileURL: URL? {
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RiviumAbTesting", isDirectory: true)
            .appendingPathComponent(persistenceFileName)
    }

    /// Where versions up to 0.2.1 kept it.
    static var legacyFileURL: URL? {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(persistenceFileName)
    }

    init(
        flushInterval: TimeInterval,
        fileURL: URL? = EventQueue.defaultFileURL,
        legacyFileURL: URL? = EventQueue.legacyFileURL,
        currentUserId: @escaping () -> String?,
        send: @escaping Send
    ) {
        self.flushInterval = flushInterval
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.currentUserId = currentUserId
        self.send = send
    }

    /// Load what an earlier run left behind.
    func start() {
        migrateLegacyFile()
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return }
        guard let persisted = try? JSONDecoder().decode([TrackEvent].self, from: data) else {
            // Silently fail and clear corrupted data
            try? FileManager.default.removeItem(at: url)
            return
        }
        lock.lock()
        events.insert(contentsOf: persisted, at: 0)
        trim()
        lock.unlock()
    }

    /// One time: the queue file of versions up to 0.2.1 moves out of Documents.
    private func migrateLegacyFile() {
        let files = FileManager.default
        guard let old = legacyFileURL, let new = fileURL, old != new, files.fileExists(atPath: old.path) else { return }
        try? files.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !files.fileExists(atPath: new.path) {
            try? files.moveItem(at: old, to: new)
        }
        try? files.removeItem(at: old)
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    /// True while sending is paused: the service asked us to wait, or the last attempt failed.
    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince1970 < pausedUntil
    }

    /// Adds an event and returns how many are waiting now.
    @discardableResult
    func enqueue(_ event: TrackEvent) -> Int {
        lock.lock()
        events.append(event)
        trim()
        let count = events.count
        // Persist immediately to survive crashes
        persist()
        lock.unlock()
        return count
    }

    /// Sends what can be sent, one chunk after the other. Only one flush
    /// runs at a time, so an event is never in two requests.
    func flush() {
        lock.lock()
        guard !isFlushing else {
            lock.unlock()
            return
        }
        isFlushing = true
        lock.unlock()
        sendNextChunk()
    }

    private func sendNextChunk() {
        lock.lock()
        guard Date().timeIntervalSince1970 >= pausedUntil, let userId = currentUserId() else {
            isFlushing = false
            lock.unlock()
            return
        }
        // The service credits a request to the token's user, so another
        // user's leftover events can never go out under it.
        let before = events.count
        events.removeAll { $0.userId != userId }
        if events.count != before { persist() }

        let chunk = Array(events.lazy.filter { !$0.variantId.isEmpty }.prefix(ApiClient.maxEventsPerRequest))
        guard !chunk.isEmpty else {
            isFlushing = false
            lock.unlock()
            return
        }
        inFlight = Set(chunk.map { $0.clientEventId })
        lock.unlock()

        send(userId, chunk) { [weak self] result in
            guard let self = self else { return }
            self.lock.lock()
            self.inFlight = []
            var goOn = false
            switch result {
            case .none:
                // No user token: the events stay parked until there is one.
                break
            case .some(.success):
                self.remove(chunk)
                self.failures = 0
                goOn = true
            case .some(.failure(let failure)):
                if failure.status == nil || (failure.status ?? 0) >= 500 {
                    // No answer, or the service is in trouble: try later, a little later each time.
                    self.pause(self.backoff(), network: failure.status == nil)
                } else if failure.status == 429 {
                    // Rate limited: wait as long as the service asked.
                    self.pause(failure.retryAfter ?? Self.defaultRateLimitPause)
                } else if failure.status == 403, failure.code == "event_limit_reached" {
                    // The month's events are used up: nothing more until the next interval.
                    self.pause(self.flushInterval)
                } else if failure.status == 401 {
                    // The token: the SDK now waits for another one.
                } else {
                    // Anything else would be refused again: these events are lost.
                    self.remove(chunk)
                    Log.debug("Events discarded: \(failure.message)")
                    goOn = true
                }
            }
            if !goOn { self.isFlushing = false }
            self.lock.unlock()
            if goOn { self.sendNextChunk() }
        }
    }

    /// The send interval changed while the app runs.
    func setFlushInterval(_ seconds: TimeInterval) {
        lock.lock()
        flushInterval = seconds
        lock.unlock()
    }

    /// The network is back: a pause that was only about the network ends now.
    func networkAvailable() {
        lock.lock()
        if pausedForNetwork {
            pausedForNetwork = false
            pausedUntil = 0
        }
        lock.unlock()
    }

    /// Takes one user's events out of the queue when they leave. Returned
    /// are the ones that can still be sent under that user's own token:
    /// complete, and not already on their way.
    func detach(userId: String) -> [TrackEvent] {
        lock.lock()
        defer { lock.unlock() }
        let theirs = events.filter { $0.userId == userId }
        guard !theirs.isEmpty else { return [] }
        events.removeAll { $0.userId == userId }
        persist()
        return theirs.filter { !$0.variantId.isEmpty && !inFlight.contains($0.clientEventId) }
    }

    /// Drops every event that was not recorded for `userId`.
    func retainUser(_ userId: String) {
        lock.lock()
        let before = events.count
        events.removeAll { $0.userId != userId }
        if events.count != before { persist() }
        lock.unlock()
    }

    /// The experiments `userId` has parked events for.
    func parkedExperimentIds(userId: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(events.filter { $0.userId == userId && $0.variantId.isEmpty }.map { $0.experimentId })
    }

    /// The service said which variant `userId` has in an experiment: parked
    /// events get it and can be sent. With a nil `variantId` (the user is
    /// not in the experiment, or it is gone) they are dropped.
    func resolve(userId: String, experimentId: String, variantId: String?) {
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        events = events.compactMap { event in
            guard event.userId == userId, event.experimentId == experimentId, event.variantId.isEmpty else {
                return event
            }
            changed = true
            guard let variantId = variantId, !variantId.isEmpty else { return nil }
            return event.with(variantId: variantId)
        }
        if changed { persist() }
    }

    func clear() {
        lock.lock()
        events = []
        persist()
        lock.unlock()
    }

    /// Returns once everything written so far is on disk.
    func waitForDisk() {
        disk.sync {}
    }

    // MARK: - Call with the lock held

    private func remove(_ sent: [TrackEvent]) {
        let ids = Set(sent.map { $0.clientEventId })
        events.removeAll { ids.contains($0.clientEventId) }
        persist()
    }

    private func pause(_ seconds: TimeInterval, network: Bool = false) {
        pausedForNetwork = network
        pausedUntil = Date().timeIntervalSince1970 + seconds
    }

    private func backoff() -> TimeInterval {
        failures = min(failures + 1, 10)
        return min(max(flushInterval, 1) * pow(2, Double(failures)), Self.maxBackoff)
    }

    /// Keeps the newest `maxQueueSize`.
    private func trim() {
        let extra = events.count - Self.maxQueueSize
        if extra > 0 {
            events.removeFirst(extra)
            Log.debug("Event queue full - dropped the \(extra) oldest")
        }
    }

    private func persist() {
        guard let url = fileURL else { return }
        let snapshot = events
        disk.async {
            do {
                if snapshot.isEmpty {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
                }
            } catch {
                // Silently fail - we don't want to crash the app
            }
        }
    }
}
