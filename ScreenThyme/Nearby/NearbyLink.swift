import dnssd
import Foundation
import Network
import Observation
import ThymeCore

/// Talks to the family's phones nearby, with no internet (PLAN.md §17), over two routes at once:
/// - Wi-Fi: Bonjour on a shared network, or Apple's peer-to-peer Wi-Fi when there's none (Wi-Fi on, no network).
/// - Bluetooth: an L2CAP channel (`BluetoothRadio`), for when Wi-Fi is off.
/// Kid phones listen and advertise; parent phones find them and connect. A phone reachable both ways gets updates over
/// Wi-Fi only; the Bluetooth connection stays open in case Wi-Fi drops. Only while the app is open: iOS suspends it.
///
/// What goes over a connection is the owner's business (`AppModel+Nearby`); this class moves bundles and keeps
/// `LinkSession` (encryption, the hello exchange) and a `LinkSentFilter` per connection.
@MainActor @Observable
final class NearbyLink {
    struct Configuration: Equatable {
        var key: LinkKey
        var role: LinkRole
        /// A kid phone's kid: names its service.
        var kidID: UUID?
        var name: String
    }

    enum Route: String {
        case wifi = "Wi-Fi"
        case bluetooth = "Bluetooth"
    }

    struct Peer: Identifiable {
        let id: ObjectIdentifier
        var hello: LinkHello
        var route: Route
        var connectedAt: Date
        var lastReceivedAt: Date
    }

    enum Status: Equatable {
        case off
        case looking
        case denied
        case failed(String)
    }

    static let serviceType = "_screenthyme._tcp"

    /// Connections whose phone proved it has the family secret; one phone can appear once per route.
    private(set) var peers: [Peer] = []
    /// The Wi-Fi route's state.
    private(set) var status = Status.off
    /// Why the Bluetooth route isn't working, when it isn't.
    private(set) var bluetoothProblem: String?

    /// What to send a peer now; the link drops what it already sent on that connection.
    @ObservationIgnored var bundleFor: (LinkHello) -> LinkBundle = { _ in LinkBundle() }
    @ObservationIgnored var received: (LinkBundle, LinkHello) -> Void = { _, _ in }

    @ObservationIgnored private(set) var configuration: Configuration?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var found: [NWEndpoint: NWBrowser.Result] = [:]
    @ObservationIgnored private var bluetooth: BluetoothRadio?
    @ObservationIgnored private var connections: [ObjectIdentifier: Connection] = [:]
    @ObservationIgnored private var diagnostics: [String] = []

    var isRunning: Bool { configuration != nil }

    func isConnected(kid: UUID) -> Bool {
        peers.contains { $0.hello.kidID == kid }
    }

    /// Starts or restarts for this configuration; if it's already running with it, only replaces a failed Wi-Fi side.
    func start(_ configuration: Configuration) {
        guard configuration != self.configuration else { return restartFailedWiFi() }
        stop()
        self.configuration = configuration
        status = .looking
        log("start \(configuration.role.rawValue) family \(configuration.key.familyTag)"
            + (configuration.kidID.map { ", service \(configuration.key.serviceName(kid: $0))" } ?? ""))
        switch configuration.role {
        case .kid: listen(configuration)
        case .parent: browse(configuration)
        }
        bluetooth = BluetoothRadio(link: self, configuration: configuration)
    }

    func stop() {
        if configuration != nil { log("stop") }
        listener?.cancel()
        browser?.cancel()
        bluetooth?.stop()
        listener = nil
        browser = nil
        bluetooth = nil
        found = [:]
        for connection in connections.values { connection.transport.cancel() }
        connections = [:]
        peers = []
        configuration = nil
        status = .off
        bluetoothProblem = nil
    }

    /// Sends every connected phone what changed since its last bundle; parents also re-dial phones they lost.
    func sendUpdates() {
        for connection in connections.values where connection.session.isReady && isPreferred(connection) {
            send(bundleFor(connection.session.peer!), on: connection)
        }
        restartFailedWiFi()
        if let configuration, configuration.role == .parent {
            for (endpoint, _) in found where !isDialing(endpoint) {
                dial(endpoint, configuration)
            }
        }
        bluetooth?.retry()
    }

    /// Sends parent-control messages now, on the connection that carries updates, to each phone `to` accepts.
    func send(_ unlock: [LinkUnlock], to accepts: (LinkHello) -> Bool) {
        var bundle = LinkBundle()
        bundle.unlock = unlock
        send(bundle, to: accepts)
    }

    private func send(_ bundle: LinkBundle, to accepts: (LinkHello) -> Bool) {
        for connection in connections.values where connection.session.isReady && isPreferred(connection) {
            if let peer = connection.session.peer, accepts(peer) { send(bundle, on: connection) }
        }
    }

    /// A failed listener or browser stays failed: after a suspension iOS can drop its connection to the Bonjour daemon
    /// (`DefunctConnection`). Its state handler dropped it; make a new one.
    private func restartFailedWiFi() {
        guard let configuration, listener == nil, browser == nil else { return }
        log("restart Wi-Fi")
        switch configuration.role {
        case .kid: listen(configuration)
        case .parent: browse(configuration)
        }
    }

    // MARK: - Wi-Fi, kid: listen

    private func listen(_ configuration: Configuration) {
        guard let kidID = configuration.kidID else { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: NetworkTransport.parameters())
        } catch {
            status = .failed("\(error)")
            log("listener: \(error)")
            return
        }
        listener.service = NWListener.Service(name: configuration.key.serviceName(kid: kidID), type: Self.serviceType,
                                              domain: nil, txtRecord: Self.txtRecord(configuration.key))
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.update(state)
                if case .failed = state, let listener, self.listener === listener {
                    listener.cancel()
                    self.listener = nil
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                self?.accept(NetworkTransport(connection, label: "incoming"), dialKey: nil, side: .listener)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func update(_ state: NWListener.State) {
        log("listener \(state)")
        switch state {
        case .ready: status = .looking
        case let .waiting(error), let .failed(error): status = Self.status(for: error)
        default: break
        }
        sawLocalNetwork(ready: state == .ready)
    }

    /// A ready listener or browser means Local Network is on; iOS's refusal shows as `Status.denied`.
    private func sawLocalNetwork(ready: Bool) {
        if ready { DevicePermissions.saw(localNetwork: .allowed) }
        if status == .denied { DevicePermissions.saw(localNetwork: .denied) }
    }

    // MARK: - Wi-Fi, parent: find kid phones and dial

    private func browse(_ configuration: Configuration) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
                                using: NetworkTransport.parameters())
        let tag = configuration.key.familyTag
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("browser \(state)")
                switch state {
                case .ready: self.status = .looking
                case let .waiting(error): self.status = Self.status(for: error)
                case let .failed(error):
                    self.status = Self.status(for: error)
                    if let browser, self.browser === browser {
                        browser.cancel()
                        self.browser = nil
                    }
                default: break
                }
                self.sawLocalNetwork(ready: state == .ready)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, let configuration = self.configuration else { return }
                // Other families' services carry another tag (or none): skip them without connecting.
                let ours = results.filter {
                    if case let .bonjour(txt) = $0.metadata { return txt["f"] == tag }
                    return false
                }
                self.log("found \(results.count) services, \(ours.count) ours: " + results.map { "\($0.endpoint)" }.joined(separator: ", "))
                self.found = Dictionary(ours.map { ($0.endpoint, $0) }, uniquingKeysWith: { _, new in new })
                for endpoint in self.found.keys where !self.isDialing(endpoint) {
                    self.dial(endpoint, configuration)
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func dial(_ endpoint: NWEndpoint, _ configuration: Configuration) {
        let connection = NWConnection(to: endpoint, using: NetworkTransport.parameters())
        accept(NetworkTransport(connection, label: "\(endpoint)"), dialKey: endpoint, side: .dialer)
    }

    // MARK: - Connections, either route

    /// A new connection. `dialKey` names what a parent phone dialed (a Bonjour endpoint, a Bluetooth peripheral), so
    /// it isn't dialed twice.
    func accept(_ transport: any LinkTransport, dialKey: AnyHashable?, side: LinkSession.Side) {
        guard let configuration else {
            transport.cancel()
            return
        }
        let hello = LinkHello(role: configuration.role, kidID: configuration.kidID, name: configuration.name)
        let connection = Connection(transport: transport, dialKey: dialKey,
                                    session: LinkSession(key: configuration.key, side: side, hello: hello))
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        log("\(transport.route.rawValue) \(transport.label) opening")
        transport.onReady = { [weak self] in
            guard let self else { return }
            log("\(transport.route.rawValue) \(transport.label) ready")
            do {
                transport.send(try connection.session.start())
            } catch {
                close(id, "hello: \(error)")
            }
        }
        transport.onData = { [weak self] data in self?.receive(data, on: connection) }
        transport.onClose = { [weak self] reason in self?.close(id, reason) }
        transport.start()
    }

    func isDialing(_ key: AnyHashable) -> Bool {
        connections.values.contains { $0.dialKey == key }
    }

    func bluetoothChanged(_ problem: String?) {
        if problem != bluetoothProblem { log("bluetooth: \(problem ?? "on")") }
        bluetoothProblem = problem
    }

    private func receive(_ data: Data, on connection: Connection) {
        do {
            for event in try connection.session.receive(data) {
                handle(event, on: connection)
            }
        } catch {
            close(ObjectIdentifier(connection), "receive: \(error)")
        }
    }

    private func handle(_ event: LinkSession.Event, on connection: Connection) {
        let route = connection.transport.route
        switch event {
        case let .hello(peer):
            log("hello from \(peer.role.rawValue) \(peer.name) over \(route.rawValue)")
            // A bundle, even an empty one, is what proves this phone to the peer. Only the preferred route carries data.
            if isPreferred(connection) {
                send(bundleFor(peer), on: connection, evenIfEmpty: true)
            } else {
                send(LinkBundle(), on: connection, evenIfEmpty: true)
            }
        case let .bundle(bundle):
            guard let peer = connection.session.peer else { return }
            log("bundle from \(peer.name) over \(route.rawValue): \(bundle.count) records")
            let id = ObjectIdentifier(connection)
            if let index = peers.firstIndex(where: { $0.id == id }) {
                peers[index].lastReceivedAt = Date()
            } else {
                peers.append(Peer(id: id, hello: peer, route: route, connectedAt: Date(), lastReceivedAt: Date()))
            }
            if !bundle.isEmpty { received(bundle, peer) }
        }
    }

    /// Of the connections to one phone, the one that carries updates: Wi-Fi if there is one, else the oldest.
    private func isPreferred(_ connection: Connection) -> Bool {
        guard let peer = connection.session.peer else { return false }
        let phone = Self.phone(peer)
        let best = connections.values
            .filter { $0.session.peer.map(Self.phone) == phone }
            .min { ($0.transport.route == .wifi ? 0 : 1, $0.serial) < ($1.transport.route == .wifi ? 0 : 1, $1.serial) }
        return best === connection
    }

    /// A phone across connections and routes: a kid phone by its kid, a parent phone by its name.
    private static func phone(_ hello: LinkHello) -> String {
        "\(hello.role.rawValue).\(hello.kidID?.uuidString ?? hello.name)"
    }

    private func send(_ bundle: LinkBundle, on connection: Connection, evenIfEmpty: Bool = false) {
        let unsent = connection.filter.unsent(bundle)
        guard evenIfEmpty || !unsent.isEmpty else { return }
        do {
            let data = try connection.session.send(unsent)
            log("send \(unsent.count) records over \(connection.transport.route.rawValue), \(data.count) bytes")
            connection.transport.send(data)
        } catch {
            close(ObjectIdentifier(connection), "send: \(error)")
        }
    }

    private func close(_ id: ObjectIdentifier, _ reason: String) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        log("\(connection.transport.route.rawValue) \(connection.transport.label) closed: \(reason)")
        connection.transport.cancel()
        peers.removeAll { $0.id == id }
    }

    // MARK: - Diagnostics

    /// Development: the link's recent events in Application Support/nearby-diagnostics.txt, to pull off a phone with
    /// devicectl (`--domain-type appDataContainer`).
    func log(_ line: String) {
        diagnostics.append("\(Date().formatted(.iso8601)) \(line)")
        if diagnostics.count > 400 { diagnostics.removeFirst(diagnostics.count - 400) }
        let url = URL.applicationSupportDirectory.appending(path: "nearby-diagnostics.txt")
        try? diagnostics.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Setup

    private static func txtRecord(_ key: LinkKey) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["f"] = key.familyTag
        return txt
    }

    private static func status(for error: NWError) -> Status {
        if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) { return .denied }
        return .failed(error.localizedDescription)
    }
}

extension NearbyLink {
    /// For status rows: who's connected and how, or why nobody is.
    var summary: String {
        if !peers.isEmpty {
            let routes = Dictionary(grouping: peers, by: \.hello.name).mapValues { Set($0.map(\.route.rawValue)).sorted() }
            return routes.keys.sorted().map { "\($0) (\(routes[$0]!.joined(separator: ", ")))" }.joined(separator: ", ")
        }
        let wifi = switch status {
        case .off: "not set up: needs iCloud once"
        case .looking: "none"
        case .denied: "Local Network is off for ScreenThyme in Settings"
        case let .failed(reason): reason
        }
        guard status != .off, let bluetoothProblem else { return wifi }
        return "\(wifi); \(bluetoothProblem)"
    }
}

/// One connection's state. A class so the transport's callbacks and the link share it.
@MainActor
private final class Connection {
    private static var count = 0

    let transport: any LinkTransport
    /// What a parent phone dialed; nil for a connection a kid phone accepted.
    let dialKey: AnyHashable?
    /// Opening order, to prefer the older of two connections on one route.
    let serial: Int
    var session: LinkSession
    var filter = LinkSentFilter()

    init(transport: any LinkTransport, dialKey: AnyHashable?, session: LinkSession) {
        Self.count += 1
        self.transport = transport
        self.dialKey = dialKey
        self.serial = Self.count
        self.session = session
    }
}
