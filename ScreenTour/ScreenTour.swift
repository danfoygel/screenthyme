import XCTest

/// The screen map's screenshots (Tools/ScreenMap): walks every screen the Simulator can reach, in single-phone test
/// mode with a replayed synthetic day for a test kid, and saves each as <SCREEN_TOUR_OUT>/<k|p>-<key>.png, named
/// after its box in Tools/ScreenMap/build.py. Run by Tools/ScreenMap/capture.sh, from a fresh install, in order:
/// test1Parent, test2Kid, then test3AskSheet once the script has left a block page's request for the app.
final class ScreenTour: XCTestCase {
    let out = ProcessInfo.processInfo.environment["SCREEN_TOUR_OUT"] ?? NSTemporaryDirectory()
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
    }

    // MARK: Helpers

    func snap(_ name: String) {
        Thread.sleep(forTimeInterval: 1.2)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
        print("TOUR saved \(name)")
    }

    /// The bottom of the area a tap can reach: the floating tab bar covers the rest.
    var bottom: CGFloat {
        let tabBar = app.tabBars.firstMatch
        return tabBar.exists ? tabBar.frame.minY - 4 : app.frame.maxY - 30
    }

    func query(_ label: String, in q: XCUIElementQuery) -> XCUIElement {
        let exact = q.matching(NSPredicate(format: "label == %@", label)).firstMatch
        if exact.exists { return exact }
        return q.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }

    /// Taps a button by label, scrolling down and then back up until it is on screen: lists build rows only as they
    /// scroll into view.
    @discardableResult
    func tap(_ label: String) -> Bool {
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch.waitForExistence(timeout: 2)
        for i in 0..<16 {
            let el = query(label, in: app.buttons)
            if el.exists && el.isHittable && el.frame.midY < bottom && el.frame.midY > 90 {
                el.tap()
                Thread.sleep(forTimeInterval: 0.5)
                return true
            }
            if i < 8 { app.swipeUp(velocity: .slow) } else { app.swipeDown(velocity: .slow) }
        }
        print("TOUR missing \(label)")
        return false
    }

    /// Opens a menu (a `Menu`, or a `Picker` drawn as one) and picks `item`. An element tap doesn't always open a
    /// SwiftUI menu in a form; a press at its leading edge does.
    @discardableResult
    func choose(_ item: String, from menu: String) -> Bool {
        tap(menu)
        let el = app.buttons[item]
        for _ in 0..<3 where !el.waitForExistence(timeout: 2) {
            query(menu, in: app.buttons).coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).press(forDuration: 0.1)
        }
        guard el.exists else { print("TOUR missing \(item) in \(menu)"); return false }
        el.tap()
        Thread.sleep(forTimeInterval: 0.8)
        return true
    }

    func back() {
        let b = app.navigationBars.allElementsBoundByIndex.last?.buttons.element(boundBy: 0)
        if let b, b.waitForExistence(timeout: 5) { b.tap() } else { print("TOUR no back button") }
        Thread.sleep(forTimeInterval: 0.7)
    }

    func tab(_ name: String) {
        let t = app.tabBars.buttons[name]
        if t.waitForExistence(timeout: 5) { t.tap() } else { print("TOUR no tab \(name)") }
        Thread.sleep(forTimeInterval: 0.6)
    }

    func scrollTop() {
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
    }

    /// Turns single-phone test mode on (Welcome or Settings). A SwiftUI toggle flips from a tap on its inner switch.
    func enableTestMode() {
        let t = app.switches["Single-phone test mode"]
        var tries = 0
        while !(t.exists && t.isHittable && t.frame.midY < bottom) && tries < 8 { app.swipeUp(velocity: .slow); tries += 1 }
        for attempt in 0..<3 where (t.value as? String) != "1" {
            if attempt == 0 { t.switches.firstMatch.tap() } else { t.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).press(forDuration: 0.3) }
            Thread.sleep(forTimeInterval: 0.8)
        }
        if (t.value as? String) != "1" { print("TOUR test mode stayed off") }
    }

    /// Replays the synthetic school day, on this phone only, for a new test kid "Leo" or for `kid`.
    func replay(onto kid: String?) {
        tab("Settings")
        enableTestMode()
        tap("Test mode")
        if kid == nil { snap("p-test") }
        tap("Replay tool")
        // The picker reads "Kid, New test kid"; "Kid" alone would match the Kids tab first.
        if let kid { choose(kid, from: "Kid,") } else { snap("p-replay") }
        tap("Replay")
        let done = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Replayed'")).firstMatch
        if !done.waitForExistence(timeout: 30) { print("TOUR replay didn't finish") }
        back(); back()
        scrollTop()
    }

    // MARK: The tour

    func test1Parent() {
        let welcome = app.switches["Single-phone test mode"]
        guard welcome.waitForExistence(timeout: 5) else { return XCTFail("Start from a fresh install (Welcome)") }
        snap("welcome")
        enableTestMode()
        tap("Set up as parent")
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
        if allow.waitForExistence(timeout: 20) { snap("p-notif"); allow.tap() } else { print("TOUR no notifications prompt") }
        tab("Settings")
        snap("p-settings")
        replay(onto: nil)

        // A rule for Leo, then the same day again, so Alerts has alerts.
        tab("Kids")
        tap("Leo")
        tap("Rules and health")
        if choose("New app used", from: "Add rule") { tap("Save") }
        back(); back()
        replay(onto: "Leo")

        tab("Kids")
        snap("p-kids")
        tap("Leo")
        snap("p-kidDay")
        tap("Day timeline")
        snap("p-timeline")
        let block = app.staticTexts["Roblox"].firstMatch
        if block.waitForExistence(timeout: 5) {
            block.tap()
            snap("p-popover")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        } else { print("TOUR missing a timeline block") }
        back()
        // The day's Apps row ("Roblox, 1 h 5 min"), not the timeline's block.
        if tap("Roblox,") {
            snap("p-appDetails")
            back()
        }
        scrollTop()

        tap("Rules and health")
        snap("p-kidSettings")
        tap("Screen Time")
        tap("Add Downtime")
        snap("p-downtime")
        tap("Done")
        tap("Save")  // a change for Change history
        Thread.sleep(forTimeInterval: 1)
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
        back()
        back()  // to Rules and health; the Content & Privacy draft is dropped

        scrollTop()
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

        tab("Settings")
        tap("Bug reports")
        snap("p-issues")
        back()
        tap("Report a problem")
        Thread.sleep(forTimeInterval: 1)
        snap("p-report")
        tap("Done")
        tab("Alerts")
        snap("p-alerts")
    }

    func test2Kid() {
        tab("Settings")
        enableTestMode()
        tap("Test mode")
        tap("Kid")
        Thread.sleep(forTimeInterval: 2)
        snap("k-home")
        if tap("Apps") {
            snap("k-apps")
            back()
        }
        tap("Report a problem")
        snap("k-report")
        back()
        tap("Test mode")
        snap("k-test")
        back()
        scrollTop()
        tap("Debug")
        snap("k-debug")
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
        if tap("Export day as trace"), tap("Share") { Thread.sleep(forTimeInterval: 1.5); snap("k-share") }
    }

    /// The app opens Ask for more time from the request capture.sh left, as from a block page.
    func test3AskSheet() {
        guard app.navigationBars["Ask for more time"].waitForExistence(timeout: 10) else {
            return XCTFail("No Ask for more time sheet: ask.json missing or over a minute old")
        }
        snap("k-ask")
        tap("Choose the app")
        Thread.sleep(forTimeInterval: 2)
        snap("k-choose")
    }
}
