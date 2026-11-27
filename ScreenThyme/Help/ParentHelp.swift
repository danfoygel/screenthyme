import Foundation

/// Help for the parent's screens: the four tabs, a kid's day and settings, places, matching and history.
extension ScreenHelp {
    static let kids = ScreenHelp(
        "Kids",
        summary: "A card for each kid: what their phone is doing now and how much it has been used today. "
            + "Tap a card to open that kid's day.",
        [
            topic(
                "On each card",
                "**In use** (green) means the phone is being used now, with the app it's probably in and for how "
                    + "long. **Idle** says when it was last used.",
                "**Today** is the day's total so far; below it are the three most used apps.",
                "A green check means the phone is reporting normally. An orange triangle means something needs "
                    + "your attention: open the kid, then **Rules and health**, to see what.",
                "**Nearby** means the kid's phone is talking to this one directly. The battery is the kid's phone's."
            ),
            topic(
                "You may also see",
                "The rules in effect today, like **School rules**. They're orange, with a hand, when a parent chose "
                    + "them instead of the usual schedule.",
                "A moon with **Not used**: how long the phone rested overnight.",
                "**Self-approved more time** (orange): your kid gave themselves more time when no parent answered.",
                "**New apps to match** (orange): apps used since the last match, which limits don't count yet. "
                    + "Match them from the kid's day."
            ),
            topic(
                "Good to know",
                "Kids' phones report within a minute or two of use. This screen refreshes itself every 30 seconds "
                    + "while it's open; pull down to refresh now.",
                "**Uncounted** is time on apps you've chosen to leave out of the day's total.",
                "A kid appears once their phone joins the family. Invite them from **Settings**.",
                "While **Syncing with iCloud** shows, kids or history may be missing, and changes wait until it ends."
            ),
        ]
    )

    static let kidDay = ScreenHelp(
        "A kid's day",
        summary: "Everything about one kid's day: how long the phone was used, when, where, and on which apps. "
            + "Use the arrows at the top to see earlier days.",
        [
            topic(
                "The totals",
                "**Apps (Apple's count)** adds up each app's time as Apple's Screen Time counts it. **Phone in use** "
                    + "is how long the phone was in use, from its own check-ins every minute of use.",
                "**Uncounted** is time on apps you've chosen to leave out of the day's total. Their time still "
                    + "shows under each app."
            ),
            topic(
                "Timeline and charts",
                "The **Timeline** has a strip for when the phone was in use, then a row for each app. A fainter "
                    + "block means the app was in use for only part of that time. Tap a block for its times.",
                "Switch the timeline between **Active hours** and **Whole day**.",
                "**When** shows the average use in each hour of the week over the last 4 weeks. Tap a square for "
                    + "its numbers.",
                "**Where** splits the day's use by place, when your kid's phone shares its location. Name places in "
                    + "the **Places** tab."
            ),
            topic(
                "Apps and websites",
                "Every app and website used that day, most used first. A browser's time on a website counts as the "
                    + "website's. Tap one for its details.",
                "An hourglass marks an app blocked now: indigo for Downtime, orange for a limit used up. On earlier "
                    + "days, orange marks the apps that went over a limit."
            ),
            topic(
                "More",
                "**Day timeline**, **Time by category** and **Pickups and notifications** show the day other ways. "
                    + "**Change history** lists every change to this kid's Screen Time.",
                "**Match new apps with camera** (orange) shows when your kid used apps that limits don't count yet.",
                "**Not installed** lists apps Apple counted time for that aren't on the phone, usually because the "
                    + "time was on their website. Limit or block the website instead.",
                "**Rules and health** opens this kid's Screen Time, phone health and alert rules."
            ),
        ]
    )

    static let alerts = ScreenHelp(
        "Alerts",
        summary: "Everything your kids' phones flagged for you, newest first, and their requests for more time, "
            + "which you can answer right here.",
        [
            topic(
                "Requests for more time",
                "**Approve** gives the time asked for, **Change** lets you give more or less, and **Decline** says "
                    + "no. A request to always allow an app has **Always allow** and **Decline**.",
                "Your answer reaches your kid's phone through iCloud within a minute or two, or at once when the "
                    + "phones are near each other with ScreenThyme open."
            ),
            topic(
                "More time running now",
                "Time given today that may not have run out yet, by a parent or by your kid.",
                "**End now** blocks it again at your kid's next minute of use, or at once when the phone is nearby. "
                    + "The change history keeps both."
            ),
            topic(
                "The alerts",
                "Alerts come from the rules you set (Settings, then the kid, then **Rules**), from each request for "
                    + "more time, and from your kid's phone when it loses Screen Time access.",
                "Under a request's alert you see how it was answered.",
                "Orange with **Self-approved, no parent answered**: your kid gave themselves more time because no "
                    + "parent answered."
            ),
            topic(
                "Good to know",
                "Use the **Kid** picker to see one kid only. Pull down to refresh.",
                "To get alerts as banners, tap **Allow notifications** in Settings."
            ),
        ]
    )

    static let parentSettings = ScreenHelp(
        "Settings",
        summary: "Set up your family and your name, open each kid's rules and health, and find a few tools for "
            + "when something isn't working.",
        [
            topic(
                "Family",
                "**Create family** starts a family on this phone. The other parent opens your invite instead.",
                "**Invite parent or kid** opens Apple's sharing sheet. Invite the other parent and each kid's Apple "
                    + "Account with read/write permission; kids open the link on their own phone.",
                "**Your name** is what your kids call you, like Mom or Dad. Their phone shows it when you answer a "
                    + "request for more time, and the change history names you by it."
            ),
            topic(
                "Kids",
                "Tap a kid for their Screen Time, phone health, parent controls and alert rules."
            ),
            topic(
                "Nearby",
                "**Kids' phones** says which kids' phones are talking to this one directly. With ScreenThyme open "
                    + "on both phones, they swap usage, requests and your answers with no internet needed.",
                "**Waiting for the internet** counts changes made on this phone that reach iCloud once it's back "
                    + "online."
            ),
            topic(
                "Tools",
                "**Bug reports** sets where reports from the bug button go.",
                "**Permissions** lists what this phone has allowed, and what each kid's phone last reported. "
                    + "**CloudKit records** shows what the family has stored in iCloud.",
                "**Allow notifications** lets ScreenThyme show alert banners. **Re-install push subscriptions** "
                    + "sets up iCloud's notifications again, if alerts or updates stop arriving.",
                "**Single-phone test mode** is for development: one phone can then act as a kid or a parent."
            ),
        ]
    )

    static let kidSettings = ScreenHelp(
        "Rules and health",
        summary: "One kid's Screen Time, how their phone is doing, the parent controls on it, and the rules that "
            + "alert you about their use.",
        [
            topic(
                "Health",
                "**All good** in green, or each problem in orange, like Screen Time access turned off or the phone "
                    + "not reporting.",
                "**Last heartbeat** is when the phone last checked in; **Last usage event** the last use it "
                    + "reported. **Ping now** asks it to check in at once, though the request may not get through.",
                "Below that: the phone's battery, Screen Time access, the settings your kid could turn off, and "
                    + "the app version.",
                "**Apps seen**, **Raw usage** and **Raw location** show what the phone sent in detail. **Match apps "
                    + "with camera** and the matches lists show which apps limits can count."
            ),
            topic(
                "Parent controls on your kid's phone",
                "Setup controls on your kid's phone are locked. With ScreenThyme open on it near this phone, "
                    + "**Unlock for 15 minutes** opens them, and **Lock now** locks them again.",
                "They also lock when ScreenThyme leaves the screen on your kid's phone."
            ),
            topic(
                "Battery use",
                "How much of your kid's battery ScreenThyme's own work used today, as iOS measures it. Screen Time "
                    + "tracking and iCloud transfers that iOS does itself aren't included. **Earlier days** shows "
                    + "past days."
            ),
            topic(
                "Rules",
                "Rules alert you when something happens on your kid's phone; they don't block anything. Blocking "
                    + "is under **Screen Time: Downtime, limits, content**.",
                "**Add rule** offers Bedtime, School hours, Daily phone total, Daily app limit, Long session, New "
                    + "app used and Phone offline.",
                "Tap a rule to change it, or swipe it left to delete it. **Off** marks a rule that's turned off."
            ),
        ]
    )

    static let ruleEditor = ScreenHelp(
        "Edit a rule",
        summary: "Choose when this rule alerts you. Tap **Save** to keep it, or **Cancel** to leave it as it was.",
        [
            topic(
                "Bedtime and School hours",
                "An alert when the phone is used between **Starts** and **Ends**, then again every few minutes "
                    + "while it stays in use (**Remind every**).",
                "Pick the **Days** it applies to, or none for every day."
            ),
            topic(
                "Use limits",
                "**Daily phone total** and **Daily app limit**: an alert once the day's use passes the time you "
                    + "set, for the **Whole phone** or the app you pick under **What**.",
                "**Long session**: an alert when one stretch of use lasts longer than the time you set."
            ),
            topic(
                "Other rules",
                "**New app used**: an alert the first time an app or website is used on this phone.",
                "**Phone offline**: an alert when the phone sends no report for the hours you set, counted only "
                    + "during waking hours (**Waking from** to **Waking until**)."
            ),
            topic(
                "Good to know",
                "**Enabled** turns the rule off or on without deleting it.",
                "Rules are checked on your kid's phone at each minute of use, so alerts arrive within a minute or "
                    + "two. **Phone offline** is checked on parents' phones.",
                "Rules only alert you. To block apps, use Downtime and limits in Screen Time."
            ),
        ]
    )

    static let appsSeen = ScreenHelp(
        "Apps seen",
        summary: "Every app, website and category your kid's phone has reported, grouped by kind.",
        [
            topic(
                "What you see",
                "Each one's name, with the identifier Apple uses for it underneath (an app's ID or a website's "
                    + "address).",
                "Tap one for its details: its use, groups, limits and requests for more time."
            ),
        ]
    )

    static let bugReports = ScreenHelp(
        "Bug reports",
        summary: "Where your family's bug reports go: a GitHub repository, and the token each phone files them with.",
        [
            topic(
                "Setting it up",
                "Enter the repository as **owner/repository** and a GitHub token, then tap **Save**.",
                "Use a private repository, and a fine-grained token for that repository only, with Issues and "
                    + "Contents set to Read and write.",
                "To change only the repository, leave the token field empty: the saved token is kept."
            ),
            topic(
                "How reports work",
                "The bug at the top right of every screen, on kids' phones and here, files a report with a picture "
                    + "of the screen. It becomes an issue in this repository, with its screenshots under reports/.",
                "Until this is set up, reports wait on each phone.",
                "Every phone in the family can read the token, so give it access to nothing else."
            ),
        ]
    )

    static let matches = ScreenHelp(
        "Matches",
        summary: "Which of the apps, websites or categories found on your kid's phone have been matched to Apple's "
            + "usage data. Limits count an app's use only once it's matched.",
        [
            topic(
                "What you see",
                "**Matched**: each row shows what your kid's phone calls it, and below, the one in Apple's usage "
                    + "data it was matched to. A wrong match stands out this way.",
                "**Not matched yet**: found on the phone but not matched, usually because it hasn't been used yet."
            ),
            topic(
                "Matching more",
                "An app is matched once it has been used. In Settings, open the kid and tap **Match apps with "
                    + "camera**, with your kid's phone on **Apps for Screen Time**, **Match with a parent's camera**.",
                "Your kid's phone can also match by screenshot, from the same place."
            ),
        ]
    )

    static let categories = ScreenHelp(
        "Categories",
        summary: "Your kid's apps and websites sorted into categories, with each one's use over the last 7 days. "
            + "Move an app to another category to change which Downtime and limits cover it.",
        [
            topic(
                "What you see",
                "Each category with its use over the last 7 days, most used first. Tap one to see its apps and "
                    + "websites.",
                "A browser's time on a website counts as the website's. Apps used less than a minute in the week "
                    + "are left out."
            ),
            topic(
                "Moving an app",
                "Tap an app or website, then pick a category under **Move to**. **(Apple's)** marks the category "
                    + "Apple put it in.",
                "The move is saved at once, for every kid, and shows in each kid's change history. Downtime, "
                    + "limits, Always Allowed and Blocked then treat it as that category's.",
                "**Moved from** (orange) marks an app or website that was moved."
            ),
            topic(
                "Good to know",
                "Categories come from your kid's use: a new one appears once an app in it is used.",
                "While ScreenThyme is syncing with iCloud, moves wait until it finishes."
            ),
        ]
    )

    static let places = ScreenHelp(
        "Places",
        summary: "A map of where your kids' phones stayed over the last 60 days. Name the spots that matter, like "
            + "Home or School, to see how much each app is used there.",
        [
            topic(
                "The map",
                "Blue circles are your family's places. Orange circles are spots where a phone stayed that no place "
                    + "covers, with the number of visits; tap one to name it.",
                "A circle's width shows how unsure iOS was of where the phone was."
            ),
            topic(
                "Places and spots",
                "Tap a place to rename it, change its fence or remove it. Tap a spot under **Not named yet** to "
                    + "name it.",
                "The **Fence** slider sets how far a place reaches: use during a visit inside it counts there. "
                    + "Kids' phones also note arriving and leaving, but iOS misses fences under 100 m.",
                "Kids' phones watch 20 places at most."
            ),
            topic(
                "Good to know",
                "Use the **Kid** picker to see one kid's visits.",
                "Use during a visit no place covers shows as **Other locations**, and use outside any visit as "
                    + "**While moving**.",
                "Visits come from iOS a few minutes after the phone arrives or leaves, sometimes later.",
                "Your kid's phone needs to allow ScreenThyme location Always, with Precise Location."
            ),
        ]
    )

    static let matchAppsWithCamera = ScreenHelp(
        "Match apps with camera",
        summary: "Match the new apps your kid has used, so limits can count them, by reading codes off your kid's "
            + "phone with this phone's camera.",
        [
            topic(
                "How to match",
                "Open ScreenThyme on your kid's phone, near this one, with Wi-Fi or Bluetooth on on both phones. "
                    + "Matching then opens on your kid's phone by itself.",
                "Hold this phone's camera over your kid's screen. It shows several screens of codes in turn "
                    + "(**report 1 of** …); keep the camera on it until it's done.",
                "This phone buzzes each time it has read a whole screen's codes, and your kid's phone moves on to "
                    + "the next. The result shows here at the end."
            ),
            topic(
                "Good to know",
                "Under the status, **codes read** shows how far along the current screen is.",
                "Keep ScreenThyme open on both phones the whole time.",
                "If the camera doesn't show, allow ScreenThyme to use it in the iPhone's Settings app."
            ),
        ]
    )

    static let locationDay = ScreenHelp(
        "Use at a location",
        summary: "How your kid's phone was used at one location on this day: each app's time there, and when the "
            + "phone was there.",
        [
            topic(
                "What you see",
                "**Use (Apple's count)** is the total time on apps there, as Apple's Screen Time counts it.",
                "**Apps and websites**: each one's time there, most first. Tap one for its details.",
                "**Times there**: when the phone arrived and left. Use that straddles arriving or leaving is shared "
                    + "out by the minutes on each side."
            ),
            topic(
                "Locations",
                "A location is one of your family's places, **Other locations** (visits no place covers), or "
                    + "**While moving** (outside any visit)."
            ),
        ]
    )

    static let rawLocation = ScreenHelp(
        "Raw location",
        summary: "Everything your kid's phone reported about where it was on one day, for checking how places "
            + "work. Use the arrows to change the day.",
        [
            topic(
                "What you see",
                "The map numbers each visit, its circle as wide as its accuracy. Blue circles are the family's "
                    + "places.",
                "**Stays**: where the phone was and when, as worked out from its visits and fences.",
                "**Events**: every report, newest first, at the time it happened. Visits show their coordinates, "
                    + "accuracy and the place they matched."
            ),
            topic(
                "Reading the events",
                "**+** is how long after it happened iOS told ScreenThyme. iOS reports each visit when the phone "
                    + "arrives and again when it leaves.",
                "**Entered** and **Left** are fence crossings. **region** is how the phone watches a fence; "
                    + "**monitor** marks iOS's other way, in older events only."
            ),
        ]
    )

    static let changeHistory = ScreenHelp(
        "Change history",
        summary: "Every change to what your kid's phone enforces, by day, with who made it. It opens on the latest "
            + "change.",
        [
            topic(
                "What you see",
                "Each saved change to Screen Time, like Downtime, limits, Always Allowed or Blocked, with what "
                    + "changed. Moves between categories show here too.",
                "Temporary changes are marked in orange with how long they last, then show again when they change "
                    + "back. Changes still to come are under days marked **Coming up**.",
                "Each answer to a request for more time, and time ended early.",
                "Marked **self-approved** (orange): time your kid took when no parent answered, with their reason."
            ),
            topic(
                "Good to know",
                "Each parent is named as they set **Your name** in Settings.",
                "Pull down to refresh."
            ),
        ]
    )
}
