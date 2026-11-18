import Foundation

/// A QR code in byte mode at error correction level M, versions 1–40. Written out here because Core Image draws
/// nothing inside the report extension, which shows the token-pairing codes (`TokenPairing`, PLAN.md §15.6).
/// After Project Nayuki's QR Code generator (MIT).
public struct QRCode: Sendable {
    public let version: Int
    public let size: Int
    /// Rows from the top; true is dark. No quiet zone.
    public private(set) var modules: [[Bool]]
    private var isFunction: [[Bool]]

    /// The smallest version that holds `bytes`; nil when they don't fit version 40.
    static func version(bytes: Int) -> Int? {
        guard let version = (1...40).first(where: { Self.dataCapacityBits($0) >= 4 + Self.countBits($0) + bytes * 8 }),
              bytes < 1 << Self.countBits(version) else { return nil }
        return version
    }

    /// Modules on a side for `bytes`, without drawing the code.
    public static func size(bytes: Int) -> Int? { version(bytes: bytes).map { $0 * 4 + 17 } }

    /// Nil when the data doesn't fit version 40.
    public init?(_ data: [UInt8]) {
        guard let version = Self.version(bytes: data.count) else { return nil }
        self.version = version
        size = version * 4 + 17
        modules = Array(repeating: Array(repeating: false, count: size), count: size)
        isFunction = modules

        var bits: [Bool] = []
        func append(_ value: Int, _ count: Int) { for i in stride(from: count - 1, through: 0, by: -1) { bits.append(value >> i & 1 == 1) } }
        append(0b0100, 4)
        append(data.count, Self.countBits(version))
        data.forEach { append(Int($0), 8) }
        let capacity = Self.dataCapacityBits(version)
        append(0, min(4, capacity - bits.count))
        append(0, (8 - bits.count % 8) % 8)
        var codewords = stride(from: 0, to: bits.count, by: 8).map { start in
            bits[start..<start + 8].reduce(UInt8(0)) { $0 << 1 | ($1 ? 1 : 0) }
        }
        var pad: UInt8 = 0xEC
        while codewords.count * 8 < capacity {
            codewords.append(pad)
            pad ^= 0xEC ^ 0x11
        }

        drawFunctionPatterns()
        drawCodewords(interleaved(codewords))
        let penalties = (0..<8).map { penalty(masked: $0) }
        let mask = penalties.indices.min { penalties[$0] < penalties[$1] }!
        applyMask(mask)
        drawFormatBits(mask)
    }

    // MARK: Layout

    private mutating func setFunction(_ x: Int, _ y: Int, _ dark: Bool) {
        modules[y][x] = dark
        isFunction[y][x] = true
    }

    private mutating func drawFunctionPatterns() {
        for i in 0..<size {
            setFunction(6, i, i % 2 == 0)
            setFunction(i, 6, i % 2 == 0)
        }
        for (x, y) in [(3, 3), (size - 4, 3), (3, size - 4)] {
            for dy in -4...4 {
                for dx in -4...4 where (0..<size).contains(x + dx) && (0..<size).contains(y + dy) {
                    let distance = max(abs(dx), abs(dy))
                    setFunction(x + dx, y + dy, distance != 2 && distance != 4)
                }
            }
        }
        let positions = alignmentPositions
        for (i, x) in positions.enumerated() {
            for (j, y) in positions.enumerated() {
                let last = positions.count - 1
                if (i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0) { continue }
                for dy in -2...2 {
                    for dx in -2...2 { setFunction(x + dx, y + dy, max(abs(dx), abs(dy)) != 1) }
                }
            }
        }
        drawFormatBits(0)  // reserves the area; redrawn with the chosen mask
        if version >= 7 {
            var remainder = version
            for _ in 0..<12 { remainder = (remainder << 1) ^ ((remainder >> 11) * 0x1F25) }
            let bits = version << 12 | remainder
            for i in 0..<18 {
                let dark = bits >> i & 1 == 1
                let a = size - 11 + i % 3, b = i / 3
                setFunction(a, b, dark)
                setFunction(b, a, dark)
            }
        }
    }

    private var alignmentPositions: [Int] {
        guard version > 1 else { return [] }
        let count = version / 7 + 2
        let step = version == 32 ? 26 : (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2
        var positions = [6]
        var position = size - 7
        for _ in 0..<count - 1 {
            positions.insert(position, at: 1)
            position -= step
        }
        return positions
    }

    /// Level M's format bits are 00.
    private mutating func drawFormatBits(_ mask: Int) {
        let data = mask
        var remainder = data
        for _ in 0..<10 { remainder = (remainder << 1) ^ ((remainder >> 9) * 0x537) }
        let bits = (data << 10 | remainder) ^ 0x5412
        func bit(_ i: Int) -> Bool { bits >> i & 1 == 1 }
        for i in 0...5 { setFunction(8, i, bit(i)) }
        setFunction(8, 7, bit(6))
        setFunction(8, 8, bit(7))
        setFunction(7, 8, bit(8))
        for i in 9..<15 { setFunction(14 - i, 8, bit(i)) }
        for i in 0..<8 { setFunction(size - 1 - i, 8, bit(i)) }
        for i in 8..<15 { setFunction(8, size - 15 + i, bit(i)) }
        setFunction(8, size - 8, true)
    }

    private mutating func drawCodewords(_ data: [UInt8]) {
        var i = 0
        var right = size - 1
        while right >= 1 {
            if right == 6 { right = 5 }
            for vertical in 0..<size {
                for j in 0..<2 {
                    let x = right - j
                    let y = (right + 1) & 2 == 0 ? size - 1 - vertical : vertical
                    if !isFunction[y][x], i < data.count * 8 {
                        modules[y][x] = data[i >> 3] >> (7 - i & 7) & 1 == 1
                        i += 1
                    }
                }
            }
            right -= 2
        }
    }

    private mutating func applyMask(_ mask: Int) {
        for y in 0..<size {
            for x in 0..<size where !isFunction[y][x] {
                let invert = switch mask {
                case 0: (x + y) % 2 == 0
                case 1: y % 2 == 0
                case 2: x % 3 == 0
                case 3: (x + y) % 3 == 0
                case 4: (x / 3 + y / 2) % 2 == 0
                case 5: x * y % 2 + x * y % 3 == 0
                case 6: (x * y % 2 + x * y % 3) % 2 == 0
                default: ((x + y) % 2 + x * y % 3) % 2 == 0
                }
                if invert { modules[y][x].toggle() }
            }
        }
    }

    /// A simplified penalty (runs, 2×2 blocks, balance): enough to avoid a mask that makes large flat areas.
    private func penalty(masked mask: Int) -> Int {
        var code = self
        code.applyMask(mask)
        code.drawFormatBits(mask)
        let m = code.modules
        var result = 0
        for line in 0..<size {
            for transposed in [false, true] {
                var run = 0
                var last: Bool?
                for i in 0..<size {
                    let dark = transposed ? m[i][line] : m[line][i]
                    if dark == last {
                        run += 1
                        if run == 5 { result += 3 } else if run > 5 { result += 1 }
                    } else {
                        run = 1
                        last = dark
                    }
                }
            }
        }
        for y in 0..<size - 1 {
            for x in 0..<size - 1 where m[y][x] == m[y][x + 1] && m[y][x] == m[y + 1][x] && m[y][x] == m[y + 1][x + 1] {
                result += 3
            }
        }
        let dark = m.joined().filter { $0 }.count
        let total = size * size
        result += (abs(dark * 20 - total * 10) + total - 1) / total * 10
        return result
    }

    // MARK: Error correction

    private func interleaved(_ data: [UInt8]) -> [UInt8] {
        let blocks = Self.blocks[version], eccLength = Self.eccPerBlock[version]
        let raw = Self.rawDataModules(version) / 8
        let shortBlocks = blocks - raw % blocks
        let shortLength = raw / blocks
        let divisor = Self.divisor(eccLength)
        var split: [[UInt8]] = []
        var k = 0
        for i in 0..<blocks {
            let length = shortLength - eccLength + (i < shortBlocks ? 0 : 1)
            var block = Array(data[k..<k + length])
            k += length
            let ecc = Self.remainder(block, divisor)
            if i < shortBlocks { block.append(0) }
            split.append(block + ecc)
        }
        var result: [UInt8] = []
        for i in 0..<split[0].count {
            for (j, block) in split.enumerated() where i != shortLength - eccLength || j >= shortBlocks {
                result.append(block[i])
            }
        }
        return result
    }

    private static func divisor(_ degree: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: degree - 1) + [1]
        var root: UInt8 = 1
        for _ in 0..<degree {
            for j in 0..<degree {
                result[j] = multiply(result[j], root)
                if j + 1 < degree { result[j] ^= result[j + 1] }
            }
            root = multiply(root, 0x02)
        }
        return result
    }

    private static func remainder(_ data: [UInt8], _ divisor: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: divisor.count)
        for byte in data {
            let factor = byte ^ result.removeFirst()
            result.append(0)
            for i in result.indices { result[i] ^= multiply(divisor[i], factor) }
        }
        return result
    }

    /// In GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
    private static func multiply(_ x: UInt8, _ y: UInt8) -> UInt8 {
        var z = 0
        for i in stride(from: 7, through: 0, by: -1) {
            z = (z << 1) ^ ((z >> 7) * 0x11D)
            z ^= Int(y >> UInt8(i) & 1) * Int(x)
        }
        return UInt8(z)
    }

    // MARK: Capacity

    private static func countBits(_ version: Int) -> Int { version < 10 ? 8 : 16 }

    private static func rawDataModules(_ version: Int) -> Int {
        var result = (16 * version + 128) * version + 64
        if version >= 2 {
            let count = version / 7 + 2
            result -= (25 * count - 10) * count - 55
            if version >= 7 { result -= 36 }
        }
        return result
    }

    private static func dataCapacityBits(_ version: Int) -> Int {
        (rawDataModules(version) / 8 - eccPerBlock[version] * blocks[version]) * 8
    }

    /// Level M, by version (index 0 unused).
    private static let eccPerBlock = [0, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26,
                                      26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28]
    private static let blocks = [0, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21,
                                 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49]
}
