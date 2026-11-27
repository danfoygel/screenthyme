import Foundation

/// Help for the welcome screen and the kid's phone's screens.
extension ScreenHelp {
    static let welcome = ScreenHelp(
        "Welcome",
        summary: "The first step: say whose phone this is. A parent's phone shows the kids' app use and sets their "
            + "rules; a kid's phone shares its app use with the parents.",
        [
            topic(
                "Choose one",
                "**Set up as parent** makes this a parent's phone: it shows which apps each kid uses, when and for "
                    + "how long, and sets their Downtime and limits.",
                "**Set up as kid's phone** needs the kid's name first. Next, a parent approves Screen Time access "
                    + "on this phone."),
            topic(
                "Good to know",
                "**Single-phone test mode** is for development only: one phone can switch between kid and parent "
                    + "and upload as made-up kids. Leave it off on your family's phones."),
        ])

    static let kidHome = ScreenHelp(
        "ScreenThyme",
        summary: "Your phone's home in ScreenThyme: what Screen Time allows right now, how you've used your apps, "
            + "and whether this phone is sharing its use with your parents.",
        [
            topic(
                "Screen Time",
                "The top shows the rules in effect now: Downtime, breaks, each limit with the time you've used, and "
                    + "the apps that are **Always Allowed**, **Uncounted** or **Blocked**. Tap a list to see its apps.",
                "**Ask for more time** shows up while something is blocked. **Ask to always allow an app** asks for "
                    + "an app to work during Downtime and not count toward limits.",
                "Your requests show here while they wait, then your parents' answers. In a real emergency with no "
                    + "parent to answer, **Can't reach a parent? Approve it myself…** lets you approve it; they're "
                    + "told right away."),
            topic(
                "Your apps",
                "**Apps** shows how long you've used each app and website, and its Downtime and limits. **Day "
                    + "timeline** shows when, as your parents see it. **Time by category** adds up games, social "
                    + "apps and the rest.",
                "**Report a problem** tells us something isn't working right; add screenshots if they help.",
                "Pull down to send this phone's latest use and check for changes."),
            topic(
                "Status and the block page",
                "**Status** says whether Screen Time access is on, whether this phone is monitoring and in the "
                    + "family, when it last woke and uploaded, and whether a parent's phone is nearby.",
                "**One more minute** sets how long that button on a block page lets an app through without asking "
                    + "(1 to 5 minutes). You can use it once a day for each app, and never for Blocked apps."),
            topic(
                "For a parent",
                "**Allow Screen Time access** (or **Allow usage data access**) needs a parent's approval on this "
                    + "phone. After approving, restart the phone once. **Upload now** sends the latest use right away.",
                "**Apps for Screen Time**: scan all apps (again after installing new ones), choose ScreenThyme alone "
                    + "so Downtime never blocks it. This phone matches apps with Apple's Screen Time data by "
                    + "itself, so limits count them.",
                "**Join the family** shows until this phone joins: open the invite link a parent sent to this "
                    + "phone's Apple Account, in Messages or Mail."),
            topic(
                "Parent controls",
                "Scanning apps, choosing ScreenThyme, starting monitoring and **Debug** are "
                    + "locked. A parent unlocks them from their own phone, near this one: Settings › Kids › the "
                    + "kid › Unlock.",
                "The screen shows who unlocked them and until when. They lock again when ScreenThyme leaves the "
                    + "screen, or with **Lock now**."),
        ])

    static let askForTime = ScreenHelp(
        "Ask for more time",
        summary: "Ask your parents for more time on an app that's blocked: by Downtime, a break, a limit, or because "
            + "it's Blocked. They answer from their phones, and the answer shows up here.",
        [
            topic(
                "Sending a request",
                "**Choose the app** opens Apple's list of your apps. A Downtime block page can't tell which app you "
                    + "were opening, so pick it here; without one, you're asking for Downtime off on the whole phone.",
                "Under **How much more time**, set the minutes, or switch on **The rest of today** (or **Until "
                    + "Downtime ends**, **Until the break ends**).",
                "Add a **Note for your parents** if you like, then tap **Send**."),
            topic(
                "Waiting for the answer",
                "While this is open, it checks for an answer every few seconds. It needs the internet, or a "
                    + "parent's phone nearby with ScreenThyme open.",
                "You can tap **Done**: the request keeps waiting, and ScreenThyme's home screen shows it and the "
                    + "answer.",
                "Your parent may give a different amount than you asked for; you'll see both."),
            topic(
                "Can't reach a parent?",
                "For Downtime, breaks and limits, **Approve it myself…** lets you approve your own request in a real "
                    + "emergency. Your parents are alerted right away. It's never offered for Blocked apps."),
        ])

    static let askAlwaysAllow = ScreenHelp(
        "Ask to always allow",
        summary: "Ask your parents to make an app Always Allowed: it then works during Downtime and doesn't count "
            + "toward limits.",
        [
            topic(
                "Sending a request",
                "**Choose the app** opens Apple's list of your apps. If it's already always allowed, the screen "
                    + "says so.",
                "Add a **Note for your parents** if you like (why you need it helps), then tap **Send**.",
                "If you already asked for that app, you'll see that request instead of sending a second one."),
            topic(
                "Waiting for the answer",
                "While this is open, it checks for an answer every few seconds. It needs the internet, or a "
                    + "parent's phone nearby with ScreenThyme open.",
                "You can tap **Done**: the request keeps waiting, and ScreenThyme's home screen shows it and the "
                    + "answer.",
                "Only a parent can say yes to this one: you can't approve it yourself."),
        ])

    static let selfApprove = ScreenHelp(
        "Approve it yourself",
        summary: "For real emergencies only: when you need more time right now and no parent can answer, you can "
            + "approve your own request.",
        [
            topic(
                "When to use it",
                "Only when no parent can answer: they don't pick up or text back, or there's no signal to reach them.",
                "Being bored, wanting to keep playing, or thinking they'd say no is **not** an emergency."),
            topic(
                "How it works",
                "**You'd be approving** shows exactly what you asked for; that's what you'll get.",
                "**Your reason** is required, and your parents will read it. Write a real sentence: **Approve it "
                    + "myself** stays off until you do.",
                "You're asked once more, **Is this really an emergency?**, before it's approved. **Cancel** goes "
                    + "back without approving."),
            topic(
                "What your parents see",
                "They get an alert right away. Their phones mark it as self-approved, with your reason, and show "
                    + "everything you use during that time. Expect to explain it.",
                "If a parent answered first, their answer counts and you'll see **Already answered**."),
        ])

    static let kidApps = ScreenHelp(
        "Apps",
        summary: "The apps and websites you've used in the last 30 days, the ones used most today first.",
        [
            topic(
                "What you see",
                "**When** shows your average use in each hour of the week over the last 4 weeks. Tap a square for "
                    + "its numbers.",
                "Each row shows today's time on the right and the last 30 days' time under its name. Apps and "
                    + "websites used only a few seconds aren't listed.",
                "Tap an app or website for its details: its Downtime and limits, and when you used it."),
            topic(
                "Good to know",
                "Time in a web browser on a website counts as that website's.",
                "A new app shows up once this phone has shared some use of it. Pull down to refresh."),
        ])

    static let kidDebug = ScreenHelp(
        "Debug",
        summary: "Tools for a parent checking that this phone tracks and uploads its use properly. Nothing here "
            + "is needed day to day.",
        [
            topic(
                "What you see",
                "The arrows pick a day. **Today as parents see it** shows that day's use and **Day timeline**; "
                    + "**Journal** lists everything this phone noted that day.",
                "**Wake alarm** shows what keeps tracking going. **Apple's lists of apps and websites** says when "
                    + "ScreenThyme last read Apple's lists of this phone's apps, websites and categories.",
                "**Our battery use** shows how much battery ScreenThyme itself used."),
            topic(
                "What you can do",
                "**Re-register** starts tracking afresh. **Stop monitoring** stops it: nothing is tracked until "
                    + "monitoring starts again.",
                "**List them now** reads Apple's lists again. **Sample and upload now** sends the latest use.",
                "**Export day as trace** saves the day's journal to share for troubleshooting."),
            topic(
                "More screens",
                "**Permissions**, **CloudKit records**, **Data access test**, **Raw usage** and **Apple's report** "
                    + "show the raw data, to compare with ScreenThyme's.",
                "**Places (location test)** tries out where the phone was and where apps got used."),
            topic(
                "Good to know",
                "Debug is a parent control: it locks again when ScreenThyme leaves the screen."),
        ])

    static let debugDayTimeline = ScreenHelp(
        "Day timeline",
        summary: "The chosen day as a calendar, as parents see it: hours top to bottom, each app's use drawn as "
            + "blocks.",
        [
            topic(
                "Reading it",
                "Apps used at the same time sit side by side. Long stretches with nothing used are cut out.",
                "Dashed use is a best guess at when it happened.",
                "Pinch to zoom in or out."),
        ])

    static let appleNumbers = ScreenHelp(
        "Apple's numbers",
        summary: "Apple's own Screen Time totals for the day chosen in Debug, drawn by Apple, to compare with "
            + "ScreenThyme's.",
        [
            topic(
                "What you see",
                "The day's total, then each app and website used for more than a minute, with its time.",
                "For today, it counts up to now."),
        ])

    static let placesTest = ScreenHelp(
        "Places",
        summary: "A test of where this phone has been and where apps got used, for a parent. iOS watches the "
            + "places itself and wakes ScreenThyme only when something changes, to save battery.",
        [
            topic(
                "Setting it up",
                "Switch on **Watch places**. It needs **Location access** set to Always; **Open Settings** goes "
                    + "there.",
                "Type a **Name** and tap **Mark this spot** to add where the phone is now, up to 20 places. Swipe "
                    + "to delete one marked here."),
            topic(
                "What you see",
                "Places marked \"(family)\" are named by parents on their phones and can't be removed here. "
                    + "\"Region\" is what iOS last said about each place.",
                "**Today by place** adds up each app's use at each place. **Stays** lists when the phone was where.",
                "**Events today** lists what iOS reported; the + is how late it told ScreenThyme."),
            topic(
                "Good to know",
                "Parents see where the phone was and where apps got used.",
                "**Clear events** deletes this phone's list of events."),
        ])
}
