import Foundation

internal class EventQueue {
    private let apiClient: ApiClient
    private let flushInterval: TimeInterval
    private let maxQueueSize: Int
    /// The signed-in user; with a user token only their events may be sent.
    private let currentUserId: () -> String?

    private var events: [TrackEvent] = []
    private var flushTimer: Timer?
    private let queue = DispatchQueue(label: "co.rivium.abtesting.eventqueue")
    private let lock = NSLock()

    private static let persistenceFileName = "rivium_ab_testing_pending_events.json"

    init(
        apiClient: ApiClient,
        flushInterval: TimeInterval,
        maxQueueSize: Int,
        currentUserId: @escaping () -> String? = { nil }
    ) {
        self.apiClient = apiClient
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
        self.currentUserId = currentUserId
    }

    func start() {
        // Load persisted events on start
        loadPersistedEvents()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.flushTimer = Timer.scheduledTimer(
                withTimeInterval: self.flushInterval,
                repeats: true
            ) { [weak self] _ in
                self?.flush()
            }
        }
    }

    func stop() {
        flushTimer?.invalidate()
        flushTimer = nil
        // Persist events before stopping
        persistEvents()
        flush()
    }

    func enqueue(_ event: TrackEvent) {
        lock.lock()
        events.append(event)
        let shouldFlush = events.count >= maxQueueSize
        lock.unlock()

        // Persist immediately to survive crashes
        persistEvents()

        if shouldFlush {
            flush()
        }
    }

    func flush() {
        lock.lock()
        // With a user token the service credits every event in the batch to
        // the token's user, so another user's leftover events can't be sent
        // under it: they would be credited to the wrong person.
        if apiClient.usesUserToken {
            let userId = currentUserId()
            events.removeAll { $0.userId != userId }
        }
        guard !events.isEmpty else {
            lock.unlock()
            clearPersistedEvents()
            return
        }
        let toFlush = events
        events = []
        lock.unlock()

        // Clear persisted events since we're attempting to flush
        clearPersistedEvents()

        apiClient.trackEvents(toFlush) { [weak self] result in
            self?.handle(result, sent: toFlush, requeue: true)
        }
    }

    /// Takes one user's pending events out of the queue, before another user
    /// signs in, so they can be sent under that user's own token.
    func detach(userId: String) -> [TrackEvent] {
        lock.lock()
        let theirs = events.filter { $0.userId == userId }
        events.removeAll { $0.userId == userId }
        lock.unlock()
        persistEvents()
        return theirs
    }

    /// Sends events taken with `detach` under `token`. Whatever fails is
    /// dropped: after the switch there is no token left to send it under.
    func sendDetached(_ theirs: [TrackEvent], token: String?) {
        guard !theirs.isEmpty else { return }
        if apiClient.usesUserToken {
            guard let token = token else { return }
            apiClient.trackEvents(theirs, explicitToken: .some(token)) { [weak self] result in
                self?.handle(result, sent: theirs, requeue: false)
            }
        } else {
            apiClient.trackEvents(theirs) { [weak self] result in
                self?.handle(result, sent: theirs, requeue: true)
            }
        }
    }

    private func handle(_ result: Result<Void, RiviumAbTestingError>, sent: [TrackEvent], requeue: Bool) {
        guard case .failure(let error) = result, requeue else { return }
        // Retry only what can succeed later: no network, rate limited, a
        // server error, or no valid token yet (401). Any other 4xx (a bad
        // request, the monthly event limit) would fail again forever.
        if case .apiError(let code, _) = error, code != 401, code != 429, code > 0, code < 500 {
            return
        }
        lock.lock()
        events.insert(contentsOf: sent, at: 0)
        lock.unlock()
        persistEvents()
    }

    // MARK: - Persistence

    private var persistenceURL: URL? {
        guard let documentsDirectory = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return documentsDirectory.appendingPathComponent(Self.persistenceFileName)
    }

    private func persistEvents() {
        lock.lock()
        let currentEvents = events
        lock.unlock()

        guard !currentEvents.isEmpty, let url = persistenceURL else { return }

        queue.async {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(currentEvents)
                try data.write(to: url, options: .atomic)
            } catch {
                // Silently fail - we don't want to crash the app
            }
        }
    }

    private func loadPersistedEvents() {
        guard let url = persistenceURL else { return }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let persistedEvents = try decoder.decode([TrackEvent].self, from: data)

            if !persistedEvents.isEmpty {
                lock.lock()
                events.insert(contentsOf: persistedEvents, at: 0)
                lock.unlock()
            }
        } catch {
            // Silently fail and clear corrupted data
            clearPersistedEvents()
        }
    }

    private func clearPersistedEvents() {
        guard let url = persistenceURL else { return }

        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
