import Foundation
import ManagedSettings
import ThymeCore

/// The block page's buttons (PLAN.md §15.4). "Ask for more time" notes what was blocked and opens ScreenThyme
/// (`openParentalControlsApp`, iOS 26.5), which asks the parents.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context.target(appToken: application)))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context.target(domainToken: webDomain)))
    }

    /// Downtime and category limits: the press names only the category, so ScreenThyme asks which app.
    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context.target(categoryToken: category)))
    }

    private func handle(_ action: ShieldAction, _ target: ShieldContext.Target) -> ShieldActionResponse {
        guard action == .secondaryButtonPressed else { return .close }
        ShieldContext.Ask(itemID: target.item?.id, categoryID: target.category?.id, at: Date()).save()
        guard #available(iOS 26.5, *) else { return .close }
        return .openParentalControlsApp
    }
}
