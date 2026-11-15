import ManagedSettings

/// The block page's buttons (PLAN.md §15.2). "Ask for more time" queues a request and redraws the page, which then
/// says the request is waiting; "Open ScreenThyme" opens the app, which uploads it and shows the answer.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context, context.target(appToken: application)))
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        completionHandler(handle(action, context, context.target(domainToken: webDomain)))
    }

    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        completionHandler(.close)
    }

    private func handle(_ action: ShieldAction, _ context: ShieldContext, _ target: ShieldContext.Target) -> ShieldActionResponse {
        let choice: Int?? = switch action {
        case .secondaryButtonPressed, .firstSecondarySubmenuItemPressed: .some(ShieldContext.requestChoices[0])
        case .secondSecondarySubmenuItemPressed: .some(ShieldContext.requestChoices[1])
        case .thirdSecondarySubmenuItemPressed: .some(ShieldContext.requestChoices[2])
        default: nil
        }
        if let minutes = choice {
            _ = context.request(target, minutes: minutes)
            return .defer
        }
        if context.pendingRequest(for: target) != nil, #available(iOS 26.5, *) {
            return .openParentalControlsApp
        }
        return .close
    }
}
