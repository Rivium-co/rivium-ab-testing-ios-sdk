import Foundation

internal class EventQueue {
    private let apiClient: ApiClient
    private let flushInterval: TimeInterval
    private let maxQueueSize: Int

    private var events: [TrackEvent] = []
    private var flushTimer: Timer?
    private let queue = DispatchQueue(label: "co.rivium.abtesting.eventqueue")
    private let lock = NSLock()

    private static let persistenceFileName = "rivium_ab_testing_pending_events.json"

    init(apiClient: ApiClient, flushInterval: TimeInterval, maxQueueSize: Int) {
        self.apiClient = apiClient
        self.flushInterval = flushInterval
        self.maxQueueSize = maxQueueSize
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
        guard !events.isEmpty else {
            lock.unlock()
            return
        }
        let toFlush = events
        events = []
        lock.unlock()

        // Clear persisted events since we're attempting to flush
        clearPersistedEvents()

        apiClient.trackEvents(toFlush) { [weak self] result in
            if case .failure = result {
                // Re-add events if flush failed and persist them
                self?.lock.lock()
                self?.events.insert(contentsOf: toFlush, at: 0)
                self?.lock.unlock()
                self?.persistEvents()
            }
        }
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
