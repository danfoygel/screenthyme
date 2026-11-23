# ScreenThyme — Security review: how a kid could get around it

An adversarial review (Nov 23, 2026) of capture, enforcement, shields, matching, rules, health checks and the kid's
own screens. The question: if a kid wanted uncounted use, use hidden inside an Always Allowed app or category, or use
counted as something else, where does the design or the code let them?

**The adversary:** a kid with their own unlocked phone and its passcode, curious and patient, who can't run their own
code on it or reach the family's iCloud container, and who may read this public repository. Other family devices and
a borrowed parent's phone are noted but out of scope.

How each finding was checked:
- **[tested]**: reproduced by a throwaway Swift test against ThymeCore.
- **[code]**: plain from the code.
- **[device]**: depends on iOS behaviour, still to try on a phone.

## Tasks

Most severe first. ~~Struck out~~ and ✅: done.

1. ✅ ~~**Put the kid phone's parent controls behind a parent's phone nearby**: Debug (Stop monitoring, Re-register,
   Places), Scan apps, Match apps by screenshot, Choose ScreenThyme, Start monitoring and One more minute's length.~~
   Locked once the phone has the family's link key; a parent's phone unlocks them for 15 minutes over the nearby link
   (`ParentUnlock`, PLAN.md §4.9). Covers findings A1–A5.
2. ✅ ~~**Choose ScreenThyme takes one app only**; the Enforcer ignores an exempt list with more.~~ Finding A1.
3. **Always expect the wake alarm** on a kid phone with data access, whatever its epoch says, and alert parents when
   it's missing (`Heartbeat.expectedActivities` is empty without an epoch). Finding A2.
4. **Require automatic date and time by default** (`Restrictions.requireAutomaticDateAndTime`), and detect clock
   skew: compare CloudKit's own modification dates with records' `at`, and judge staleness by them. Finding B1.
5. **Alert on use while blocked**: an app, website or category gaining use in Apple's data while the applied plan
   shields it and no grant or one more minute covers it. Catches A1, A2, D2, C10 and the PiP and webview cases.
6. **Stop subtracting Always Allowed websites twice** in all-apps totals (`EnforcementPlanner.totalSeconds`): only
   when their browser is counted. Finding D1.
7. **Shield Blocked apps first** within the 50-app cap (`ShieldBudget.fit`), then by use. Finding D2.
8. **Tighten WebMirror's "inside another app"**: require Safari, or a website seen in the same interval. Finding D3.
9. **Run the new-app rule on samples the app takes**, not only the extension's. Finding D4.
10. **Tell parents what the kid's phone exempts and drops**: the number of exempt tokens in heartbeats, and an alert
    when a scan drops a Blocked or limited app. Finding A3.
11. **Notice a broken ScreenThyme exemption**: a block page that names ScreenThyme itself means its token no longer
    works; journal it and alert parents. Follows from task 2.
12. **Authenticate pairing codes**: a MAC from a secret in the App Group (the report extension can read it, the kid
    can't), so screenshots can't be forged. Finding A4.
13. **File bug reports as a bot account or GitHub App**, not the repository owner's token, so the triage workflow's
    owner check on `/approve` means the owner. Finding F1.
14. **Try the [device] findings on a phone**: Picture in Picture, shields over WKWebView pages, a blocked app's token
    after delete and reinstall, Private Browsing's domains, App Clips, and Debug's Re-register tapped repeatedly.
15. **Write parents' guidance** into the policy screen: Always Allowed Safari, Messages, FaceTime, browsers or whole
    categories carries everything inside them (section C); turn on automatic date and time and account locks; the
    kid's other devices aren't covered.

## Findings

### A. Controls on the kid's own phone

1. **Choose ScreenThyme exempted anything. [code]** The "Select ScreenThyme only" picker saved every app picked to
   `exempt-tokens.json`, and the Enforcer let those through Downtime, limits and Blocked. Nothing checked the pick,
   and parents never saw it; use still counted but nothing was shielded. *Fixed by tasks 1–2.*
2. **Debug › Stop monitoring stopped everything, silently. [tested + code]** `stopMonitoring()` with no names stops
   every activity (the wake alarm, `dt.`, `lim.`, `om.end`) and clears the epoch. `ensureMonitoring` then does nothing,
   and heartbeats expect no activities, so `HealthEvaluator` raises nothing. Until ScreenThyme next opened: no Downtime
   starts, no limit events. For good: no wakes, so no all-apps limits, no alerts, "Idle" on parents' phones. *Fixed by
   task 1; task 3 makes it loud if it ever happens another way.*
3. **Scan apps with a partial pick unshielded apps. [code]** Items the last scan picked and this one didn't lose their
   token, so Blocked and per-app limits on them shield nothing (Downtime's category shield still does). Picking them
   again restores them, match and all. Parents see them under "No longer on the phone" only while dropped. *Fixed by
   task 1; task 10 tells parents.*
4. **Match apps by screenshot could be forged. [tested]** The codes carry no secret: the fingerprint can be read off a
   real code and the hash is public. Crafted codes paired a chosen token with any bundle ID. A forged match lets a game
   through Downtime (matched to an app in an Always Allowed category), makes a use-based grant never run out, clears a
   correct match, or moves a category limit onto our own count. Camera matching is much harder to fool. *Gated by
   task 1; task 12 closes it.*
5. **One more minute's length was the kid's setting** (1–5 minutes, once a day per app). *Gated by task 1.*

### B. Clock and environment

1. **Date and time weren't locked by default. [tested + code]** `requireAutomaticDateAndTime` is off by default, and
   nothing else locks it once data access turns Apple's Screen Time off. Moving the clock lifts Downtime at the next
   wake; moving the date resets limits, one more minute and Apple's "today"; a grant timed by the clock never ends if
   the clock goes back; quiet hours follow the kid's clock; and a heartbeat stamped in the future keeps the phone from
   looking stale for as long as it's ahead (`HealthEvaluator` uses the kid's `at`). Task 4.
2. **Offline overnight.** Staleness counts only 7:00–22:00. Enforcement goes on offline, but alerts wait for morning.
3. **iCloud off for ScreenThyme.** The "iCloud off" warning needs iCloud to reach parents, so they hear through
   staleness 3 hours later. Account changes aren't locked by default (`lockAccounts`).
4. **The phone's language. [code, low]** Categories are joined by `localizedDisplayName`, which a language change
   renames. Mostly fails closed (the `lim.` event still enforces), but a category limit past the 18-activity cap counts
   zero.

### C. Use hidden inside allowed things [device]

Apple's data credits time to the app on screen, so whatever runs inside an Always Allowed app is free:
1. **Messages:** iMessage games, and YouTube links that play inline.
2. **FaceTime:** SharePlay screen sharing.
3. **In-app browsers:** an allowed app with a WKWebView browser (the Google app, Gmail) is a free browser. Whether web
   shields reach WKWebView is untested.
4. **Downloaded media:** videos or comics played in an allowed Files, Photos or Books.
5. **Picture in Picture:** whether Apple credits PiP time to the app on screen, and whether a shield stops PiP.
6. **Home Screen web apps** (`com.apple.webapp`, no token): blocking an app doesn't block its website as a web app.
7. **Third-party browsers:** their time is the browser's, in a utility-type category, not the site's.
8. **Private Browsing:** whether Apple still reports its domains.
9. **Other devices:** iPads, Macs and old phones aren't covered, and Apple's Screen Time can't be set up for the kid
   there without taking data access back from ScreenThyme (PLAN.md §15–16).
10. **Apple's family Always Allowed list** (PLAN.md §16), if it returns, passes every ScreenThyme shield, Safari and
    Messages included, with nothing to show it. Task 5 would notice.
11. **ScreenThyme itself** is never blocked (photo picker, maps, the bug report box). Low.

### D. Counting that leaks

1. **Always Allowed websites were subtracted twice. [tested]** `totalSeconds` takes allowed websites off the all-apps
   total even when the browser they ran in is already left out. With Safari and a school site Always Allowed, an hour
   on the site plus an hour of a game counted 0 s; with Productivity & Finance allowed (Safari and the site in it), 30
   minutes of a game counted 0 s. Task 6.
2. **ShieldBudget gave the 50 slots to apps used today. [tested]** Ranked by hour last used, then seconds: a Blocked
   app unused today lost its shield to 50 limited apps used today, and an app just opened, with less use this hour
   than 50 others, stayed unshielded. With a large group limit the kid can keep moving to unshielded apps. Task 7.
3. **WebMirror's "inside another app" test is easy to trip. [tested]** Two apps with the same seconds in an interval
   both count as website mirrors, and mirrors are left out of all-apps limits. Task 8.
4. **New-app alerts get lost. [code]** An item is new only the first time any sampler sees it, and the app's own
   `sampleNow` never runs the RuleEngine: install, use under a minute, open ScreenThyme, and no alert. Task 9.

### E. Miscategorization

1. App categories are the developer's App Store category: a game filed under Education, Entertainment or Utilities
   escapes a Games limit, and an Always Allowed category lets all such apps through.
2. Disguised apps (vaults and private browsers dressed as calculators) sit in Utilities.
3. Website categories are Apple's classifier's: mirrors and proxies of video sites likely land in Other or Utilities.
4. Apps installed after the last scan have no token: only their category or all apps can block them, so a Blocked app
   plus an alternative installed later gets around Blocked.

### F. Trust and infrastructure

1. **Bug reports file with the owner's token. [code]** The private bug repository's triage workflow accepts `/approve`
   from the repository owner, and comments made with the family's token (every family phone can read it from the
   zone) are the owner's. A leaked token can approve plans that the fix task then implements. Kid-written issues also
   appear as the owner's (the triage prompt does resist instructions in them). Task 13.
2. **The family zone is read/write for every phone**, the kid's included. Not exploitable without the team's container
   or a CloudKit API token, but nothing else protects `Policy` and `TimeGrant` records.
3. **A borrowed, unlocked parent's phone** can approve requests and change the policy (change history names the
   parent).
4. **Request notes are the kid's own words** in parents' notifications. Low: the request row names the app from its
   token.

## Done

- Parent controls on kids' phones and the one-app ScreenThyme pick (tasks 1–2): PLAN.md §4.9 and §15.3, `ParentUnlock`
  and `LinkUnlock` in `ThymeKit/Sources/ThymeCore/Link/ParentUnlock.swift`.
