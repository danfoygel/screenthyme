import CryptoKit
import Foundation

/// One connection between two family phones, without the network: framing, the hello exchange and encryption
/// (PLAN.md §17). The app feeds it bytes from the socket and writes out what it returns.
///
/// Every frame is a 4-byte big-endian length and an AES-GCM box. Hellos are sealed with a key derived from the family
/// secret, so a phone outside the family can't read or send one. Later messages use keys derived from the secret and
/// both hellos' nonces, one per direction, with a counter as the GCM nonce: a frame recorded on an earlier connection,
/// replayed, reordered or reflected back to its sender fails to open.
public struct LinkSession: Sendable {
    /// The listener is the kid phone, the dialer a parent phone.
    public enum Side: String, Sendable {
        case listener, dialer
    }

    public enum Event: Sendable, Equatable {
        /// The peer's hello arrived: send a bundle now, even an empty one, so the peer can verify this phone.
        case hello(LinkHello)
        case bundle(LinkBundle)
    }

    public enum Failure: Error, Equatable {
        /// The frame didn't open: another family, a corrupted stream, or a replay.
        case notAuthentic
        case unsupportedVersion(Int)
        case frameTooLarge(Int)
        case notReady
    }

    /// Larger than a day of samples on a busy phone, compressed.
    public static let maxFrameLength = 32 << 20

    public let side: Side
    public let hello: LinkHello
    public private(set) var peer: LinkHello?
    private let key: LinkKey
    private var buffer = Data()
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(key: LinkKey, side: Side, hello: LinkHello) {
        self.key = key
        self.side = side
        self.hello = hello
    }

    public var isReady: Bool { sendKey != nil }

    /// A bundle from the peer opened. A hello alone could be a recording of an earlier connection's; only a phone
    /// with the family secret can seal a bundle for this connection's keys.
    public private(set) var isVerified = false

    /// This phone's hello, the first bytes to write.
    public func start() throws -> Data {
        let sealed = try AES.GCM.seal(try encode(hello), using: key.derived("hello"))
        return Self.frame(sealed.combined!)
    }

    /// Bytes read from the connection; returns what they completed. Throws when the connection should close.
    public mutating func receive(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard length <= Self.maxFrameLength else { throw Failure.frameTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            let payload = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            events.append(try open(payload))
        }
        return events
    }

    /// A bundle as bytes to write. Only once the peer's hello has arrived.
    public mutating func send(_ bundle: LinkBundle) throws -> Data {
        guard let sendKey else { throw Failure.notReady }
        let sealed = try AES.GCM.seal(try compress(encode(bundle)), using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return Self.frame(sealed.ciphertext + sealed.tag)
    }

    private mutating func open(_ payload: Data) throws -> Event {
        guard let receiveKey else {
            let peer: LinkHello
            do {
                let box = try AES.GCM.SealedBox(combined: payload)
                peer = try JSONDecoder.thyme.decode(LinkHello.self, from: AES.GCM.open(box, using: key.derived("hello")))
            } catch {
                throw Failure.notAuthentic
            }
            guard peer.version == LinkHello.currentVersion else { throw Failure.unsupportedVersion(peer.version) }
            // The same nonce back means our own hello reflected to us.
            guard peer.nonce != hello.nonce else { throw Failure.notAuthentic }
            self.peer = peer
            let (listener, dialer) = side == .listener ? (hello, peer) : (peer, hello)
            let salt = listener.nonce + dialer.nonce
            let outbound = key.derived("from-\(side.rawValue)", salt: salt)
            let inbound = key.derived("from-\(side == .listener ? Side.dialer.rawValue : Side.listener.rawValue)", salt: salt)
            sendKey = outbound
            self.receiveKey = inbound
            return .hello(peer)
        }
        let bundle: LinkBundle
        do {
            guard payload.count >= 16 else { throw Failure.notAuthentic }
            let box = try AES.GCM.SealedBox(nonce: Self.nonce(receiveCounter), ciphertext: payload.dropLast(16),
                                            tag: payload.suffix(16))
            bundle = try JSONDecoder.thyme.decode(LinkBundle.self, from: decompress(AES.GCM.open(box, using: receiveKey)))
        } catch {
            throw Failure.notAuthentic
        }
        receiveCounter += 1
        isVerified = true
        return .bundle(bundle)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.thyme.encode(value)
    }

    private func compress(_ data: Data) throws -> Data {
        try (data as NSData).compressed(using: .lzfse) as Data
    }

    private func decompress(_ data: Data) throws -> Data {
        try (data as NSData).decompressed(using: .lzfse) as Data
    }

    private static func nonce(_ counter: UInt64) -> AES.GCM.Nonce {
        try! AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + withUnsafeBytes(of: counter.bigEndian) { Data($0) })
    }

    private static func frame(_ payload: Data) -> Data {
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
    }
}
