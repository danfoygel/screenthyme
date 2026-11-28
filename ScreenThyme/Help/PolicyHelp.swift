import Foundation

/// Help for a kid's Screen Time policy on a parent's phone and its editors: Downtime, App Limits, groups, choosing
/// apps, Content & Privacy, saving, and rulesets.
extension ScreenHelp {
    // MARK: - The policy

    static let policy = ScreenHelp(
        "Screen Time",
        summary: "Your kid's Screen Time rules: when the phone rests, how long apps can be used each day and what "
            + "never opens. ScreenThyme enforces them on your kid's phone itself, in place of Apple's Screen Time.",
        [
            topic(
                "What you see",
                "**Ruleset** shows the ruleset in effect today and why: its own days, or chosen by a parent for some "
                    + "days (in orange, with who chose it).",
                "**Rulesets** lists each one with its days and how many rules it has. Tap one for its own "
                    + "**Downtime**, **App Limits**, **Blocked**, **Limit warnings** and **Breaks**.",
                "Everything below them, **Categories**, **Groups**, **Always Allowed**, **Uncounted** and **Content & "
                    + "Privacy**, is the same in every ruleset."
            ),
            topic(
                "How the rules fit together",
                "A ruleset's **Downtime** blocks the whole phone, or only some apps, between set times. Its **App "
                    + "Limits** block their apps for the rest of the day once they've been used that long, and its "
                    + "**Blocked** apps never open.",
                "**Always Allowed** apps work during Downtime and breaks and don't count toward limits. ScreenThyme "
                    + "and Phone always work.",
                "**Uncounted** apps, chosen from Always Allowed, are also left out of the day's total.",
                "A ruleset's **Breaks** block everything but Always Allowed apps after a stretch of use, for as long "
                    + "as the break. Your phone doesn't show when a break is running."
            ),
            topic(
                "Saving changes",
                "Your edits, here and on a ruleset's screen, wait until you tap **Save** on either, which asks "
                    + "whether they're permanent or for some days. **Revert** throws them away.",
                "Saved changes go to iCloud, and your kid's phone picks them up at its next check-in, usually within "
                    + "a minute or two of use; sooner when your phones are near each other with ScreenThyme open.",
                "Temporary changes are listed under **Temporary changes** until they change back by themselves at "
                    + "midnight. **Change history** lists every change and who made it.",
                "**Switch ruleset…** and **Categories** save at once, so they're off while you have unsaved edits."
            ),
            topic(
                "Good to know",
                "Turning off the **Enforce** switch at the top lifts every rule on your kid's phone, Content & "
                    + "Privacy included.",
                "Don't set up Screen Time for your kid in the iPhone's Settings: it would take back the usage data "
                    + "ScreenThyme needs.",
                "**Add ruleset** makes a new one, empty or a copy of another. Swipe a ruleset left to delete it, with "
                    + "its rules; the last one can't be deleted. Swipe a group left to delete it."
            ),
        ]
    )

    static let savePolicy = ScreenHelp(
        "Save changes",
        summary: "Choose how long your changes last and check what changed, then tap **Save** to send them to your "
            + "kid's phone.",
        [
            topic(
                "Permanent or temporary",
                "**Permanent** changes stay until someone changes them again.",
                "**Temporary** changes last **Today only** or for up to 30 days from today, then change back by "
                    + "themselves at midnight, on your kid's phone too, even without internet."
            ),
            topic(
                "What changes back",
                "Only what this save changed goes back. Anything changed again before then stays as it was changed.",
                "Until then, the change is listed under **Temporary changes** on the Screen Time screen."
            ),
            topic(
                "After you save",
                "Your kid's phone picks up the changes at its next check-in, usually within a minute or two of use.",
                "The save is noted in **Change history**, with who made it and, for a temporary one, when it changes "
                    + "back.",
                "**Cancel** goes back to your edits without saving them."
            ),
        ]
    )

    // MARK: - Editors

    static let downtimeEditor = ScreenHelp(
        "Downtime",
        summary: "A stretch of time when your kid's phone rests: the whole phone, or only some apps, is blocked from "
            + "one time until another.",
        [
            topic(
                "Setting it up",
                "Give it a **Name**, then choose when it starts (**From**) and ends (**Until**). It can run past "
                    + "midnight, like a bedtime.",
                "**Whole phone** blocks everything but Always Allowed apps, ScreenThyme and Phone. **Some apps** "
                    + "blocks only what's under **Included**, and everything else keeps working.",
                "Under **Days**, turn on the days it's for. With none on, it's every day."
            ),
            topic(
                "How it works",
                "This Downtime belongs to the ruleset whose screen you added it on. Other rulesets keep their own.",
                "A Downtime that runs past midnight belongs to the day it starts, and to that day's ruleset: "
                    + "Friday's bedtime runs into Saturday morning as Friday's.",
                "During Downtime your kid can ask you for more time from the block page, or take one more minute "
                    + "once each Downtime."
            ),
            topic(
                "Good to know",
                "**Done** stays off until it has a name, its start and end differ and, for **Some apps**, something "
                    + "is included.",
                "**Done** adds it to your edits. Tap **Save** to send it to your kid's phone."
            ),
        ]
    )

    static let limitEditor = ScreenHelp(
        "App Limit",
        summary: "How long some apps, or the whole phone, can be used each day. Once the time is used up, they're "
            + "blocked until midnight.",
        [
            topic(
                "Setting it up",
                "**Name** is optional: left empty, the limit is named after what it limits. **On** turns it off and "
                    + "on without deleting it.",
                "Set the time a day with the stepper, 5 minutes a tap; hold **+** or **−** to go faster.",
                "Under **Other days**, give a weekday its own time. Swipe a day left and tap **Same** to go back to "
                    + "the time a day."
            ),
            topic(
                "What it limits",
                "**All apps and websites** counts everything but Always Allowed apps, ScreenThyme and Phone.",
                "Otherwise, tap **Included** to choose apps, websites, categories and groups. Their time adds up "
                    + "toward the one limit.",
                "An iPhone blocks at most 50 apps one by one, for limits, Downtime and Blocked together; the note "
                    + "below warns you past that. Categories and **All apps and websites** have no such cap."
            ),
            topic(
                "How it works",
                "Use is counted as it happens, and the limit blocks within about a minute of being reached.",
                "When it's used up, your kid can ask you for more time from the block page, or take one more minute "
                    + "once a day.",
                "This limit belongs to the ruleset whose screen you added it on, and warns as that ruleset's **Limit "
                    + "warnings** say.",
                "**Done** adds it to your edits. Tap **Save** to send it to your kid's phone."
            ),
        ]
    )

    static let groupEditor = ScreenHelp(
        "Group",
        summary: "Your own collection of apps, websites and categories, so you can name them all at once in "
            + "Downtime, limits, Always Allowed, Uncounted and Blocked.",
        [
            topic(
                "Setting it up",
                "Give the group a **Name**, then tap **Included** to choose what's in it.",
                "An app can be in several groups. A group can't hold other groups."
            ),
            topic(
                "How it works",
                "Everything that uses the group follows it: add an app here, and every Downtime, limit and list that "
                    + "names the group covers it too.",
                "The note under the list says what uses the group now.",
                "Groups are the same in every ruleset. Deleting one, by swiping it left on the Screen Time screen, "
                    + "takes it out of everything that used it."
            ),
            topic(
                "Good to know",
                "**Done** adds it to your edits. Tap **Save** on the Screen Time screen to send it to your kid's phone."
            ),
        ]
    )

    /// Choosing apps, websites, categories and groups for a Downtime, limit, group or list, titled as the screen is.
    static func itemSelection(_ title: String) -> ScreenHelp {
        ScreenHelp(
            title,
            summary: "Tap the apps, websites, categories and groups to include. A checkmark shows each one that's "
                + "chosen.",
            [
                topic(
                    "What you see",
                    "Only what's on your kid's phone is listed: the apps, websites and categories ScreenThyme found "
                        + "there.",
                    "**Categories** are Apple's, or your own sorting of them once you've set up Categories on the "
                        + "Screen Time screen. **Groups** are your own collections.",
                    "**Not matched yet** holds apps ScreenThyme can't search or sort by name yet. They get a name the "
                        + "first time they're used for a minute."
                ),
                topic(
                    "What you can do",
                    "Search by name at the top.",
                    "Tap a row to choose it, and again to take it out. Your choices go back to the screen before; "
                        + "they're sent to your kid's phone when you tap **Save** on the Screen Time screen."
                ),
                topic(
                    "Good to know",
                    "A category covers all its apps, including ones installed later.",
                    "For **Uncounted**, only Always Allowed apps can be chosen.",
                    "With nothing listed, open ScreenThyme on your kid's phone and scan apps under Apps for Screen "
                        + "Time."
                ),
            ]
        )
    }

    // MARK: - Content & Privacy

    static let contentPrivacy = ScreenHelp(
        "Content & Privacy",
        summary: "Limits on what your kid's phone can install, buy, watch, browse and change, the same in every "
            + "ruleset.",
        [
            topic(
                "What's here",
                "**App Store**: block installing or deleting apps and in-app purchases, always ask for the password, "
                    + "and set the highest age rating for apps.",
                "**Media**: block explicit music, podcasts and books, set the highest movie and TV ratings, and "
                    + "block Apple Music.",
                "**Web**: under **Websites**, choose **Unrestricted**, **Limit adult websites** or **Allowed websites "
                    + "only**, then the lists of sites to allow or block.",
                "**Other** and **Changes**: block Siri and Game Center features, and stop changes to accounts, the "
                    + "passcode, cellular settings and the date and time."
            ),
            topic(
                "How it works",
                "Changes wait until you tap **Save** on the Screen Time screen, then reach your kid's phone at its "
                    + "next check-in, usually within a minute or two of use.",
                "They apply only while the **Enforce** switch on the Screen Time screen is on.",
                "**Require automatic date and time** keeps Downtime and limits from being dodged by changing the "
                    + "clock."
            ),
        ]
    )

    /// A web filter's list of sites, titled as the screen is: Always allow, Never allow or Allowed websites.
    static func websiteList(_ title: String) -> ScreenHelp {
        ScreenHelp(
            title,
            summary: "Websites for your kid's web filter, set under **Websites** in Content & Privacy.",
            [
                topic(
                    "The lists",
                    "With **Limit adult websites**, adult sites are filtered out. Sites in **Always allow** open "
                        + "anyway, and sites in **Never allow** never open.",
                    "With **Allowed websites only**, the sites in **Allowed websites** are the only ones that open."
                ),
                topic(
                    "What you can do",
                    "Type a site's address, like example.com, and tap **Add**.",
                    "Swipe a site left to delete it.",
                    "Changes are sent to your kid's phone when you tap **Save** on the Screen Time screen."
                ),
            ]
        )
    }

    // MARK: - Rulesets

    static let switchRuleSet = ScreenHelp(
        "Switch ruleset",
        summary: "Put another ruleset in effect for today or some days, over each day's own, such as for a holiday "
            + "or a trip.",
        [
            topic(
                "What you can do",
                "Tap the ruleset to use. Under each is the days it's normally for.",
                "Choose how long: **Today only**, or up to 30 days from today.",
                "**Switch** saves at once and sends it to your kid's phone.",
                "**Back to each day's own ruleset now**, shown while a switch is running, ends it."
            ),
            topic(
                "How it works",
                "A switch changes only Downtime, App Limits, Blocked, limit warnings and breaks. Everything else is "
                    + "the same in every ruleset.",
                "At the end, each day goes back to its own ruleset by itself, on your kid's phone too, even without "
                    + "internet. A Downtime that began on the last day, like a bedtime, still runs to its end.",
                "The Screen Time screen shows the chosen ruleset in orange, with who chose it and until when. Each "
                    + "switch is noted in **Change history**."
            ),
        ]
    )

    static let ruleSet = ScreenHelp(
        "Ruleset",
        summary: "One ruleset's own rules: its Downtime, App Limits, Blocked apps, limit warnings and breaks, in "
            + "effect on its days or when you switch to it.",
        [
            topic(
                "What you see",
                "**Name and days** says which weekdays the ruleset is for, and whether it's in effect today. Tap it "
                    + "to rename the ruleset or change its days.",
                "**Downtime**, **App Limits** and **Blocked** are this ruleset's own. A limit can show extra time a "
                    + "parent gave today, when your kid asked for more.",
                "Groups, Always Allowed, Uncounted, Categories and Content & Privacy are on the Screen Time screen, "
                    + "the same in every ruleset."
            ),
            topic(
                "Limit warnings",
                "A notification on your kid's phone once a share of a limit's time is used, such as 75%, for each "
                    + "limit in this ruleset. Other rulesets have their own.",
                "**Add a warning**, set its share with the stepper, 5% a tap, and swipe it left to delete it.",
                "Each comes once a day per limit; more time you give starts them over. Your kid's phone asks to allow "
                    + "notifications the next time ScreenThyme is opened there, and you get an alert if they're "
                    + "turned off."
            ),
            topic(
                "Breaks",
                "**Take breaks** blocks everything but Always Allowed apps after a stretch of use, for as long as the "
                    + "break, on the days this ruleset is in effect. Other rulesets have their own.",
                "Set how much use comes before a break and how long the break is with the steppers.",
                "A pause shorter than the break doesn't start the count over. Your kid can ask for more time or take "
                    + "one more minute, as in Downtime. Your phone doesn't show when a break is running."
            ),
            topic(
                "Saving changes",
                "Your edits wait until you tap **Save**, here or on the Screen Time screen, which asks whether "
                    + "they're permanent or for some days. **Revert** throws them away.",
                "Swipe a Downtime, limit or limit warning left to delete it."
            ),
        ]
    )

    /// One ruleset's name and days; a new one also picks what it starts from.
    static func ruleSetEditor(isNew: Bool) -> ScreenHelp {
        ScreenHelp(
            isNew ? "New ruleset" : "Ruleset",
            summary: "A ruleset's name and the days it's in effect.",
            [
                isNew
                    ? topic(
                        "What you can do",
                        "Give it a **Name**.",
                        "**Start from** begins with **No rules**, or a copy of another ruleset's Downtime, limits, "
                            + "Blocked, limit warnings and breaks. It starts as a copy of today's.",
                        "Under **In effect on**, turn on the days this ruleset is for."
                    )
                    : topic(
                        "What you can do",
                        "Change the **Name**.",
                        "Under **In effect on**, turn on the days this ruleset is for.",
                        "Its Downtime, limits, Blocked, limit warnings and breaks are changed on its own screen, "
                            + "where you came from."
                    ),
                topic(
                    "How it works",
                    "Each day belongs to one ruleset at most. A day another ruleset has shows its name; turning it on "
                        + "moves it here (**Moves from …**). A day you turn off goes to the first ruleset.",
                    "With no days, the ruleset is in effect only when you switch to it from the Screen Time screen, "
                        + "as for a trip.",
                    "**Done** adds this to your edits. Tap **Save** to send it to your kid's phone."
                ),
            ]
        )
    }
}
