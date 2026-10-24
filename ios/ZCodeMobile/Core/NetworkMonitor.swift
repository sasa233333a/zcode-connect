import Foundation
import Network

/// Bridges the system path monitor to the connection state machine. A regained
/// network cancels the remaining backoff and retries immediately instead of
/// waiting for the next scheduled attempt.
@MainActor
final class NetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "dev.paco.zcode.mobile.network")
    private(set) var isSatisfied = true
    var onAvailable: (() -> Void)?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasSatisfied = self.isSatisfied
                self.isSatisfied = satisfied
                if satisfied, !wasSatisfied { self.onAvailable?() }
            }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
