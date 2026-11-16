import Foundation
import Network

/// A byte stream to one phone nearby: Wi-Fi (`NetworkTransport`) or Bluetooth (`BluetoothTransport`). Callbacks
/// arrive on the main actor; `onClose` at most once, and not after `cancel()`.
@MainActor
protocol LinkTransport: AnyObject {
    var route: NearbyLink.Route { get }
    /// For diagnostics.
    var label: String { get }
    var onReady: () -> Void { get set }
    var onData: (Data) -> Void { get set }
    var onClose: (String) -> Void { get set }
    func start()
    func send(_ data: Data)
    func cancel()
}

/// The Wi-Fi route: a TCP connection found through Bonjour, on a shared network or peer-to-peer Wi-Fi.
@MainActor
final class NetworkTransport: LinkTransport {
    let route = NearbyLink.Route.wifi
    let label: String
    var onReady: () -> Void = {}
    var onData: (Data) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    private let connection: NWConnection
    private var closed = false

    init(_ connection: NWConnection, label: String) {
        self.connection = connection
        self.label = label
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onReady()
                    self.receive()
                case let .failed(error):
                    self.finish("\(error)")
                case .cancelled:
                    self.finish("cancelled")
                default:
                    // `.waiting` (no route yet, e.g. peer-to-peer Wi-Fi still coming up) retries by itself.
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let error else { return }
            MainActor.assumeIsolated { self?.finish("write: \(error)") }
        })
    }

    func cancel() {
        closed = true
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.onData(data) }
                if let error {
                    self.finish("\(error)")
                } else if isComplete {
                    self.finish("closed by the other phone")
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose(reason)
    }

    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        // Notices a phone that walked away within about half a minute.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}
