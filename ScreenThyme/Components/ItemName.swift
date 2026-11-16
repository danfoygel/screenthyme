import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// An app's or website's name: a nickname if set, else Apple's label for its token (icon and name), else the App
/// Store's name and icon, else a readable form of the bundle ID or domain.
struct ItemName: View {
    let item: TrackedItem?
    var showIcon = true

    var body: some View {
        if let item {
            if item.nickname == nil, let label = tokenLabel(item) {
                label
            } else if item.nickname == nil, let name = AppCatalog.shared.entries[item.identifier]?.name {
                // From the App Store lookup, on parents' phones.
                if showIcon, let icon = AppCatalog.shared.icon(for: item) {
                    Label {
                        Text(name)
                    } icon: {
                        AsyncImage(url: icon) { $0.resizable() } placeholder: { Color.secondary.opacity(0.2) }
                            .frame(width: 22, height: 22)
                            .clipShape(.rect(cornerRadius: 5))
                    }
                } else {
                    Text(name)
                }
            } else {
                Text(item.displayName)
            }
        } else {
            Text("Unknown app").foregroundStyle(.secondary)
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

enum Format {
    static func minutes(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
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
