import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The block page (PLAN.md §15.2): says why something is blocked and offers "Ask for more time".
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(app: application))
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(app: application, category: category))
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(domain: webDomain))
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(domain: webDomain, category: category))
    }

    private func make(_ context: ShieldContext, _ target: ShieldContext.Target) -> ShieldConfiguration {
        let reason = context.reason(for: target)
        let pending = context.pendingRequest(for: target) != nil
        // Only a known app can ask: a request names the app, and the button on an unknown one would do nothing.
        let canAsk = !pending && target.item != nil && reason != nil
        let label = UIColor.label
        // Fixed colors: iOS 26 draws the primary button much lighter than the color given (systemGreen came out mint),
        // so a white label disappeared. Dark text stays readable either way; the icon would otherwise draw black.
        let green = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        let symbol = reason.map { if case .downtime = $0 { "moon.zzz.fill" } else { "hourglass" } } ?? "hand.raised.fill"
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            icon: UIImage(systemName: symbol)?.withTintColor(green, renderingMode: .alwaysOriginal),
            title: .init(text: context.title(for: reason), color: label),
            subtitle: .init(text: context.subtitle(for: target, reason: reason), color: .secondaryLabel),
            primaryButtonLabel: .init(text: pending ? "Open ScreenThyme" : "OK", color: .black),
            primaryButtonBackgroundColor: green,
            secondaryButtonLabel: !canAsk ? nil : .init(text: "Ask for more time", color: .systemGreen),
            secondaryButtonSubmenuItems: !canAsk ? nil : ShieldContext.requestChoices.map { minutes in
                ShieldContext.describe(minutes: minutes).capitalizedFirst
            })
    }
}
