import XCTest

/// The screen map's screenshots (Tools/ScreenMap): walks every screen the Simulator can reach, in single-phone test
/// mode with a replayed synthetic day for a test kid, and saves each as <SCREEN_TOUR_OUT>/<k|p>-<key>.png, named
/// after its box in Tools/ScreenMap/build.py. Run by Tools/ScreenMap/capture.sh from a fresh install, in one go: the
/// tests run in name order, test1Setup first (it makes the test kid and their day), then any of the others, each from
/// a fresh launch.
///
/// Speed: XCUITest waits for the app to idle after each tap, and `-screenTour` turns the app's animations off, so the
/// helpers wait only for what they need next (polling, not `waitForExistence`) and `snap` settles briefly.
@MainActor
final class ScreenTour: XCTestCase {
    let env = ProcessInfo.processInfo.environment
    var out: String { env["SCREEN_TOUR_OUT"] ?? NSTemporaryDirectory() }
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-screenTour"]
        // The replayed day's alerts arrive as banners, which otherwise hold up each tap until they're gone.
        addUIInterruptionMonitor(withDescription: "Notification banner") { banner in
            guard banner.identifier == "NotificationShortLookView" else { return false }
            banner.swipeUp(velocity: .fast)
            return true
        }
        app.launch()
    }

    // MARK: Helpers

    func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 0.3)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        print("TOUR saved \(name)")
    }

    /// Polls `condition` every 0.1 s until it holds or `timeout` passes.
    @discardableResult
    func wait(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return true
    }

    /// `waitForExistence` checks only once a second, even for an element that's already there.
    @discardableResult
    func appear(_ el: XCUIElement, _ timeout: TimeInterval = 5) -> Bool {
        wait(timeout) { el.exists }
    }

    /// The band of the screen a tap reaches: below the top navigation bar (rows scrolled under it are still
    /// "hittable"), above the floating tab bar.
    func band() -> ClosedRange<CGFloat> {
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY - 4 : app.frame.maxY - 30
        let top = max(90, app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? 0)
        return top...max(top, bottom)
    }

    func inView(_ el: XCUIElement, _ band: ClosedRange<CGFloat>) -> Bool {
        // A missing element's properties retry for 2 s before failing.
        el.exists && el.isHittable && band.contains(el.frame.midY)
    }

    /// A button labelled `label` (or starting with it) that a tap reaches now: a row on screen, or a toolbar button
    /// (Save, Done, Cancel, the bug) in the frontmost navigation bar. Rows win, so "Report a problem" is the kid
    /// home's row, not the bug.
    func reachable(_ label: String) -> XCUIElement? {
        let band = band()
        for predicate in [NSPredicate(format: "label == %@", label), NSPredicate(format: "label BEGINSWITH %@", label)] {
            let rows = app.buttons.matching(predicate).allElementsBoundByIndex
            if let el = rows.first(where: { inView($0, band) }) { return el }
            let bars = app.navigationBars.buttons.matching(predicate).allElementsBoundByIndex
            if let el = bars.last(where: { $0.isHittable }) { return el }
        }
        return nil
    }

    /// What's on screen, to tell when a scroll stops moving anything: the end of the list.
    func fingerprint() -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var seen: [String] = []
        func walk(_ s: XCUIElementSnapshot) {
            if s.elementType == .staticText || s.elementType == .button { seen.append("\(s.label)@\(Int(s.frame.minY))") }
            s.children.forEach(walk)
        }
        walk(root)
        return seen
    }

    /// Scrolls the list most of a screen, down (or `up`), with a hold before letting go so it doesn't fling past rows.
    func page(up: Bool = false) {
        let low = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let high = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        (up ? high : low).press(forDuration: 0.05, thenDragTo: up ? low : high, withVelocity: .fast, thenHoldForDuration: 0.1)
    }

    /// Waits for `find` while the screen is still changing (up to `wait`), then pages down to the list's end and back
    /// up to its top, or up first when `above` says so: lists build rows only as they scroll into view.
    func scrollTo(_ what: String, wait: TimeInterval = 1.5, above: () -> Bool = { false },
                  _ find: () -> XCUIElement?) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(wait)
        var shown = fingerprint()
        while true {
            if let el = find() { return el }
            if Date() > deadline { break }
            Thread.sleep(forTimeInterval: 0.15)
            let now = fingerprint()
            if now == shown { break }
            shown = now
        }
        for up in above() ? [true, false] : [false, true] {
            var last = fingerprint()
            for _ in 0..<15 {
                page(up: up)
                if let el = find() { return el }
                let now = fingerprint()
                if now == last { break }
                last = now
            }
        }
        print("TOUR missing \(what)")
        return nil
    }

    /// Taps a button by label (see `reachable`), scrolling to it if need be.
    @discardableResult
    func tap(_ label: String, wait: TimeInterval = 1.5) -> Bool {
        let any = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
        let above = { any.exists && any.frame.midY < self.band().lowerBound }
        guard let el = scrollTo(label, wait: wait, above: above, { reachable(label) }) else { return false }
        el.tap()
        return true
    }

    /// Opens a menu (a `Menu`, or a `Picker` drawn as one) and picks `item`. An element tap doesn't always open a
    /// SwiftUI menu in a form; a press at its leading edge does.
    @discardableResult
    func choose(_ item: String, from menu: String) -> Bool {
        guard let button = scrollTo(menu, { reachable(menu) }) else { return false }
        button.tap()
        let el = app.buttons[item]
        for _ in 0..<3 where !appear(el, 1.5) {
            button.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.1)
        }
        guard el.exists else { print("TOUR missing \(item) in \(menu)"); return false }
        el.tap()
        return true
    }

    func back() {
        guard appear(app.navigationBars.firstMatch, 3),
              let bar = app.navigationBars.allElementsBoundByIndex.last else { return print("TOUR no back button") }
        let named = bar.buttons["BackButton"]
        let b = named.exists ? named : bar.buttons.element(boundBy: 0)
        if appear(b, 3) { b.tap() } else { print("TOUR no back button") }
    }

    func tab(_ name: String) {
        let t = app.tabBars.buttons[name]
        if appear(t) { t.tap() } else { print("TOUR no tab \(name)") }
    }

    /// Turns single-phone test mode on (Welcome or Settings). A SwiftUI toggle flips from a tap on its inner switch.
    func enableTestMode() {
        let t = app.switches["Single-phone test mode"]
        guard scrollTo("Single-phone test mode", wait: 3, { inView(t, band()) ? t : nil }) != nil else { return }
        let on = { (t.value as? String) == "1" }
        for attempt in 0..<3 where !on() {
            if attempt == 0 { t.switches.firstMatch.tap() } else { t.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).press(forDuration: 0.3) }
            wait(1, until: on)
        }
        if !on() { print("TOUR test mode stayed off") }
    }

    /// Opens Test mode from parent Settings, turning test mode on if it's off.
    func openTestMode() {
        tab("Settings")
        if !tap("Test mode") {
            enableTestMode()
            tap("Test mode")
        }
    }

    /// Replays the synthetic school day, on this phone only, for a new test kid "Leo" or for `kid`.
    func replay(onto kid: String?) {
        openTestMode()
        if kid == nil { snap("p-test") }
        tap("Replay tool")
        // The picker reads "Kid, New test kid"; "Kid" alone would match the Kids tab first.
        if let kid { choose(kid, from: "Kid,") } else { snap("p-replay") }
        tap("Replay")
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Replayed'")).firstMatch
        if !appear(done, 30) { print("TOUR replay didn't finish") }
        back(); back()
    }

    /// Leo's Rules and health, from the Kids tab.
    func openLeo(_ row: String? = nil) {
        tab("Kids")
        tap("Leo")
        if let row { tap(row) }
    }

    /// Switches this phone to the kid's role, from parent Settings.
    func becomeKid() {
        openTestMode()
        tap("Kid")
        if !wait(10, until: { !app.tabBars.firstMatch.exists && app.navigationBars["ScreenThyme"].exists }) {
            print("TOUR kid home didn't open")
        }
    }

    // MARK: The tour

    /// Welcome, the parent role, Leo's replayed day with a rule's alerts, and a named place: what the others need.
    func test1Setup() {
        let welcome = app.switches["Single-phone test mode"]
        guard appear(welcome) else { return XCTFail("Start from a fresh install (Welcome)") }
        snap("welcome")
        enableTestMode()
        tap("Set up as parent")
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if appear(allow, 20) { snap("p-notif"); allow.tap() } else { print("TOUR no notifications prompt") }
        tab("Settings")
        snap("p-settings")
        replay(onto: nil)

        // A rule for Leo, then the same day again, so Alerts has alerts.
        openLeo("Rules and health")
        if choose("New app used", from: "Add rule") { tap("Save") }
        back(); back()
        replay(onto: "Leo")

        // Name the most visited spot (the replay's home), so Leo's day has a place besides other locations.
        tab("Places")
        let spot = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "visits ·")).firstMatch
        guard let spot = scrollTo("a spot to name", wait: 3, { inView(spot, band()) ? spot : nil }) else { return }
        spot.tap()
        let name = app.textFields.firstMatch
        if appear(name) {
            name.tap()
            // The Simulator's first keyboard of a run takes a while to come up.
            appear(app.keyboards.firstMatch, 15)
            name.typeText("Home")
        }
        snap("p-placeEditor")
        tap("Save")
        // Below the map: a swipe on it would pan it instead of scrolling the list.
        for _ in 0..<3 {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.62))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)),
                       withVelocity: .fast, thenHoldForDuration: 0.1)
        }
        snap("p-places")
    }

    func test2Kids() {
        tab("Kids")
        snap("p-kids")
        tap("Leo")
        snap("p-kidDay")
        tap("Day timeline")
        let block = app.staticTexts["Roblox"].firstMatch
        let drawn = appear(block)
        snap("p-timeline")
        if drawn {
            block.tap()
            snap("p-popover")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        } else { print("TOUR missing a timeline block") }
        back()
        tap("Time by category")
        snap("p-categories")
        back()
        // The day's Apps row ("Roblox, 1 h 5 min"), not the timeline's block.
        if tap("Roblox,") {
            snap("p-appDetails")
            back()
        }
        if tap("Home,") {
            snap("p-locationDay")
            back()
        }
        if tap("Raw location") {
            snap("p-rawLocation")
            back()
        }
    }

    func test3ScreenTime() {
        openLeo("Rules and health")
        snap("p-kidSettings")
        tap("Screen Time")
        tap("Add Downtime")
        snap("p-downtime")
        tap("Done")
        tap("Save")  // a change for Change history
        tap("Temporary")  // and its change back, still to come
        snap("p-save")
        tap("Save")
        wait(5) { !app.navigationBars.buttons["Revert"].exists }
        snap("p-policy")
        tap("Add limit")
        snap("p-limit")
        tap("Cancel")
        tap("Add group")
        snap("p-group")
        tap("Cancel")
        tap("Bedtime")
        tap("Some apps")
        tap("Included")
        snap("p-select")
        back()
        tap("Cancel")
        tap("Always Allowed")
        snap("p-allowed")
        back()
        tap("Blocked")
        snap("p-blocked")
        back()
        tap("Content & Privacy")
        snap("p-content")
        choose("Limit adult websites", from: "Websites")
        tap("Always allow")
        snap("p-domains")
        back()
        back()
        tap("Change history")
        snap("p-history")
    }

    func test4Rules() {
        openLeo("Rules and health")
        tap("Apps seen")
        snap("p-apps")
        back()
        tap("Raw usage")
        snap("p-raw")
        back()
        if choose("Daily app limit", from: "Add rule") {
            snap("p-rule")
            if tap("What") { snap("p-what"); back() }
            tap("Cancel")
        }
    }

    func test5Settings() {
        tab("Settings")
        tap("Bug reports")
        snap("p-issues")
        back()
        tap("Permissions")
        snap("p-perms")
        back()
        tap("Report a problem")
        if appear(app.navigationBars["Report a problem"]) { snap("p-report") }
        tap("Cancel")
        tab("Alerts")
        snap("p-alerts")
    }

    func test6Kid() {
        becomeKid()
        snap("k-home")
        if tap("Apps") {
            snap("k-apps")
            back()
        }
        tap("Day timeline")
        snap("k-timeline")
        back()
        tap("Time by category")
        snap("k-categories")
        back()
        tap("Report a problem")
        snap("k-report")
        back()
        tap("Test mode")
        snap("k-test")
        back()
        tap("Debug")
        snap("k-debug")
        tap("Permissions")
        snap("k-perms")
        back()
        tap("Day timeline")
        snap("k-day")
        back()
        tap("Data access test")
        snap("k-s4")
        back()
        tap("Match scanned apps")
        snap("k-pairing")
        back()
        tap("Raw usage")
        snap("k-raw")
        back()
        tap("Places (location test)")
        snap("k-places")
        back()
        if tap("Export day as trace"), tap("Share") {
            // The share sheet fills in its rows after it opens.
            appear(app.otherElements["ActivityListView"])
            Thread.sleep(forTimeInterval: 1)
            snap("k-share")
        }
    }

    /// The app opens Ask for more time from a request left in the App Group (SCREEN_TOUR_GROUP), as from a block page.
    func test7AskSheet() {
        // Still a parent's phone when test6Kid didn't run.
        wait(5) { app.tabBars.firstMatch.exists || app.navigationBars.firstMatch.exists }
        if app.tabBars.firstMatch.exists { becomeKid() }
        guard let group = env["SCREEN_TOUR_GROUP"] else { return XCTFail("SCREEN_TOUR_GROUP: the App Group's path") }
        // What a block page's "Ask for more time" leaves for the app, which opens the sheet if it's under a minute old.
        let at = ISO8601DateFormatter.string(from: Date(), timeZone: .gmt, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        try? Data("{\"at\":\"\(at)\"}".utf8).write(to: URL(fileURLWithPath: "\(group)/Library/ScreenThyme/ask.json"))
        app.terminate()
        app.launch()
        guard appear(app.navigationBars["Ask for more time"], 10) else {
            return XCTFail("No Ask for more time sheet: ask.json missing or over a minute old")
        }
        snap("k-ask")
        tap("Choose the app")
        // Apple's picker draws its list a moment after it opens.
        if !appear(app.staticTexts["All Apps & Categories"], 8) { print("TOUR Apple's picker stayed empty") }
        snap("k-choose")
    }
}
