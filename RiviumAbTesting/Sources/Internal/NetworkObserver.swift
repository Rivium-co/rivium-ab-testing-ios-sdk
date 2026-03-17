import Foundation
import Network

/// Observes network connectivity changes and triggers callbacks when network becomes available.
internal class NetworkObserver {
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "co.rivium.abtesting.networkobserver")
    private let onNetworkAvailable: () -> Void

    private var isMonitoring = false
    private var wasUnavailable = false

    init(onNetworkAvailable: @escaping () -> Void) {
        self.monitor = NWPathMonitor()
        self.onNetworkAvailable = onNetworkAvailable
    }

    /// Start observing network changes
    func start() {
        guard !isMonitoring else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            if path.status == .satisfied {
                // Only trigger if we were previously unavailable
                // This prevents triggering on initial startup
                if self.wasUnavailable {
                    self.wasUnavailable = false
                    DispatchQueue.main.async {
                        self.onNetworkAvailable()
                    }
                }
            } else {
                self.wasUnavailable = true
            }
        }

        monitor.start(queue: queue)
        isMonitoring = true
    }

    /// Stop observing network changes
    func stop() {
        guard isMonitoring else { return }

        monitor.cancel()
        isMonitoring = false
    }

    /// Check if network is currently available
    func isNetworkAvailable() -> Bool {
        return monitor.currentPath.status == .satisfied
    }
}
