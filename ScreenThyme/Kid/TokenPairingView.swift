import DeviceActivity
import PhotosUI
import SwiftUI
import ThymeCore
import Vision

/// Matches scanned apps and websites to Apple's data at once (PLAN.md §15.6, `TokenPairing`). One Apple report per
/// bit of each scanned item's number, filtered to the items with that bit set, draws a QR code of what it saw, and a
/// names report spells the identifiers out; the kid takes screenshots of them, and this reads the codes back from the
/// photo library.
struct TokenPairingView: View {
    @Environment(AppModel.self) private var model
    @State private var photos: [PhotosPickerItem] = []
    @State private var result: String?
    @State private var working = false

    var body: some View {
        let order = TokenPairing.order(AppGroup.loadItems())
        let views = TokenPairing.views(count: order.count)
        ScrollView {
            VStack(spacing: 8) {
                Text("Take screenshots that together show all \(views.count + 1) codes, then import them.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                PhotosPicker(selection: $photos, maxSelectionCount: 10, matching: .screenshots) {
                    Label(working ? "Reading…" : "Import screenshots", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || views.isEmpty)
                if let result {
                    Text(result).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if views.isEmpty {
                    Text("Scan the apps first.").foregroundStyle(.secondary)
                }
                if !views.isEmpty {
                    DeviceActivityReport(.init("pair." + TokenPairing.View.names.name), filter: Self.filter(order))
                        .frame(height: 360)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(views, id: \.self) { view in
                        DeviceActivityReport(.init("pair." + view.name),
                                             filter: Self.filter(TokenPairing.members(view, of: order)))
                            .frame(height: 190)
                    }
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Match by screenshot")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photos) { _, picked in
            guard !picked.isEmpty else { return }
            Task { await importPhotos(picked) }
        }
    }

    /// When codes were last imported: apps first used after it are counted on the home screen (`TokenPairing.toMatch`).
    struct State: Codable {
        var importedAt: Date
    }

    static var stateURL: URL { AppGroup.container.appending(path: "token-pairing.json") }

    static func lastImport() -> Date? {
        AppGroup.load(State.self, from: stateURL)?.importedAt
    }

    private static func filter(_ items: [TrackedItem]) -> DeviceActivityFilter {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -(TokenPairing.days - 1),
                                          to: Calendar.current.startOfDay(for: now))!
        return DeviceActivityFilter(
            segment: .daily(during: DateInterval(start: start, end: now)), users: .all, devices: .all,
            applications: Set(items.compactMap { $0.kind == .app ? TokenCoding.application($0.tokenData) : nil }),
            webDomains: Set(items.compactMap { $0.kind == .domain ? TokenCoding.webDomain($0.tokenData) : nil }))
    }

    private func importPhotos(_ picked: [PhotosPickerItem]) async {
        guard let kid = model.config.kid else { return }
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
        let (resolution, outcome) = Self.pair(codes, kid: kid)
        guard resolution.missing.isEmpty else {
            result = "Missing codes \(resolution.missing.joined(separator: ", ")): include them in the screenshots."
                + (resolution.otherScan > 0 ? " Some codes were from an earlier scan; take new screenshots." : "")
            return
        }
        var parts = ["\(resolution.pairs.count) found: \(outcome.added) newly matched", "\(outcome.corrected) corrected",
                     "\(outcome.unchanged) already right"]
        if outcome.cleared > 0 { parts.append("\(outcome.cleared) wrong matches undone") }
        if outcome.created > 0 { parts.append("\(outcome.created) not used since tracking began, added") }
        if resolution.unknown > 0 { parts.append("\(resolution.unknown) not seen in Apple's data on this phone yet") }
        if resolution.conflicts > 0 { parts.append("\(resolution.conflicts) inconsistent, skipped") }
        result = parts.joined(separator: ", ") + ". You can delete the screenshots now."
        guard !outcome.changed.isEmpty else { return }
        await Enforcer.offMain { Enforcer.reconcile() }
        await model.flush()
    }

    /// Saves the matches; changed items go to the outbox, so parents' phones see them.
    private static func pair(_ codes: [TokenPairing.Code], kid: Kid) -> (TokenPairing.Resolution, TokenPairing.Outcome) {
        AppGroup.withLock("sampler") {  // the sampler rewrites items.json too
            var items = AppGroup.loadItems()
            let resolution = TokenPairing.resolve(codes, order: TokenPairing.order(items), known: items)
            guard resolution.missing.isEmpty else { return (resolution, TokenPairing.Outcome()) }
            AppGroup.save(State(importedAt: Date()), to: stateURL)
            let outcome = TokenPairing.apply(resolution.pairs, to: &items, kid: kid.id)
            if !outcome.changed.isEmpty {
                AppGroup.saveItems(items)
                try? AppGroup.newItems.append(contentsOf: outcome.changed)
            }
            try? AppGroup.journal.append(.note(
                "token pairing: \(outcome.added) added, \(outcome.corrected) corrected, \(outcome.cleared) cleared, "
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
