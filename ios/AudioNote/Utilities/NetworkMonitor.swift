import Foundation
import Network

final class NetworkMonitor: @unchecked Sendable {
    static let shared = NetworkMonitor()

    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "info.karsa.app.ios.audionote.networkmonitor")

    private(set) var isConnected: Bool = true
    private(set) var connectionType: ConnectionType = .unknown

    enum ConnectionType {
        case wifi
        case cellular
        case ethernet
        case unknown
    }

    private init() {
        monitor = NWPathMonitor()
    }

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }

            self.isConnected = path.status == .satisfied

            if path.usesInterfaceType(.wifi) {
                self.connectionType = .wifi
            } else if path.usesInterfaceType(.cellular) {
                self.connectionType = .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                self.connectionType = .ethernet
            } else {
                self.connectionType = .unknown
            }

            Logger.info("Network status: \(self.isConnected), type: \(self.connectionType)")
        }

        monitor.start(queue: queue)
    }

    func stopMonitoring() {
        monitor.cancel()
    }

    /// Check network connectivity synchronously
    /// Returns true if network is available
    func checkConnectivity() -> Bool {
        return isConnected
    }
}
