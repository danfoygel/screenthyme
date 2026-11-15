import FamilyControls
import ManagedSettings
import SwiftUI
import ThymeCore

/// An app's name: the nickname if set, else Apple's label for the token (if this device can render it — S2),
/// else "App #37".
struct ItemName: View {
    let item: TrackedItem?
    var showIcon = true

    var body: some View {
        if let item {
            if let nickname = item.nickname {
                Text(nickname)
            } else if let label = tokenLabel(item) {
                label
            } else {
                Text(item.fallbackName).foregroundStyle(.secondary)
            }
        } else {
            Text("Unknown app").foregroundStyle(.secondary)
        }
    }

    private func tokenLabel(_ item: TrackedItem) -> AnyView? {
        switch item.kind {
        case .app:
            TokenCoding.application(item.tokenData).map { styled(Label($0)) }
        case .domain:
            TokenCoding.webDomain(item.tokenData).map { styled(Label($0)) }
        case .category:
            TokenCoding.category(item.tokenData).map { styled(Label($0)) }
        }
    }

    private func styled<V: View>(_ label: V) -> AnyView {
        if showIcon {
            AnyView(label)
        } else {
            AnyView(label.labelStyle(.titleOnly))
        }
    }
}

enum Format {
    static func minutes(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// "25–29 min", "1 h 15 min–1 h 29 min".
    static func range(_ total: ItemTotal) -> String {
        let (lower, upper) = (total.lowerMinutes, total.upperMinutes)
        if upper == lower { return minutes(lower) }
        return upper < 60 ? "\(lower)–\(upper) min" : "\(minutes(lower))–\(minutes(upper))"
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
