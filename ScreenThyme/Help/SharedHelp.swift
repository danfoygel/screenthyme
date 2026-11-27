import Foundation

/// Help for the screens shared by parents' and kids' phones (Components) and for the Debug screens.
extension ScreenHelp {
    // MARK: - A kid's day

    static let timeline = ScreenHelp(
        "Timeline",
        summary: "One day of phone use laid out like a calendar: hours run top to bottom, and each app's use is a "
            + "block at the time it happened.",
        [
            topic(
                "What you see",
                "Each block is one stretch of use of one app, in that app's color, with its name, start time and "
                    + "length when there's room. A fainter block was in use only part of that stretch, alongside "
                    + "other apps.",
                "Blocks used at the same time sit side by side. On today, a red dot and line mark the time now.",
                "Long stretches with nothing to show are cut out, like torn tape, labeled with their times and "
                    + "length, so the day fits on fewer screens.",
                "Labels at the right mark the day's events: a limit used up, **one more minute**, a request for more "
                    + "time and its answer, time ended early, and alerts."
            ),
            topic(
                "The colored line beside the hours",
                "**Placed** (green): the phone checked in on time, so use there is placed to within about a minute.",
                "**Idle** (gray): little or no use, so nothing is drawn.",
                "**No check-ins** (red): Apple counted use there, but the phone didn't check in, so its time is a "
                    + "best guess. Blocks drawn at a guess have a dashed outline.",
                "**Burst** (yellow): check-ins arrived all at once, so the times there aren't exact."
            ),
            topic(
                "What you can do",
                "Tap a block for its exact times and length, or an event's label for what happened.",
                "Pinch to zoom in on a busy hour, or use the **Zoom in** and **Zoom out** buttons. Zooming keeps the "
                    + "time you were looking at in place.",
                "Use the arrows by the date to go back a day, or forward again up to today.",
                "**Options** (•••): **Show websites**, **Hide short use (under 2 min)** and **Show events**. Your "
                    + "zoom and options are remembered."
            ),
            topic(
                "Good to know",
                "How long each app was used comes from Apple's own count. When it was used comes from the phone "
                    + "checking in each minute it's in use.",
                "Pull down to fetch the latest. New use usually shows within a minute or two."
            ),
        ]
    )

    static let categoryTime = ScreenHelp(
        "Categories",
        summary: "One day's use added up by category, such as games, social and entertainment, with each "
            + "category's apps inside it.",
        [
            topic(
                "What you see",
                "**Apps (Apple's count)** is the day's total. **Uncounted**, when shown, is time in apps left out of "
                    + "that total; it still shows in their category.",
                "Each category has its time and a bar, as long as its share compared with the biggest category.",
                "**No category** holds apps Apple hasn't put in one."
            ),
            topic(
                "What you can do",
                "Tap a category to open its list of apps and websites, and tap one of those for its details.",
                "Use the arrows by the date to go back a day, or forward again up to today.",
                "Pull down to fetch the latest."
            ),
            topic(
                "Good to know",
                "Apple puts each app and website in one category, mostly by its App Store category. Parents can "
                    + "move one to another in Screen Time › Categories.",
                "Time a browser spent on a website counts as that website's, not the browser's."
            ),
        ]
    )

    static let pickups = ScreenHelp(
        "Pickups",
        summary: "How often the phone was picked up and how many notifications it got in one day, by app and by "
            + "hour. These are Apple's own counts.",
        [
            topic(
                "What you see",
                "The day's **Pickups**, **Notifications** and **First pickup**. **Without opening an app** counts "
                    + "pickups where no app was opened.",
                "**Apps**: each app's pickups and notifications, in that order.",
                "**By hour**: the same two numbers for each hour of the day."
            ),
            topic(
                "What you can do",
                "Tap an app for its details.",
                "Use the arrows by the date to go back a day, or forward again up to today."
            ),
            topic(
                "Good to know",
                "Apple files each pickup under the first app opened after it.",
                "The note under the totals says when the counts were last updated. Websites have no pickups or "
                    + "notifications of their own."
            ),
        ]
    )

    // MARK: - One app

    /// The parent's version adds where it was used, Edit Screen Time and ending time a parent gave.
    static func appDetails(forParent: Bool) -> ScreenHelp {
        ScreenHelp(
            "App details",
            summary: "Everything about one app or website: whether it's open right now, how much it's been used, "
                + "and the Screen Time rules that cover it.",
            [
                topic(
                    "At the top",
                    "Whether it's **Open now**, in Downtime, over a limit, **Blocked** or on a break, and until when.",
                    "A note under it says when it isn't matched yet: its use or its blocking may not be known."
                ),
                topic(
                    "Use",
                    "Today, yesterday, the last 7 and 30 days, the daily average and when it was last used, from "
                        + "Apple's count. The chart shows each of the last 30 days; the dashed line is the average.",
                    "**When** shows the hours of the week it's used most. Tap a square for its numbers.",
                    "**Raw usage** lists each time the phone found new use of it."
                ),
                topic(
                    "Rules",
                    "**Groups** shows the groups and lists it's in: **Always Allowed**, **Uncounted**, **Blocked**. "
                        + "\"Through…\" means it's in because of a group or its category.",
                    "**Downtime** and **Limits** list what covers it. Each limit shows the time used today across "
                        + "everything it counts, out of the limit plus any extra time given today.",
                    "**More time** lists requests for more time and **one more minute** from the last 30 days, with "
                        + "their answers. Orange means it was self-approved, with no parent's answer."
                ),
                forParent
                    ? topic(
                        "What you can do",
                        "**Where**, when the kid's location is shared, shows where it was used, today or over the "
                            + "last 7 days.",
                        "**End now**, under time you gave that's still running, ends it early: what it let through is "
                            + "blocked again.",
                        "**Edit Screen Time** opens the kid's Downtime, limits and lists.",
                        "Pull down to fetch the latest."
                    )
                    : topic(
                        "Good to know",
                        "ScreenThyme and Phone are always allowed. Only a parent can change the rules.",
                        "Pull down to refresh."
                    ),
            ]
        )
    }

    /// An Always Allowed, Uncounted or Blocked list, or what one Downtime turns off; editable on parents' phones.
    static func selectedItems(_ title: String, canEdit: Bool) -> ScreenHelp {
        ScreenHelp(
            title,
            summary: "The apps, websites and categories in this list. The note at the bottom says what the list does.",
            [
                topic(
                    "What you see",
                    "Groups, categories, apps and websites, each by name. A category covers every app in it.",
                    "Tap an app or website for its details.",
                    "**No longer on the phone**: deleted, or left out of the latest app scan. These no longer block "
                        + "or allow anything."
                ),
                canEdit
                    ? topic(
                        "What you can do",
                        "**Edit** opens the full list of apps, websites, categories and groups to choose from.",
                        "Swipe left on one that's no longer on the phone and tap **Remove**, or tap **Remove these** "
                            + "for all of them."
                    )
                    : topic(
                        "Good to know",
                        "Only a parent can change this list."
                    ),
            ]
        )
    }

    static let batteryUse = ScreenHelp(
        "Battery use",
        summary: "How much of the kid's battery ScreenThyme itself used, one day at a time, newest first.",
        [
            topic(
                "How to read it",
                "**Total**: the day's energy, as a share of a full charge (when the phone's battery size is known) "
                    + "and in mWh.",
                "**Tracking**: the part that checks in while the phone is in use, with its wake-ups and processor "
                    + "time.",
                "**App**: ScreenThyme itself, with how many times it opened and its processor time.",
                "**Updated**: when the phone last sent that day's numbers."
            ),
            topic(
                "Good to know",
                "iOS measures this for ScreenThyme's own work. Work iOS does for it, such as Screen Time's tracking "
                    + "and iCloud transfers, isn't included."
            ),
        ]
    )

    // MARK: - Debug

    static let rawUsage = ScreenHelp(
        "Raw usage",
        summary: "Every usage sample for a day, grouped by the fetch of Apple's numbers that found it. Use it to "
            + "check what the phone actually reported when a timeline or total looks wrong.",
        [
            topic(
                "How to read it",
                "Each section is one fetch: its time and what it found in all. A row is what one app or site gained "
                    + "since the fetch before, with the time window it falls in.",
                "**≈** before a time: older samples that don't record when they were fetched, so the time shown is "
                    + "the end of their window.",
                "The note under the date gives the day's number of fetches and the total."
            ),
            topic(
                "Good to know",
                "Use the arrows to change the day. From an app's details, only that app's samples are shown, "
                    + "starting on the last day it was used.",
                "On a kid's phone this is the phone's own outbox; on a parent's phone, what has synced from the "
                    + "kid's phone."
            ),
        ]
    )

    static let testMode = ScreenHelp(
        "Test mode",
        summary: "Single-phone test mode for development builds: try both roles and several kids on one phone.",
        [
            topic(
                "What you can do",
                "**Role** switches this phone between kid and parent, so it can view its own uploads after a "
                    + "CloudKit round trip.",
                "**Authorization**: **Individual (adult)** lets an adult's phone capture its own use. Capture is the "
                    + "same; parent approval and undeletability come with **Child (Family Sharing)** only.",
                "**Kid identity**: upload as an existing kid, or add a new test kid. Switching stops monitoring and "
                    + "forgets this phone's apps and samples, so start monitoring again afterwards.",
                "**Replay tool** replays a recorded or synthetic day. **Forget test kids on this phone** removes "
                    + "test kids from this phone's data."
            ),
            topic(
                "Good to know",
                "Test data goes to the CloudKit development environment only.",
                "A phone set up as a kid's enters test mode only from the welcome screen."
            ),
        ]
    )

    static let replay = ScreenHelp(
        "Replay",
        summary: "Re-uploads a recorded or synthetic day as any kid, to work on the parent screens, timelines and "
            + "alerts without waiting for real use.",
        [
            topic(
                "Source",
                "**Synthetic day**: a made-up day, such as a school day, fast app switching or a bedtime violation.",
                "**This phone's journal for the chosen day**: this phone's own recorded wake-ups.",
                "**Import trace file…**: a day exported earlier as a trace file."
            ),
            topic(
                "Target",
                "**Day** moves the replay to that date. **Kid** is an existing kid or a new test kid named below.",
                "**Speed**: **Instant**, **Real time** (each fire when the clock reaches it) or **60×** (the same "
                    + "timestamps, delivered fast, to watch alerts arrive).",
                "**Send to**: **This phone only** works in the Simulator without iCloud; **iCloud (family)** "
                    + "uploads to the family's zone."
            ),
            topic(
                "Good to know",
                "**Replay** shows progress in fires sent, and **Stop** ends it early.",
                "Replay tests everything after capture: sync, reconstruction, rules, screens and alerts, but not "
                    + "Screen Time's own wake-ups. Replayed apps' icons show only on the phone that recorded them."
            ),
        ]
    )

    static let cloudRecords = ScreenHelp(
        "CloudKit records",
        summary: "Counts and sizes of every record in the family's iCloud zone, to see what takes up room and how "
            + "fast it grows.",
        [
            topic(
                "What you can do",
                "**Scan iCloud** downloads every record of the family zone; **Scan again** repeats it. It doesn't "
                    + "change what this phone has synced.",
                "Pick a kid in **Kid** to narrow the type and age sections to their records."
            ),
            topic(
                "How to read it",
                "Each row is a count and a size. **By kid** splits them by kid; **Family** is the family's own "
                    + "records, and a removed kid's are listed by id.",
                "**By record type** is largest first; **By age (created)** shows how old the records are.",
                "Sizes count the records' field data only, not CloudKit's own metadata."
            ),
        ]
    )

    static let permissions = ScreenHelp(
        "Permissions",
        summary: "Everything ScreenThyme can ask iOS for, and whether each is allowed. Check here when capture, "
            + "notifications or location seem to have stopped.",
        [
            topic(
                "What you see",
                "**This phone**: each permission it uses, what it's for and its state: **Allowed**, **Off**, "
                    + "**Not asked** or **Unknown**. When one isn't allowed, the row says where to turn it on in "
                    + "Settings.",
                "On a parent's phone, each kid's phone below, as its last heartbeat reported it, with when and the "
                    + "app version.",
                "**Not used on this phone**: the permissions this phone doesn't need, and why."
            ),
            topic(
                "What you can do",
                "A button under a permission iOS hasn't asked about yet brings up its prompt. Once one is off, only "
                    + "Settings can turn it back on.",
                "**Open ScreenThyme in Settings** goes straight there. The screen checks again when you come back, "
                    + "or pull down to refresh."
            ),
            topic(
                "Good to know",
                "A kid's phone sends these with each heartbeat, and parents are notified when one is off.",
                "Low Power Mode pauses Background App Refresh on a kid's phone."
            ),
        ]
    )

    static let dataAccess = ScreenHelp(
        "Data access (S4)",
        summary: "A test of iOS 26.4 data access on this phone: whether it's granted and what Apple's per-app data "
            + "looks like. Nothing here feeds capture or sync.",
        [
            topic(
                "What you can do",
                "**Authorization** shows the current state; with data access it reads approvedWithDataAccess. "
                    + "**Request authorization again** asks once more and logs the answer.",
                "**Today's activity (cached)** and **Today's activity (live)** fetch today's hourly data: minutes, "
                    + "pickups and notifications by hour and by app, and how long the fetch took.",
                "**Installed apps and visited sites** lists Apple's installed apps, visited websites and categories."
            ),
            topic(
                "Good to know",
                "Results show under **Results** and are also appended to s4-results.jsonl in the App Group, to copy "
                    + "off the phone with devicectl.",
                "Visited websites can take 10 s or more, and sometimes never answer."
            ),
        ]
    )

    static let familyDataSpike = ScreenHelp(
        "Family data spike",
        summary: "Checks whether Apple's FamilyActivityData lists (websites, apps and categories, each with a name "
            + "and token) agree with the app scan and its matches. Nothing here feeds enforcement.",
        [
            topic(
                "What you can do",
                "**Visited websites**, **Categories** and **Installed apps (may hang)** each fetch one list on its "
                    + "own and log how long it took, however long that is.",
                "**Test shield**: tap a website or app to shield it with its token, then open it to see whether it's "
                    + "blocked. **Filter** narrows the list; **Clear test shield** removes it."
            ),
            topic(
                "How to read it",
                "Each fetch logs its count, how many have names and tokens that decode, and how its tokens compare "
                    + "with the scan's and their matches.",
                "It also logs how much of Apple's usage data the list covers, and what's missing.",
                "In the test shield list, Apple's icon and name beside a row mean its token decodes in this app."
            ),
            topic(
                "Good to know",
                "Results are also appended to family-data-spike.jsonl in the App Group, to copy off with devicectl.",
                "A stuck list can stay stuck for every app, sometimes until the phone restarts."
            ),
        ]
    )
}
