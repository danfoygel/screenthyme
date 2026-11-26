import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// Spike: can `FamilyActivityData` (iOS 26.4 data access) replace the app scan and token pairing? It lists visited
/// websites, installed apps and categories, each with its name and its token. Each list is fetched and timed on its own,
/// since `installedApplications` once hung for 90+ s, and compared with the scan's tokens and matches. A test shield
/// (store `spike`) checks that its tokens block. Results also go to App Group `family-data-spike.jsonl` for devicectl.
/// Debug-only; nothing here feeds enforcement.
struct FamilyDataSpikeView: View {
    struct Entry: Identifiable, Sendable {
        var id: String { "\(kind.rawValue):\(name)" }
        let kind: ItemKind
        /// Domain, bundle ID or category name.
        let name: String
        let tokenData: Data?
    }

    private static let store = ManagedSettingsStore(named: .init("spike"))

    @State private var lines: [String] = []
    @State private var entries: [ItemKind: [Entry]] = [:]
    @State private var pending: Set<ItemKind> = []
    @State private var shielded: String?
    @State private var search = ""

    var body: some View {
        Form {
            Section {
                Button("Visited websites") { fetch(.domain) }
                Button("Categories") { fetch(.category) }
                Button("Installed apps (may hang)") { fetch(.app) }
                if !pending.isEmpty { ProgressView("Waiting for \(pending.map(\.title).sorted().joined(separator: ", "))") }
            } header: {
                Text("Fetch")
            } footer: {
                Text("Each list runs on its own and logs how long it took, however long that is.")
            }
            Section("Results") {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            Section {
                LabeledContent("Shielded now", value: shielded ?? "nothing")
                Button("Clear test shield", role: .destructive) { clearShield() }
                TextField("Filter", text: $search)
                ForEach(shieldable) { entry in
                    Button { shield(entry) } label: {
                        HStack {
                            tokenLabel(entry)
                            Spacer()
                            Text(entry.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Test shield")
            } footer: {
                Text("Tap a website or app to shield it with its FamilyActivityData token, then open it. "
                    + "Apple's icon and name beside a row mean the token decodes in this app.")
            }
        }
        .navigationTitle("Family data spike")
        .bugButton()
    }

    private var shieldable: [Entry] {
        let all = (entries[.domain] ?? []) + (entries[.app] ?? [])
        let withTokens = all.filter { $0.tokenData != nil }
        return search.isEmpty ? withTokens : withTokens.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    @ViewBuilder private func tokenLabel(_ entry: Entry) -> some View {
        if entry.kind == .domain, let token = TokenCoding.webDomain(entry.tokenData) {
            Label(token)
        } else if entry.kind == .app, let token = TokenCoding.application(entry.tokenData) {
            Label(token)
        } else {
            Text("token doesn't decode").foregroundStyle(.red)
        }
    }

    // MARK: Fetching

    private func fetch(_ kind: ItemKind) {
        guard !pending.contains(kind) else { return }
        pending.insert(kind)
        log("\(Self.source(kind)): started")
        Task {
            let started = Date()
            do {
                let fetched = try await Self.fetch(kind)
                entries[kind] = fetched
                report(kind, fetched, seconds: Date().timeIntervalSince(started))
            } catch {
                log("\(Self.source(kind)): ERROR after \(Self.seconds(Date().timeIntervalSince(started))): \(error)")
            }
            pending.remove(kind)
        }
    }

    /// Off the main actor: FamilyActivityData and its results aren't Sendable, so only names and token data come back.
    nonisolated static func fetch(_ kind: ItemKind) async throws -> [Entry] {
        let data = FamilyActivityData.shared
        switch kind {
        case .domain:
            return try await data.visitedWebDomains.map {
                Entry(kind: kind, name: $0.domain ?? "?", tokenData: $0.token.flatMap(TokenCoding.encode))
            }
        case .app:
            return try await data.installedApplications.map {
                Entry(kind: kind, name: $0.bundleIdentifier ?? "? \($0.localizedDisplayName ?? "")",
                      tokenData: $0.token.flatMap(TokenCoding.encode))
            }
        case .category:
            return try await data.activityCategories.map {
                Entry(kind: kind, name: $0.localizedDisplayName ?? "?", tokenData: $0.token.flatMap(TokenCoding.encode))
            }
        }
    }

    /// Counts, then the comparison with this phone's items: the scan's tokens (does iOS hand out the same token?),
    /// their matches (does it agree with token pairing?) and Apple's usage data (does the list cover it?).
    private func report(_ kind: ItemKind, _ fetched: [Entry], seconds: TimeInterval) {
        let source = Self.source(kind)
        let withToken = fetched.filter { $0.tokenData != nil }
        let decodes = withToken.filter { Self.decodes(kind, $0.tokenData) }
        log("\(source): \(fetched.count) in \(Self.seconds(seconds)); named \(fetched.filter { !$0.name.hasPrefix("?") }.count), "
            + "with token \(withToken.count), token decodes \(decodes.count)")
        log("  first: " + fetched.prefix(8).map(\.name).joined(separator: ", "))

        let items = AppGroup.loadItems().filter { $0.kind == kind }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let scanned = items.filter { $0.isScanned && $0.tokenData != nil }
        var sameToken = 0, sameBytes = 0, agree = 0
        var disagree: [String] = []
        for entry in withToken {
            if scanned.contains(where: { $0.tokenData == entry.tokenData }) { sameBytes += 1 }
            guard let twin = scanned.first(where: { Self.sameToken(kind, $0.tokenData, entry.tokenData) }) else { continue }
            sameToken += 1
            guard let match = twin.match.flatMap({ byID[$0] }) else { continue }
            if match.identifier == entry.name { agree += 1 } else { disagree.append("\(entry.name) ≠ \(match.identifier)") }
        }
        log("  vs the scan's \(scanned.count) tokens: \(sameToken) equal (\(sameBytes) byte for byte); "
            + "of those matched, \(agree) agree with token pairing, \(disagree.count) don't")
        if !disagree.isEmpty { log("  disagree: " + disagree.prefix(10).joined(separator: "; ")) }

        let names = Set(fetched.map(\.name))
        let fromData = Set(items.filter { !$0.isScanned }.map(\.identifier))
        let missing = fromData.subtracting(names).sorted()
        log("  covers \(fromData.count - missing.count) of the \(fromData.count) in Apple's usage data")
        if !missing.isEmpty { log("  missing: " + missing.prefix(20).joined(separator: ", ")) }
        let extra = names.subtracting(fromData).count
        log("  \(extra) not in Apple's usage data here")
    }

    nonisolated static func source(_ kind: ItemKind) -> String {
        switch kind {
        case .domain: "visitedWebDomains"
        case .app: "installedApplications"
        case .category: "activityCategories"
        }
    }

    private static func decodes(_ kind: ItemKind, _ data: Data?) -> Bool {
        switch kind {
        case .domain: TokenCoding.webDomain(data) != nil
        case .app: TokenCoding.application(data) != nil
        case .category: TokenCoding.category(data) != nil
        }
    }

    private static func sameToken(_ kind: ItemKind, _ a: Data?, _ b: Data?) -> Bool {
        switch kind {
        case .domain: TokenCoding.webDomain(a).map { $0 == TokenCoding.webDomain(b) } ?? false
        case .app: TokenCoding.application(a).map { $0 == TokenCoding.application(b) } ?? false
        case .category: TokenCoding.category(a).map { $0 == TokenCoding.category(b) } ?? false
        }
    }

    nonisolated static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1f s", interval)
    }

    // MARK: Test shield

    private func shield(_ entry: Entry) {
        Self.store.clearAllSettings()
        switch entry.kind {
        case .domain: Self.store.shield.webDomains = TokenCoding.webDomain(entry.tokenData).map { [$0] }
        case .app: Self.store.shield.applications = TokenCoding.application(entry.tokenData).map { [$0] }
        case .category: return
        }
        shielded = entry.name
        log("test shield: \(entry.name)")
    }

    private func clearShield() {
        Self.store.clearAllSettings()
        if let shielded { log("test shield cleared: \(shielded)") }
        shielded = nil
    }

    private func log(_ line: String) {
        lines.append(line)
        Self.append(line)
    }

    nonisolated static func append(_ line: String) {
        let file = JSONLinesFile<String>(url: AppGroup.container.appending(path: "family-data-spike.jsonl"))
        try? file.append(contentsOf: ["\(Date().formatted(date: .omitted, time: .standard)) \(line)"])
    }
}
