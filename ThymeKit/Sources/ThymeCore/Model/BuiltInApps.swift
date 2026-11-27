/// Names of Apple's built-in apps as the phone shows them (the App Store says "Apple Music", and lacks Settings and App Store).
public enum BuiltInApps {
    public static let names: [String: String] = [
        "com.apple.AppStore": "App Store",
        "com.apple.Bridge": "Watch",
        "com.apple.camera": "Camera",
        "com.apple.calculator": "Calculator",
        "com.apple.DocumentsApp": "Files",
        "com.apple.facetime": "FaceTime",
        "com.apple.findmy": "Find My",
        "com.apple.Fitness": "Fitness",
        "com.apple.freeform": "Freeform",
        "com.apple.Health": "Health",
        "com.apple.iBooks": "Books",
        "com.apple.journal": "Journal",
        "com.apple.Maps": "Maps",
        "com.apple.mobilecal": "Calendar",
        "com.apple.MobileAddressBook": "Contacts",
        "com.apple.mobilemail": "Mail",
        "com.apple.mobilenotes": "Notes",
        "com.apple.mobilephone": "Phone",
        "com.apple.mobilesafari": "Safari",
        "com.apple.mobileslideshow": "Photos",
        "com.apple.MobileSMS": "Messages",
        "com.apple.MobileStore": "iTunes Store",
        "com.apple.mobiletimer": "Clock",
        "com.apple.Music": "Music",
        "com.apple.news": "News",
        "com.apple.Passbook": "Wallet",
        "com.apple.podcasts": "Podcasts",
        "com.apple.Preferences": "Settings",
        "com.apple.reminders": "Reminders",
        "com.apple.shortcuts": "Shortcuts",
        "com.apple.tv": "TV",
        "com.apple.VoiceMemos": "Voice Memos",
        "com.apple.weather": "Weather",
        webApp: "Web app",
    ]

    /// Apps iOS lets through every shield: `dmd` logged Phone, Settings and Compass as "unblockable" on a kid's phone
    /// (PLAN.md §16), and the Screen Time unlock screen is iOS's own. A token wouldn't block them, so no scan or match
    /// needs to find them.
    public static let unblockable: Set<String> = [
        "com.apple.mobilephone", "com.apple.Preferences", "com.apple.compass", "com.apple.ScreenTimeUnlock",
    ]

    /// Every Home Screen web app, under one bundle ID: no scan lists it as an app, and its site is a website item.
    public static let webApp = "com.apple.webapp"

    /// Browsers. Apple counts a browser's use twice, under its bundle ID and under the site's domain (Chrome's minutes
    /// matched one site's second for second on a kid's phone), so its blocks can go by the site.
    public static let browsers: Set<String> = [
        "com.apple.mobilesafari", "com.google.chrome.ios", "org.mozilla.ios.Firefox", "org.mozilla.ios.Focus",
        "com.microsoft.msedge", "com.brave.ios.browser", "com.duckduckgo.mobile.ios",
    ]

    /// Apps whose time is a website's too, and whose blocks are matched to one: browsers and Home Screen web apps.
    public static func showsWebsites(_ bundleID: String) -> Bool {
        bundleID == webApp || browsers.contains(bundleID)
    }

    /// iOS's own processes that turn up in Apple's usage data, such as the screenshot editor
    /// (com.apple.ScreenshotServicesService), the call screen, the Face ID prompt, the print dialog
    /// (com.apple.printcenter), Apple Pay's sheet (com.apple.ServicesPaymentAngel), Emergency SOS
    /// (com.apple.SOSBuddy) and permission prompts (com.apple.ContactsUI.LimitedAccessPromptView): no app scan lists them.
    public static func isSystemProcess(_ bundleID: String) -> Bool {
        guard bundleID.hasPrefix("com.apple."), names[bundleID] == nil else { return false }
        let parts = bundleID.dropFirst("com.apple.".count).split(separator: ".").map { $0.lowercased() }
        guard let name = parts.last else { return false }
        return ["springboard", "printcenter"].contains(name)
            || parts.contains { part in
                ["service", "services", "ui", "agent", "angel", "buddy", "sheet"].contains { part.hasSuffix($0) }
            }
    }

    /// iOS's own sheets over another app, such as the Face ID prompt, the screenshot editor or Wallet's pay sheet:
    /// Apple counts their time on top of the app beneath (they never had a fetch to themselves on a kid's phone, and
    /// often took its apps past the fetch's length), so lists and blocks leave them out. The call screen and the Home
    /// Screen are use of their own.
    public static func isOverlay(_ bundleID: String) -> Bool {
        isSystemProcess(bundleID) && !["com.apple.InCallService", "com.apple.springboard"].contains(bundleID)
    }
}
