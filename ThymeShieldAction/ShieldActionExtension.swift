import Foundation
import ManagedSettings
import ThymeCore

/// The block page's buttons (PLAN.md §15.4, §15.5). "Ask for more time" notes what was blocked and opens ScreenThyme
/// (`openParentalControlsApp`, iOS 26.5), which asks the parents; its menu's "One more minute" lifts the shield
/// for the kid phone's chosen minutes (1–5), once a day, without asking.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context.target(appToken: application), context))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context.target(domainToken: webDomain), context))
    }

    /// Downtime and category limits: the press names only the category, so ScreenThyme asks which app.
    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context.target(categoryToken: category), context))
    }

    private func handle(_ action: ShieldAction, _ target: ShieldContext.Target, _ context: ShieldContext) -> ShieldActionResponse {
        let submenu: [ShieldAction] = [.firstSecondarySubmenuItemPressed, .secondSecondarySubmenuItemPressed,
                                       .thirdSecondarySubmenuItemPressed]
        let choice: ShieldContext.MoreTime
        if action == .secondaryButtonPressed {
            choice = .ask
        } else if let index = submenu.firstIndex(of: action) {
            let menu = context.moreTimeMenu(for: target)
            choice = menu.indices.contains(index) ? menu[index] : .ask
        } else {
            return .close
        }
        if choice == .oneMoreMinute, let scope = context.extraMinuteScope(for: target),
           Enforcer.takeExtraMinute(itemID: scope.itemID, reason: scope.reason) {
            // The stores no longer shield it: iOS re-evaluates the shield and lets the app through.
            return .defer
        }
        ShieldContext.Ask(itemID: target.item?.id, categoryID: target.category?.id, at: Date()).save()
        guard #available(iOS 26.5, *) else { return .close }
        return .openParentalControlsApp
    }
}
