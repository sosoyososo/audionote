import Foundation
import Network

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "info.karsa.app.ios.audionote.networkmonitor")

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .unknown

    /// Called when connectivity transitions from disconnected → connected
    @MainActor
    var onStatusChange: ((_ isConnected: Bool) -> Void)?

    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown
    }

    private init() {
        monitor = NWPathMonitor()
        // Sync-init from current path to avoid race
        let currentPath = monitor.currentPath
        isConnected = currentPath.status == .satisfied
        updateConnectionType(from: currentPath)
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            let wasConnected = self.isConnected
            self.isConnected = path.status == .satisfied
            self.updateConnectionType(from: path)

            Logger.info("Network status: \(self.isConnected), type: \(self.connectionType)")

            // Fire callback on transition: disconnected → connected
            if !wasConnected && self.isConnected {
                Task { @MainActor in
                    self.onStatusChange?(true)
                }
            }
        }

        monitor.start(queue: queue)
    }

    func stopMonitoring() {
        monitor.cancel()
    }

    func checkConnectivity() -> Bool {
        isConnected
    }

    private func updateConnectionType(from path: NWPath) {
        if path.usesInterfaceType(.wifi) {
            connectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            connectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            connectionType = .ethernet
        } else {
            connectionType = .unknown
        }
    }
}
