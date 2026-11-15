import Foundation

/// An append-only file of one JSON object per line, safe to share between the app and the monitor extension.
/// Appends take an exclusive `flock` and fsync before returning, so a fire survives the extension being killed.
/// A torn last line (killed mid-write) is skipped on read.
public struct JSONLinesFile<Element: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func append(_ element: Element) throws {
        try append(contentsOf: [element])
    }

    public func append(contentsOf elements: [Element]) throws {
        guard !elements.isEmpty else { return }
        let encoder = JSONEncoder.thyme
        var data = Data()
        for element in elements {
            data.append(try encoder.encode(element))
            data.append(0x0A)
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
        fsync(fd)
    }

    public func readAll() -> [Element] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder.thyme
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(Element.self, from: $0) }
    }
}

extension JSONEncoder {
    /// Shared format for every file and trace: ISO 8601 dates with fractional seconds, sorted keys.
    public static var thyme: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    public static var thyme: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = (try? fractional.parse(string)) ?? (try? Date.ISO8601FormatStyle().parse(string)) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date \(string)")
        }
        return decoder
    }
}
