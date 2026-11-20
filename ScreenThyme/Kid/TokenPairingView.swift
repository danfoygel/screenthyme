import DeviceActivity
import PhotosUI
import SwiftUI
import ThymeCore
import Vision

/// Matches scanned apps, websites and categories to Apple's data at once (PLAN.md §15.6, `TokenPairing`). One Apple
/// report per bit of each scanned item's number, filtered to the items with that bit set, draws a QR code of what it
/// saw, and a names report spells the identifiers out; categories have reports of their own. The kid takes screenshots
/// of them, and this reads the codes back from the photo library. By default only unmatched scanned items are paired,
/// with new apps, so a few small codes do.
struct TokenPairingView: View {
    @Environment(AppModel.self) private var model
    @State private var mode = AppGroup.tokenPairingMode()
    /// The reports' window ends here, fixed while the screen is open: a new filter makes every report fetch again.
    @State private var now = Date()
    @State private var photos: [PhotosPickerItem] = []
    @State private var result: String?
    @State private var working = false
    /// Once the reports know to draw for screenshots (`TokenPairing.Display`).
    @State private var ready = false
    @State private var width: CGFloat = 340
    @Environment(\.displayScale) private var scale

    var body: some View {
        let items = AppGroup.loadItems()
        let order = TokenPairing.order(items, mode: mode)
        let categories = TokenPairing.categoryOrder(items, mode: mode)
        let views = TokenPairing.views(count: order.count) + TokenPairing.categoryViews(count: categories.count)
        ScrollView {
            VStack(spacing: 8) {
                // Saved before the reports redraw: the report extension reads it.
                Picker("Match", selection: Binding(get: { mode }, set: { mode in
                    AppGroup.save(mode, to: AppGroup.tokenPairingModeURL)
                    self.mode = mode
                    result = nil
                })) {
                    Text("New apps").tag(TokenPairing.Mode.unmatched)
                    Text("Everything").tag(TokenPairing.Mode.all)
                }
                .pickerStyle(.segmented)
                Text(mode == .unmatched
                     ? "Matches apps, websites and categories not matched yet. Apps installed since the last scan need a new scan first."
                     : "Checks every match again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !views.isEmpty {
                    Text("Take screenshots that together show all \(views.count + (order.isEmpty ? 0 : 1)) codes, then import them.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .screenshots) {
                    Label(working ? "Reading…" : "Import screenshots", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || views.isEmpty)
                if let result {
                    Text(result).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if views.isEmpty {
                    Text(mode == .unmatched && !(TokenPairing.order(items, mode: .all) + TokenPairing.categoryOrder(items, mode: .all)).isEmpty
                         ? "Every scanned app and website is matched." : "Scan the apps first.")
                        .foregroundStyle(.secondary)
                }
                if ready, !order.isEmpty {  // an empty filter would mean every app
                    let names = size(.names, lines: TokenPairing.estimatedLines(members: order, items: items, mode: mode),
                                     columns: 1)
                    DeviceActivityReport(.init("pair." + TokenPairing.View.names.name), filter: Self.filter(order, now: now))
                        .frame(height: names.height)
                }
                // As many columns (up to 3) as still give each code its pixels a module: small codes, wider phones.
                let members = views.map { TokenPairing.members($0, of: $0.isCategory ? categories : order) }
                let lines = members.map { TokenPairing.estimatedLines(members: $0, items: items, mode: mode) }
                let columns = (1...3).last { columns in
                    zip(views, lines).allSatisfy { size($0, lines: $1, columns: columns).fits }
                } ?? 1
                let height = zip(views, lines).map { size($0, lines: $1, columns: columns).height }.max() ?? 0
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns), spacing: 8) {
                    ForEach(Array(zip(views, members)).filter { _ in ready }, id: \.0) { view, members in
                        DeviceActivityReport(.init("pair." + view.name), filter: Self.filter(members, now: now))
                            .frame(height: height)
                    }
                }
            }
            .id(mode)  // the reports draw again in the new mode, even with the same filters
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .padding(.horizontal)
        }
        .navigationTitle("Match by screenshot")
        .bugButton()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            AppGroup.save(TokenPairing.Display.screenshots, to: AppGroup.pairingDisplayURL)
            ready = true
        }
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            Task { await importPhotos(picked) }
        }
    }

    /// The height a report needs in a grid of `columns` for its codes to draw at `TokenPairing.pixelsPerModule`, laid
    /// out the way the report extension lays them out, and whether they fit the width at that size.
    private func size(_ view: TokenPairing.View, lines: Int, columns: Int) -> (height: CGFloat, fits: Bool) {
        let cell = (width - CGFloat(columns - 1) * 8) / CGFloat(columns)
        let codes = TokenPairing.estimatedCodes(view, lines: lines)
        let wanted = CGFloat(codes.modules * TokenPairing.pixelsPerModule + 1) / scale  // a pixel spare: rounding
        let side = min(wanted, cell)
        let across = max(1, Int(cell / side))
        let rows = (codes.count + across - 1) / across
        return (CGFloat(rows) * side + 20, wanted <= cell)  // and the caption
    }

    /// When codes were last imported: apps first used after it are counted on the home screen (`TokenPairing.unmatched`).
    struct State: Codable {
        var importedAt: Date
    }

    static var stateURL: URL { AppGroup.container.appending(path: "token-pairing.json") }

    static func lastImport() -> Date? {
        AppGroup.load(State.self, from: stateURL)?.importedAt
    }

    /// One weekly segment over the last `TokenPairing.days`: pairing needs only which apps were used, and each
    /// segment repeats every app used in it.
    static func filter(_ items: [TrackedItem], now: Date) -> DeviceActivityFilter {
        let start = now.addingTimeInterval(-Double(TokenPairing.days) * 86_400)
        return DeviceActivityFilter(
            segment: .weekly(during: DateInterval(start: start, end: now)), users: .all, devices: .all,
            applications: Set(items.compactMap { $0.kind == .app ? TokenCoding.application($0.tokenData) : nil }),
            categories: Set(items.compactMap { $0.kind == .category ? TokenCoding.category($0.tokenData) : nil }),
            webDomains: Set(items.compactMap { $0.kind == .domain ? TokenCoding.webDomain($0.tokenData) : nil }))
    }

    private func importPhotos(_ picked: [PhotosPickerItem]) async {
        working = true
        defer {
            working = false
            photos = []
        }
        var codes: [TokenPairing.Code] = []
        for item in picked {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            codes += await Self.qrPayloads(in: data).compactMap(TokenPairing.decode)
        }
        guard !codes.isEmpty else {
            result = "No ScreenThyme codes found in \(picked.count) screenshot\(picked.count == 1 ? "" : "s")."
            return
        }
        let saved = await Self.save(codes, model: model, mode: mode, source: "the screenshots")
        result = saved.text + (saved.paired ? " You can delete the screenshots now." : "")
    }

    /// Pairs `codes` (from screenshots or a parent's camera, drawn in `mode`) and saves the matches. Returns what
    /// happened, to show, and whether it paired (no report was missing).
    static func save(_ codes: [TokenPairing.Code], model: AppModel, mode: TokenPairing.Mode,
                     source: String) async -> (text: String, paired: Bool) {
        guard let kid = model.config.kid else { return ("This phone has no kid set up.", false) }
        let (resolution, outcome) = pair(codes, kid: kid, mode: mode)
        guard resolution.missing.isEmpty else {
            return ("Missing codes \(resolution.missing.joined(separator: ", ")): include them in \(source)."
                + (resolution.otherScan > 0 ? " Some codes were drawn before the scan or matches changed, or in the other mode; read them again." : ""), false)
        }
        var parts = ["\(resolution.pairs.count) found: \(outcome.added) newly matched", "\(outcome.corrected) corrected",
                     "\(outcome.unchanged) already right"]
        if outcome.cleared > 0 { parts.append("\(outcome.cleared) wrong matches undone") }
        if outcome.created > 0 { parts.append("\(outcome.created) not used since tracking began, added") }
        if resolution.unknown > 0 { parts.append("\(resolution.unknown) not seen in Apple's data on this phone yet") }
        if resolution.conflicts > 0 { parts.append("\(resolution.conflicts) inconsistent, skipped") }
        if !outcome.changed.isEmpty {
            await Enforcer.offMain { Enforcer.reconcile() }
            await model.flush()
        }
        await model.sendHeartbeat(.manual)  // parents' phones stop counting the apps just looked for
        return (parts.joined(separator: ", ") + ".", true)
    }

    /// Saves the matches; changed items go to the outbox, so parents' phones see them.
    private static func pair(_ codes: [TokenPairing.Code], kid: Kid, mode: TokenPairing.Mode)
        -> (TokenPairing.Resolution, TokenPairing.Outcome) {
        AppGroup.withLock("sampler") {  // the sampler rewrites items.json too
            var items = AppGroup.loadItems()
            let resolution = TokenPairing.resolve(codes, order: TokenPairing.order(items, mode: mode),
                                                  categories: TokenPairing.categoryOrder(items, mode: mode), known: items)
            guard resolution.missing.isEmpty else { return (resolution, TokenPairing.Outcome()) }
            AppGroup.save(State(importedAt: Date()), to: stateURL)
            let outcome = TokenPairing.apply(resolution.pairs, to: &items, kid: kid.id)
            if !outcome.changed.isEmpty {
                AppGroup.saveItems(items)
                try? AppGroup.newItems.append(contentsOf: outcome.changed)
            }
            try? AppGroup.journal.append(.note(
                "token pairing (\(mode.rawValue)): \(outcome.added) added, \(outcome.corrected) corrected, \(outcome.cleared) cleared, "
                    + "\(outcome.created) created, \(resolution.unknown) unknown, \(resolution.conflicts) conflicts"))
            return (resolution, outcome)
        }
    }

    private static func qrPayloads(in image: Data) async -> [String] {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr]
        let observations = (try? await request.perform(on: image)) ?? []
        return observations.compactMap(\.payloadString)
    }
}
