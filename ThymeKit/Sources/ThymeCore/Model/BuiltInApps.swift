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
        // Every Home Screen web app.
        "com.apple.webapp": "Web app",
    ]

    /// iOS's own processes that turn up in Apple's usage data, such as the screenshot editor
    /// (com.apple.ScreenshotServicesService), the call screen and the Face ID prompt: no app scan lists them.
    public static func isSystemProcess(_ bundleID: String) -> Bool {
        guard bundleID.hasPrefix("com.apple."), names[bundleID] == nil else { return false }
        let name = bundleID.split(separator: ".").last?.lowercased() ?? ""
        return name == "springboard" || ["service", "services", "ui"].contains { name.hasSuffix($0) }
    }
}
