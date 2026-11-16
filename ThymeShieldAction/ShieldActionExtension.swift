import ManagedSettings
import ThymeCore

/// The block page's buttons (PLAN.md §15.2). "Ask for more time" queues a request, sends it to the parents at once
/// and redraws the page, which then says the request is waiting; "Open ScreenThyme" opens the app, which shows the
/// answer.
final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        handle(action, context, context.target(appToken: application), completionHandler)
    }

    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        handle(action, context, context.target(domainToken: webDomain), completionHandler)
    }

    /// Downtime and category limits: the press names only the category.
    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let context = ShieldContext()
        handle(action, context, context.target(categoryToken: category), completionHandler)
    }

    private func handle(_ action: ShieldAction, _ context: ShieldContext, _ target: ShieldContext.Target,
                        _ completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let choice: Int?? = switch action {
        case .secondaryButtonPressed, .firstSecondarySubmenuItemPressed: .some(ShieldContext.requestChoices[0])
        case .secondSecondarySubmenuItemPressed: .some(ShieldContext.requestChoices[1])
        case .thirdSecondarySubmenuItemPressed: .some(ShieldContext.requestChoices[2])
        default: nil
        }
        if let minutes = choice {
            guard context.request(target, minutes: minutes) != nil else {
                try? AppGroup.journal.append(.note("shield action \(action): nothing to ask for on \(target.name)"))
                return completionHandler(.close)
            }
            let config = context.config
            // ManagedSettings calls back once, on its own queue; it isn't declared Sendable.
            nonisolated(unsafe) let completionHandler = completionHandler
            Task {
                do {
                    try await Outbox.sendRequests(config: config)
                } catch {
                    try? AppGroup.journal.append(.note("request send failed: \(error)"))
                }
                completionHandler(.defer)
            }
            return
        }
        if context.pendingRequest(for: target) != nil, #available(iOS 26.5, *) {
            return completionHandler(.openParentalControlsApp)
        }
        completionHandler(.close)
    }
}
