import CoreBluetooth
import Foundation
import ThymeCore

/// The nearby link's Bluetooth route (PLAN.md §16), for when Wi-Fi is off. A kid phone publishes an L2CAP channel and
/// advertises a service whose one characteristic holds the channel's number (PSM); a parent phone scans for that
/// service, reads the number and opens the channel, a plain byte stream. The service and characteristic ids are derived
/// from the family secret, so other families' phones never look for them. No Bluetooth pairing: `LinkSession`
/// encrypts and authenticates, as on Wi-Fi.
@MainActor
final class BluetoothRadio: NSObject {
    private weak var link: NearbyLink?
    private let serviceID: CBUUID
    private let channelID: CBUUID
    // Kid phone
    private var peripheralManager: CBPeripheralManager?
    private var psm: CBL2CAPPSM?
    // Parent phone
    private var centralManager: CBCentralManager?
    /// Kid phones being connected or connected, held so CoreBluetooth keeps them.
    private var peripherals: [UUID: CBPeripheral] = [:]

    init(link: NearbyLink, configuration: NearbyLink.Configuration) {
        self.link = link
        serviceID = CBUUID(nsuuid: configuration.key.bluetoothServiceID)
        channelID = CBUUID(nsuuid: configuration.key.bluetoothChannelID)
        super.init()
        // The first of these on a phone asks for Bluetooth access.
        switch configuration.role {
        case .kid: peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        case .parent: centralManager = CBCentralManager(delegate: self, queue: nil)
        }
    }

    func stop() {
        if let peripheralManager {
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
            if let psm { peripheralManager.unpublishL2CAPChannel(psm) }
            peripheralManager.delegate = nil
        }
        if let centralManager {
            centralManager.stopScan()
            for peripheral in peripherals.values { centralManager.cancelPeripheralConnection(peripheral) }
            centralManager.delegate = nil
        }
        peripherals = [:]
        peripheralManager = nil
        centralManager = nil
    }

    /// Parent phones: scans again, since a scan reports each kid phone only once.
    func retry() {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        centralManager.scanForPeripherals(withServices: [serviceID])
    }

    private func report(_ state: CBManagerState) {
        let problem: String? = switch state {
        case .poweredOff: "Bluetooth is off"
        case .unauthorized: "Bluetooth is off for ScreenThyme in Settings"
        case .unsupported: "no Bluetooth"
        default: nil
        }
        link?.bluetoothChanged(problem)
    }

    private func disconnect(_ peripheral: CBPeripheral, _ reason: String) {
        guard peripherals.removeValue(forKey: peripheral.identifier) != nil else { return }
        link?.log("Bluetooth \(peripheral.identifier.uuidString.prefix(8)): \(reason)")
        centralManager?.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - Kid phone: advertise and accept

extension BluetoothRadio: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        report(peripheral.state)
        guard peripheral.state == .poweredOn, psm == nil else { return }
        // Unencrypted at the Bluetooth level, which would need pairing; the link encrypts.
        peripheral.publishL2CAPChannel(withEncryption: false)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: (any Error)?) {
        if let error {
            link?.log("Bluetooth channel: \(error)")
            return
        }
        psm = PSM
        let characteristic = CBMutableCharacteristic(type: channelID, properties: [.read],
                                                     value: withUnsafeBytes(of: PSM.bigEndian) { Data($0) },
                                                     permissions: [.readable])
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [characteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        if let error {
            link?.log("Bluetooth service: \(error)")
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: (any Error)?) {
        link?.log(error.map { "Bluetooth advertising: \($0)" } ?? "Bluetooth advertising, channel \(psm ?? 0)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard let channel else {
            link?.log("Bluetooth incoming: \(error.map { "\($0)" } ?? "no channel")")
            return
        }
        link?.accept(BluetoothTransport(channel: channel, label: "incoming"), dialKey: nil, side: .listener)
    }
}

// MARK: - Parent phone: scan and connect

extension BluetoothRadio: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        report(central.state)
        if central.state == .poweredOn { central.scanForPeripherals(withServices: [serviceID]) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard peripherals[peripheral.identifier] == nil, link?.isDialing(peripheral.identifier) != true else { return }
        link?.log("Bluetooth found \(peripheral.identifier.uuidString.prefix(8)), signal \(RSSI) dBm")
        peripherals[peripheral.identifier] = peripheral
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        disconnect(peripheral, "connect failed: \(error.map { "\($0)" } ?? "?")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: (any Error)?) {
        // The channel's streams end too, which closes the connection.
        disconnect(peripheral, "disconnected")
    }
}

extension BluetoothRadio: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            return disconnect(peripheral, "no ScreenThyme service")
        }
        peripheral.discoverCharacteristics([channelID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == channelID }) else {
            return disconnect(peripheral, "no channel characteristic")
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        guard characteristic.uuid == channelID, let value = characteristic.value, value.count == 2 else {
            return disconnect(peripheral, "no channel number")
        }
        peripheral.openL2CAPChannel(value.reduce(0) { $0 << 8 | CBL2CAPPSM($1) })
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: (any Error)?) {
        guard let channel else {
            return disconnect(peripheral, "channel: \(error.map { "\($0)" } ?? "?")")
        }
        let transport = BluetoothTransport(channel: channel, label: String(peripheral.identifier.uuidString.prefix(8)))
        // When the link closes the connection, drop the Bluetooth connection too, so the next scan finds it again.
        transport.whenDone = { [weak self] in self?.disconnect(peripheral, "connection closed") }
        link?.accept(transport, dialKey: peripheral.identifier, side: .dialer)
    }
}

/// The Bluetooth route's byte stream: an L2CAP channel's input and output streams, on the main run loop.
@MainActor
final class BluetoothTransport: NSObject, LinkTransport {
    let route = NearbyLink.Route.bluetooth
    let label: String
    var onReady: () -> Void = {}
    var onData: (Data) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    /// Called once the streams are closed, either way.
    var whenDone: () -> Void = {}
    private let channel: CBL2CAPChannel
    private var pending = Data()
    private var closed = false

    init(channel: CBL2CAPChannel, label: String) {
        self.channel = channel
        self.label = label
    }

    private var streams: [Stream] { [channel.inputStream, channel.outputStream].compactMap { $0 } }

    func start() {
        for stream in streams {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .default)
            stream.open()
        }
        // The channel is already open; writes wait in `pending` until the stream has room.
        onReady()
    }

    func send(_ data: Data) {
        pending.append(data)
        flush()
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        teardown()
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        teardown()
        onClose(reason)
    }

    private func teardown() {
        for stream in streams {
            stream.delegate = nil
            stream.remove(from: .main, forMode: .default)
            stream.close()
        }
        pending = Data()
        whenDone()
    }

    private func flush() {
        guard !closed, let output = channel.outputStream else { return }
        while !pending.isEmpty, output.hasSpaceAvailable {
            let written = pending.withUnsafeBytes { output.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: $0.count) }
            if written < 0 { return finish("write: \(output.streamError.map { "\($0)" } ?? "failed")") }
            if written == 0 { return }
            pending = Data(pending.dropFirst(written))
        }
    }

    private func read() {
        guard let input = channel.inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !closed, input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count < 0 { return finish("read: \(input.streamError.map { "\($0)" } ?? "failed")") }
            if count == 0 { return }
            onData(Data(buffer[0..<count]))
        }
    }
}

extension BluetoothTransport: @preconcurrency StreamDelegate {
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable: read()
        case .hasSpaceAvailable: flush()
        case .errorOccurred: finish("\(aStream.streamError.map { "\($0)" } ?? "stream error")")
        case .endEncountered: finish("closed by the other phone")
        default: break
        }
    }
}
