import CoreGraphics
import Foundation
import ImageIO
import Testing
import Vision
@testable import ThymeCore

/// Our QR codes, drawn the way the report extension draws them, must read back exactly with Vision (what the app uses).
struct QRCodeTests {
    @Test(arguments: [1, 17, 60, 140, 345, 600, 1200, 2000])
    func readsBackWithVision(length: Int) async throws {
        let alphabet = Array("0123456789abcdef\nSTPAIR ")
        let text = String((0..<length).map { i in alphabet[(i * 7 + length) % alphabet.count] })
        let code = try #require(QRCode(Array(text.utf8)))
        #expect(code.size == code.version * 4 + 17)
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        let observations = try await request.perform(on: try png(code))
        #expect(observations.compactMap(\.payloadString) == [text], "version \(code.version)")
    }

    @Test func tooMuchDataIsNil() {
        #expect(QRCode([UInt8](repeating: 65, count: 3000)) == nil)
    }

    /// 4 px per module and a 4-module quiet zone.
    private func png(_ code: QRCode) throws -> Data {
        let scale = 4, side = (code.size + 8) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for (y, row) in code.modules.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale {
                    for dx in 0..<scale { pixels[((y + 4) * scale + dy) * side + (x + 4) * scale + dx] = 0 }
                }
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let image = try #require(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}
