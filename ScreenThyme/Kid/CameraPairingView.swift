import DeviceActivity
import SwiftUI
import ThymeCore
import UIKit

/// Matches scanned apps, websites and categories with a parent's camera (PLAN.md §15.6): the same reports as
/// `TokenPairingView`, one at a time and filling the screen, each cycling through smaller codes. A parent's phone nearby
/// reads them and sends back the codes of every report it has read all of (`LinkPairing`), which moves this screen on
/// to the next report. Once all are read, this phone pairs, as from screenshots, and tells the parent what it found.
struct CameraPairingView: View {
    @Environment(AppModel.self) private var model
    /// Loaded once, when the screen opens: a filter made anew at every redraw would make the report fetch again.
    @State private var setup: Setup?
    @State private var mode = AppGroup.tokenPairingMode()
    /// Reports passed over by hand: one that draws no code would hold everything up.
    @State private var skipped: Set<TokenPairing.View> = []
    @State private var result: String?
    @State private var saving = false

    struct Setup {
        var mode: TokenPairing.Mode
        /// Whether the scan has items at all, matched or not.
        var scanned: Bool
        var order: [TrackedItem]
        var categories: [TrackedItem]
        /// The names report first: it spells out identifiers the phone hasn't seen in Apple's data, which the bit
        /// reports' hashes need.
        var views: [TokenPairing.View]
        var now: Date

        init(items: [TrackedItem], mode: TokenPairing.Mode) {
            self.mode = mode
            scanned = !(TokenPairing.order(items, mode: .all) + TokenPairing.categoryOrder(items, mode: .all)).isEmpty
            order = TokenPairing.order(items, mode: mode)
            categories = TokenPairing.categoryOrder(items, mode: mode)
            views = (order.isEmpty ? [] : [.names]) + TokenPairing.views(count: order.count)
                + TokenPairing.categoryViews(count: categories.count)
            now = Date()
        }

        func members(_ view: TokenPairing.View) -> [TrackedItem] {
            TokenPairing.members(view, of: view.isCategory ? categories : order)
        }

        /// The reports all of whose codes a parent's phone has read, for this scan.
        func read(_ texts: Set<String>) -> Set<TokenPairing.View> {
            let complete = TokenPairing.complete(texts.compactMap(TokenPairing.decode))
            let apps = complete[TokenPairing.fingerprint(order)] ?? []
            let categories = complete[TokenPairing.fingerprint(categories)] ?? []
            return Set(views.filter { $0.isCategory ? categories.contains($0) : apps.contains($0) })
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let setup {
                let read = setup.read(model.pairingCodes)
                let current = setup.views.first { !read.contains($0) && !skipped.contains($0) }
                // Saved before the reports redraw: the report extension reads it.
                Picker("Match", selection: Binding(get: { mode }, set: { start($0) })) {
                    Text("New apps").tag(TokenPairing.Mode.unmatched)
                    Text("Everything").tag(TokenPairing.Mode.all)
                }
                .pickerStyle(.segmented)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let current {
                    DeviceActivityReport(.init("pair." + current.name),
                                         filter: TokenPairingView.filter(setup.members(current), now: setup.now))
                        .id(current.name)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HStack {
                        Text("Report \((setup.views.firstIndex(of: current) ?? 0) + 1) of \(setup.views.count)")
                            .monospacedDigit()
                        Spacer()
                        Button("Skip") { skipped.insert(current) }
                    }
                    .font(.footnote)
                } else {
                    Spacer()
                    if let result {
                        Text(result).multilineTextAlignment(.center)
                    } else if setup.views.isEmpty {
                        Text(setup.scanned ? "Every scanned app and website is matched." : "Scan the apps first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView("Matching…")
                    }
                    Spacer()
                }
                Color.clear.frame(height: 0)
                    .task(id: "\(setup.mode.rawValue).\(current?.name ?? "")") { await shown(current, of: setup, read: read) }
            }
        }
        .padding(.horizontal)
        .navigationTitle("Match with a parent's camera")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Before any report draws: smaller codes, one at a time.
            AppGroup.save(TokenPairing.Display.camera, to: AppGroup.pairingDisplayURL)
            start(mode)
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            model.showPairing(nil)
        }
    }

    /// Starts over in `mode`: codes read in the other mode name another order, so they wouldn't count anyway.
    private func start(_ mode: TokenPairing.Mode) {
        AppGroup.save(mode, to: AppGroup.tokenPairingModeURL)
        self.mode = mode
        model.pairingCodes = []
        skipped = []
        result = nil
        setup = Setup(items: AppGroup.loadItems(), mode: mode)
    }

    private var status: String {
        let parents = Set(model.nearby.peers.filter { $0.hello.role == .parent }.map(\.hello.name)).sorted()
        guard !parents.isEmpty else {
            let name = model.config.kid?.displayName ?? "this kid"
            return "Waiting for a parent's phone nearby. On it, open ScreenThyme → Settings → \(name) → Match apps with camera."
        }
        return "Hold \(parents.joined(separator: " or "))'s camera over this screen until it moves on."
    }

    /// Tells parents' phones what this screen shows; once nothing is left to show, pairs.
    private func shown(_ current: TokenPairing.View?, of setup: Setup, read: Set<TokenPairing.View>) async {
        guard !setup.views.isEmpty else { return }
        let done = current.flatMap(setup.views.firstIndex(of:)) ?? setup.views.count
        model.showPairing(.progress(showing: current?.name, done: done, total: setup.views.count))
        guard current == nil, result == nil, !saving else { return }
        saving = true
        defer { saving = false }
        let codes = model.pairingCodes.compactMap(TokenPairing.decode)
        let saved = await TokenPairingView.save(codes, model: model, mode: setup.mode, source: "what the camera reads")
        result = saved.text
        model.sendPairingResult(saved.text)
    }
}
