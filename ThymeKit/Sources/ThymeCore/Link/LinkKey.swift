import CryptoKit
import Foundation

/// The family's secret for talking to its phones nearby, without the internet (PLAN.md §17). The family zone's owner
/// creates it once; it syncs as `LinkKey.<id>`, so every phone that joined the family has it and no other phone does.
public struct LinkKey: Codable, Sendable, Hashable, Identifiable {
    /// One per family zone, under a fixed name, so every phone can fetch it by name.
    public static let fixedID = Replay.stableUUID("link-key")

    public var id: UUID
    /// 32 random bytes. Only ever used through keys derived from it.
    public var secret: Data
    public var createdAt: Date

    public init(secret: Data, createdAt: Date) {
        self.id = Self.fixedID
        self.secret = secret
        self.createdAt = createdAt
    }

    public static func generate(now: Date = Date()) -> LinkKey {
        LinkKey(secret: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, createdAt: now)
    }

    /// Published in Bonjour TXT records, so phones skip other families' services without connecting.
    public var familyTag: String { tag("family") }

    /// A kid phone's Bonjour service name: stable, and says nothing about the kid to other phones on the network.
    public func serviceName(kid: UUID) -> String {
        "ScreenThyme \(tag("kid \(kid.uuidString)").prefix(12))"
    }

    /// Bluetooth: the service a kid phone advertises, and its characteristic that holds the L2CAP channel number.
    /// Derived like the tag, so only family phones scan for it.
    public var bluetoothServiceID: UUID { uuid("bluetooth service") }
    public var bluetoothChannelID: UUID { uuid("bluetooth channel") }

    func derived(_ label: String, salt: Data = Data()) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: salt,
                               info: Data("screenthyme.link.\(label)".utf8), outputByteCount: 32)
    }

    private func uuid(_ label: String) -> UUID {
        var bytes = Array(HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: derived("tag")).prefix(16))
        // A well-formed random (version 4) UUID.
        bytes[6] = bytes[6] & 0x0f | 0x40
        bytes[8] = bytes[8] & 0x3f | 0x80
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
    }

    private func tag(_ label: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(label.utf8), using: derived("tag"))
        return code.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
