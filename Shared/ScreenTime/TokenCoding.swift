import FamilyControls
import Foundation
import ManagedSettings

/// Tokens are stored as JSON so they survive in the App Group and in CloudKit.
enum TokenCoding {
    static func encode<T: Encodable>(_ token: T) -> Data? {
        try? JSONEncoder().encode(token)
    }

    static func application(_ data: Data?) -> ApplicationToken? { decode(data) }
    static func webDomain(_ data: Data?) -> WebDomainToken? { decode(data) }
    static func category(_ data: Data?) -> ActivityCategoryToken? { decode(data) }

    private static func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
