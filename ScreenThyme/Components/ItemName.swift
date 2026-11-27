import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// An app's or website's name: Apple's label for its token (icon and name), else a nickname, the App Store's name or a
/// readable form of the bundle ID or domain, with the icon `AppCatalog` found.
struct ItemName: View {
    let item: TrackedItem?
    var showIcon = true

    var body: some View {
        if let item {
            if item.nickname == nil, let label = tokenLabel(item) {
                label
            } else {
                let name = item.nickname ?? AppCatalog.shared.entries[item.identifier]?.name ?? item.displayName
                if showIcon, let icon = AppCatalog.shared.icon(for: item) {
                    Label {
                        Text(name)
                    } icon: {
                        iconView(icon)
                    }
                } else {
                    Text(name)
                }
            }
        } else {
            Text("Unknown app").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func iconView(_ icon: AppCatalog.Icon) -> some View {
        switch icon {
        case let .remote(url):
            AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 22, height: 22)
                .clipShape(.rect(cornerRadius: 5))
        case let .image(image):
            Image(uiImage: image).resizable().scaledToFit()
                .frame(width: 22, height: 22)
                .clipShape(.rect(cornerRadius: 5))
        case let .token(token):
            Label(token).labelStyle(.iconOnly)
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.35))
                .frame(width: 22, height: 22)
                .background(LinearGradient(colors: [Color(white: 0.9), Color(white: 0.7)], startPoint: .top, endPoint: .bottom),
                            in: .rect(cornerRadius: 5))
        }
    }

    private func tokenLabel(_ item: TrackedItem) -> AnyView? {
        switch item.kind {
        case .app: TokenCoding.application(item.tokenData).map { styled(Label($0)) }
        case .domain: TokenCoding.webDomain(item.tokenData).map { styled(Label($0)) }
        case .category: TokenCoding.category(item.tokenData).map { styled(Label($0)) }
        }
    }

    private func styled<V: View>(_ label: V) -> AnyView {
        showIcon ? AnyView(label) : AnyView(label.labelStyle(.titleOnly))
    }
}

/// A parent's group of apps (`ItemGroup`), as lists show it.
struct GroupName: View {
    let group: ItemGroup

    var body: some View {
        Label(group.name, systemImage: group.isCategory ? "square.grid.2x2.fill" : "square.stack.3d.up.fill")
    }
}

enum Format {
    static func minutes(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// To the nearest quarter hour: "10¼ hours".
    static func hours(_ interval: TimeInterval) -> String {
        let quarters = Int((interval / 900).rounded())
        let whole = quarters / 4, fraction = ["", "¼", "½", "¾"][quarters % 4]
        if whole == 0 { return fraction.isEmpty ? "0 hours" : "\(fraction) hour" }
        return whole == 1 && fraction.isEmpty ? "1 hour" : "\(whole)\(fraction) hours"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension Kid {
    var color: Color {
        [Color.blue, .orange, .green, .purple, .pink, .teal][abs(colorIndex) % 6]
    }
}
