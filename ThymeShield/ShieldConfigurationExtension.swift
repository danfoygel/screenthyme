import ManagedSettings
import ManagedSettingsUI
import UIKit

/// The block page (PLAN.md §15.2, §15.4, §15.5): says why something is blocked; "Ask for more time" opens ScreenThyme,
/// or offers one more minute first.
final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(app: application), inCategory: false)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(app: application, category: category), inCategory: true)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(domain: webDomain), inCategory: false)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        let context = ShieldContext()
        return make(context, context.target(domain: webDomain, category: category), inCategory: true)
    }

    /// `inCategory`: shown through a category shield, so a press names the category, not the app.
    private func make(_ context: ShieldContext, _ target: ShieldContext.Target, inCategory: Bool) -> ShieldConfiguration {
        let reason = context.reason(for: target)
        // Opens ScreenThyme, which asks (or shows the waiting request and its answer), or first offers one more minute.
        let canAsk = reason != nil
        let menu = context.moreTimeMenu(for: context.pressed(target, inCategory: inCategory))
        let label = UIColor.label
        // Fixed colors: iOS 26 draws the primary button much lighter than the color given (systemGreen came out mint),
        // so a white label disappeared. Dark text stays readable either way; the icon would otherwise draw black.
        let green = UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        let symbol = reason.map { reason in
            switch reason {
            case .downtime: "moon.zzz.fill"
            case .breakTime: "figure.walk"
            default: "hourglass"
            }
        } ?? "hand.raised.fill"
        return ShieldConfiguration(
            backgroundBlurStyle: .systemMaterial,
            icon: UIImage(systemName: symbol)?.withTintColor(green, renderingMode: .alwaysOriginal),
            title: .init(text: context.title(for: reason), color: label),
            subtitle: .init(text: context.subtitle(for: target, reason: reason), color: .secondaryLabel),
            primaryButtonLabel: .init(text: "OK", color: .black),
            primaryButtonBackgroundColor: green,
            secondaryButtonLabel: canAsk ? .init(text: "Ask for more time", color: .systemGreen) : nil,
            secondaryButtonSubmenuItems: canAsk && !menu.isEmpty ? menu.map { $0.title(minutes: context.config.extraMinuteLength) } : nil)
    }
}
