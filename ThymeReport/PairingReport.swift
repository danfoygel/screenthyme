import DeviceActivity
import ExtensionKit
import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// One of the reports that pair scanned tokens with bundle IDs and domains (PLAN.md §15.6, `TokenPairing`). The app
/// filters it to the scanned items whose number has this report's bit set; it draws a QR code of hashes of the
/// identifiers it sees (the names report: every scanned item, identifiers spelled out). This extension's own tokens are encrypted under another key than the scan's, so iOS does the
/// comparison, through the filter.
struct PairingData: @unchecked Sendable {
    var view: TokenPairing.View
    var identifiers = 0
    /// Each code's modules, rows from the top, true for dark.
    var codes: [[[Bool]]] = []
    var problem: String?
}

struct PairingReport: @preconcurrency DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let view: TokenPairing.View
    let content: (PairingData) -> PairingView

    init(_ view: TokenPairing.View) {
        self.view = view
        context = DeviceActivityReport.Context("pair." + view.name)
        content = { PairingView(report: $0) }
    }

    nonisolated func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> PairingData {
        var report = PairingData(view: view)
        var seen: Set<TokenPairing.Identifier> = []
        for await device in data {
            for await segment in device.activitySegments {
                for await category in segment.categories {
                    for await app in category.applications {
                        if let bundle = app.application.bundleIdentifier {
                            seen.insert(TokenPairing.Identifier(kind: .app, identifier: bundle))
                        }
                    }
                    for await site in category.webDomains {
                        if let domain = site.webDomain.domain { seen.insert(TokenPairing.Identifier(kind: .domain, identifier: domain)) }
                    }
                }
            }
        }
        report.identifiers = seen.count
        // The scan's order, as the app sees it, names the codes: codes from another scan can't be mixed in.
        let order = TokenPairing.order(AppGroup.loadItems())
        guard !order.isEmpty else {
            report.problem = "Can't read the app scan"
            return report
        }
        let texts = TokenPairing.encode(fingerprint: TokenPairing.fingerprint(order), view: view,
                                         lines: TokenPairing.lines(view, seen: seen))
        report.codes = texts.compactMap(Self.modules)
        if report.codes.count < texts.count { report.problem = "Couldn't draw the code" }
        return report
    }

    /// Our own encoder: Core Image draws nothing in this extension, not even on the CPU.
    private nonisolated static func modules(_ text: String) -> [[Bool]]? {
        QRCode(Array(text.utf8))?.modules
    }
}

struct PairingView: View {
    let report: PairingData

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let columns = TokenPairing.columns(count: report.codes.count, width: proxy.size.width,
                                                   height: proxy.size.height)
                let rows = (report.codes.count + columns - 1) / columns
                let side = min(proxy.size.width / CGFloat(columns), proxy.size.height / CGFloat(max(rows, 1)))
                VStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { row in
                        HStack(spacing: 0) {
                            let end = min(row * columns + columns, report.codes.count)
                            ForEach(row * columns..<end, id: \.self) { index in
                                QRCodeView(modules: report.codes[index]).frame(width: side, height: side)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(report.problem ?? "\(report.view.name) · \(report.identifiers)")
                .font(.caption2)
                .foregroundStyle(report.problem == nil ? Color.secondary : .orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Square modules of whole pixels (`TokenPairing.pixelsPerModule`), centered on white, with a quiet zone.
struct QRCodeView: View {
    let modules: [[Bool]]
    @Environment(\.displayScale) private var scale

    var body: some View {
        Canvas { context, size in
            let count = CGFloat(modules.count + 8)
            let side = max(1, (min(size.width, size.height) * scale / count).rounded(.down)) / scale
            let origin = CGPoint(x: ((size.width - side * count) / 2 * scale).rounded(.down) / scale,
                                 y: ((size.height - side * count) / 2 * scale).rounded(.down) / scale)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var dark = Path()
            for (y, row) in modules.enumerated() {
                for (x, isDark) in row.enumerated() where isDark {
                    dark.addRect(CGRect(x: origin.x + (CGFloat(x) + 4) * side, y: origin.y + (CGFloat(y) + 4) * side,
                                        width: side, height: side))
                }
            }
            context.fill(dark, with: .color(.black))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
