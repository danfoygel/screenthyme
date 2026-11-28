# ScreenThyme — Plan

Near-real-time, per-app screen time for our kids' iPhones, viewed on the parents' iPhones, and Screen Time limits
that ScreenThyme enforces itself. This file describes the design as built, the platform facts it rests on, and what's
still to build (§6). Section numbers are referenced from the code; keep them stable.

## 1. Problem

Apple's built-in Screen Time has two problems for us:

1. **Precision.** It shows totals per app and per hour, but not *which app was used, when, and for how long*.
2. **Latency.** Kid usage sometimes takes hours or days to reach the parents' phones, because of iCloud Screen Time sync.

An app that reads the usage data can't share the phone with Apple's Screen Time (§15), so ScreenThyme also replaces
Apple's limits.

## 2. Goals and non-goals

**Goals**
- **Every app and website** tracked individually with exact per-app minutes (Apple's own numbers, §13), and nothing
  to hand-pick.
- A **timeline** showing when each app was used, placed to within about a minute of use (§4.2).
- On both parents' phones, about **1 minute** after use to see that the phone is in use and what's being used.
- Push **alerts** for quiet-hours use, daily thresholds, long sessions, new apps, requests for more time, and
  **health**: the kid phone stopped reporting, lost authorization or data access, stopped monitoring, or had a
  setting turned off.
- **Enforcement**: Downtime, app limits, Always Allowed, Blocked and Content & Privacy restrictions, with requests for
  more time answered from a parent's phone (§15).
- History kept **forever**.
- 2 parents and 1–2 kids, all on **iOS 26.4+**.

**Non-goals**
- Mac, iPad or web viewers.
- App Store distribution. This is a family-only app installed with development builds from a paid developer account.
- Content inspection: no screenshots, messages or browsing contents.
- Communication Limits (no API).

## 3. Platform reality (Nov 2026; iOS 27 is current)

| Fact | Consequence |
|---|---|
| **Data access** (iOS 26.4: `approvedWithDataAccess`, `DeviceActivityData.activityData(...)`) gives exact per-app and per-website seconds by **bundle ID and domain**, hourly at finest, fresh to the second. Officially EU-only for customer installs, but it works with development builds on our US accounts, under `.child` too (§13). | This is the capture. Apple's data has no display names and no tokens. |
| Only one app or service holds a phone's usage data. Granting ScreenThyme data access turns Apple's App & Website Activity off; configuring Screen Time for the kid in Settings takes it back (§15, §16). | ScreenThyme replaces Apple's limits; parents must not set Screen Time for the kid in Settings. |
| The **DeviceActivityReport** extension is sandboxed: no network, no App Group writes, no export. It can read the App Group. | Used for on-phone display only: Apple's own numbers. |
| The **DeviceActivityMonitor** extension gets threshold and interval callbacks, can write the App Group, make network requests if it blocks briefly, and has a ~6 MB memory limit and a few seconds per callback. | Our wake-up and capture loop (§4.1). It stays small: JSON files, no SwiftData. |
| At most **20 monitored activities** per app. **Thousands of registered events crash Apple's `UsageTrackingAgent`** on smaller phones (§12). | One wake-alarm activity with 20 events; the rest of the budget is enforcement's. |
| Every registration **replays today's already-passed thresholds**, counted from midnight, in random order, sometimes ~2/s, for up to ~8 minutes. A new authorization grant can restart iOS's count of today's use lower (§16). | The reconstruction treats replays as one burst; the wake alarm calibrates against iOS's count. |
| Threshold delivery is unreliable on iOS 26+ (early, immediate or missed fires). | Fires are only wake-ups and "in use" hints; the minutes come from Apple's data. |
| **Shields need tokens** (`ApplicationToken`, `WebDomainToken`, `ActivityCategoryToken`); tokens are opaque, can't be decoded, and Apple's usage data never includes them. A shield list with more than 50 tokens shields nothing, and 50 apps (and 50 websites) one by one is the cap for all of an app's stores together. | Apple's lists (or an app scan) give tokens, matched to bundle IDs (§15.3, §15.6); `ShieldBudget` keeps within 50. |
| `Label(token)` renders a kid's tokens as names and icons on a parent's phone in the same family (in lists; menu-style `Picker`s draw them blank). | Scanned items show by `Label` until matched. |
| Categories are **Apple's fixed list** (Social, Games, Entertainment, …); each app is in one. | Category limits and totals use them as-is; groups (§15.8) are the parents' own. |
| **`.child` authorization** needs a parent's approval on the kid's phone; the kid then can't delete the app. No callback when it's revoked. After granting it, the phone needs a restart before any Screen Time data reaches apps. | Heartbeats detect tampering (§4.7). |
| `AuthorizationCenter.shared.authorizationStatus` is unreliable in the extension. | The extension never gates on it; a refused fetch says data access is gone. |
| Family Controls **distribution** entitlement is needed for TestFlight and the App Store. | We ship Xcode development builds. |

## 4. Design

### 4.1 Capture (kid's phone)

**The wake alarm.** One `DeviceActivity` activity, `st.<epoch8>.tot`, on a repeating daily schedule, with 20 rolling
total-use thresholds (`includesAllActivity`), one per minute of use: `t.<minute>` (`RollingLadder`,
`Shared/ScreenTime/Roller.swift`). It wakes the monitor extension each minute the phone is in use. The extension
re-registers the next 20 once half are used, and starts over at the first callback of a new day
(`Roller.startDayIfNeeded`; the journal notes "wake alarm: new day"). A fresh registration also adds probes below
today's total to find iOS's count (§16). The alarm's state is App Group `Rolling/activity.json`; the app re-registers
when it's missing or from an earlier day, and the extension rebuilds it from the epoch. Each registration is recorded
as a `LadderEpoch`.

**Each wake** (`ThymeMonitorExtension`):
1. Appends the fire to the day's **journal** (`Journal/journal-<day>.jsonl`, append-only, `flock` + `fsync`), in our
   minutes.
2. Fetches today's per-app data (`Sampler`, ≤ 3 s) and writes the change since the last fetch as `UsageSample`s, plus
   any app or website seen for the first time as a `TrackedItem`. Today's pickups and notifications go in the day's
   `PickupReport` when they changed (§13).
3. Evaluates the alert rules (`RuleEngine`, §4.6) and the data-access check (§16).
4. Rolls the alarm if needed, and reconciles enforcement (`Enforcer.reconcile`, §15.2).
5. Uploads to CloudKit and fetches the kid's rules, policy, answers and family places by name (`Uploader.flush`,
   `KidSync`), waiting at most 3 s. Anything left waits in the outbox for the next wake or the app.
6. Meters its own energy use (§4.10).

The app does the same sampling and upload on launch, background refresh and silent pushes, and registers the alarm
(off the main thread, under a background task; `ensureMonitoring` is throttled to avoid replays). A new authorization
grant stops every activity, so the app re-registers after any authorization request.

### 4.2 Reconstruction (pure Swift, `ThymeKit/Reconstruction`)

**Inputs** for one kid and day: the wake alarm's fires (when the phone was in use), Apple's samples (what was used,
exactly), and tracking starts (minute-0 fires uploaded at each registration).

- **In-use minutes:** each total fire ends one in-use minute. A registration's replay burst is counted as
  "before tracking", not placed. Duplicates and fires faster than wall-clock time are dropped as suspect.
- **Totals** are Apple's: a day's samples for an item add up to its exact total.
- **Placing use in time** (`CheckIns`): the day is split at its check-ins (wakes and fetches). An on-time wake places
  the use it reports on the minutes just before it, shared among the apps reported there. Use in a stretch with no
  wake although Apple counted 2+ minutes ("blind"), or ending in a burst, is drawn at a best guess and marked
  "somewhere in" its window. A coverage line shows how well each stretch is placed.
- **Blocks and runs:** an item's back-to-back pieces merge into one block; gaps of more than 2 minutes end a run.
  Use under 2 minutes is hidden by default.
- **Websites inside apps** (`WebMirror`): Apple reports a website's time under its App Store app's bundle ID too, even
  when the app isn't installed, and under an in-app browser's host app. Apps whose time falls inside Safari's (95% of
  the week) or another app's are left out of all-apps totals and limits. A browser's or Home Screen web app's block is
  named after the website whose time matches its own (Apple counts a browser's use under the site's domain too), and
  lists of use (a kid's day, by place, the kid's own apps) give that time to the site, not the browser (`BrowserSites`).
  Apple also counts a web view inside any other app under its site: ads (googleads.g.doubleclick.net,
  imasdk.googleapis.com) and in-app browsers, beside the app's own time, which already holds it. A banner ad gets as
  much time as the game it sits in. A site's time that no browser in its fetch can account for is the app's: lists,
  blocks and places leave it out. iOS's own sheets over an app (the Face ID prompt, the screenshot editor, Wallet's pay
  sheet: `BuiltInApps.isOverlay`) are counted on top of the app beneath too, so they get no blocks and lists leave them
  out. Limits and shields still go by Apple's numbers.
- **The call screen** (`ItemAliases`): Apple's data has iOS's call screen (`com.apple.InCallService`) apart from Phone.
  Phone's own time is dialing, recents and voicemail; the call screen's is a call with the screen on (phone, FaceTime
  and other apps' calls, which Apple doesn't tell apart). Their seconds never matched, so lists and timelines show the
  call screen's use as Phone's, and like Phone it's never blocked and all-apps limits don't count it.
- **Live status** (`LiveStatus`): "in use" when the latest wake is under 2 minutes old; "probably X" is the app with
  the most use in the latest fetch.
- **Categories** (`CategoryUsage`) and **heatmaps** (`UsageHeatmap`, hour by weekday) come from the same samples.

Raw fires and samples are the source of truth; timelines are derived on the parent's phone (and the kid's own, §4.9),
so better heuristics re-render all of history. `thyme-inspect` runs the same reconstruction on files copied off a
phone.

The wake alarm's total runs about 13 minutes a day below Apple's numbers on both phones; Apple's per-app data matches
Apple's Screen Time.

### 4.3 Sync: CloudKit

- **Topology:** the first parent owns a custom zone `Family` in their private database. A zone-wide `CKShare` adds the
  other parent and each kid's Apple Account (read/write). Records are named `<Type>.<uuid>`, carry a JSON payload and
  are saved with `.allKeys`, so every upload is idempotent.
- **Kid phones** write fires, samples, items, epochs, heartbeats, energy reports, alerts, time requests, extra-minute
  uses and place events. **Parents** write kids, rules, rule sets, policies, policy changes, answers (`TimeGrant`),
  pings, family places, the link key and the issue tracker.
- **Kid phones don't depend on pushes**: the extension fetches `RuleSet.<kid>`, `Policy.<kid>`, `FamilyPlaces` and the
  answers to open requests by name at every wake (`KidSync`; back-to-back wakes within 45 s skip it). A parent's change
  reaches a phone in use within about a minute.
- **Parents** keep a local mirror (`FamilyData`, Application Support/FamilyData): JSON files, fires and samples one per
  kid per day. They fetch zone changes on silent pushes (`CKRecordZoneSubscription` for the owner,
  `CKDatabaseSubscription` on the shared database for participants), on launch and background refresh, and every
  30 s while open. Saves that fail for lack of network wait in `PendingSaves` and retry at every refresh.
- **Alert pushes:** the owner has a `CKQuerySubscription` on `Alert` with visible `notificationInfo` built from the
  record's title and body, so banners arrive without waking the app. A participant parent posts a local notification
  for alerts under an hour old when a silent push's fetch brings them (`Notifier`). Every launch ensures the role's
  subscriptions and checks each result; `Application Support/push-diagnostics.txt` shows what a phone has.
- The mirror carries a snapshot version: bump it when stored types change. It also keeps every fetched record as
  CloudKit sent it (`RawRecordLog`, FamilyData/raw), so a bump decodes those again on the phone (well under a second)
  instead of fetching the whole zone (~15,000 records, about a minute). The log is whole only after a full fetch it
  began, and only while the change token is the one it noted. A full re-fetch keeps showing the old snapshot, saves
  the change token after each page so it resumes, and blocks policy and rule saves until it ends.

### 4.4 Data model (CloudKit record types, `Model/Records.swift` and `Model/Policy.swift`)

| Record | Key fields |
|---|---|
| `Kid` | `id`, `displayName`, `colorIndex`, `deviceName`, `isTest` |
| `TrackedItem` | `id` (derived from kid, kind and identifier, so every phone agrees), `kind` (app/domain/category), `identifier` (bundle ID, domain, category name, or `token:<hash>` for a scanned item), `name?`, `tokenData?`, `category?`, `nickname?`, `firstSeen`, `match?` (a scanned item's item from Apple's data) |
| `LadderEpoch` | `kidID`, `startedAt`, `activityNames` |
| `UsageFire` | `kidID`, `minute`, `firedAt`, `day`, `epochID` (total fires only; minute 0 marks a tracking start) |
| `UsageSample` | `kidID`, `itemID`, `day`, `start`, `end`, `seconds`, `reportedAt` |
| `Heartbeat` | `kidID`, `at`, `source` (fire/backgroundRefresh/ping/launch/manual/nearby), `authStatus`, `activeActivities`, `expectedActivities`, `appVersion`, `backlogCount`, `lastFireAt`, `batteryLevel`, the Settings switches (§4.7), `lastTokenPairing` |
| `EnergyReport` | `kidID`, `day`, `deviceModel`, `monitor` and `app` usage (energy, CPU time, wake-ups, callbacks, launches), `batteryLevel`; one per kid per day, overwritten |
| `PickupReport` | `kidID`, `day`, `updatedAt`, per hour: pickups without an app, first pickup, and each app's pickups and notifications; one per kid per day, overwritten (§13) |
| `Alert` | `kidID`, `ruleID?`, `itemID?`, `at`, `title`, `body` |
| `Rule`, `RuleSet` | a rule's `condition` (§4.6) and `enabled`; `RuleSet.<kid>` holds all of a kid's rules |
| `Policy` | one per kid: rulesets (Downtime, limits, limit warnings, Blocked) and the one chosen, Always Allowed, Uncounted, restrictions, groups, temporary changes (§15.1, §15.15) |
| `PolicyChange` | the kid, time, parent's name, the policy before and after, `until?` (§15.7, §15.10) |
| `TimeRequest`, `TimeGrant` | a request for more time or to always allow (item, reason, minutes, note) and its answer (`TimeGrant.<request id>`) |
| `ExtraMinuteUse` | one more minute taken on the kid's phone (§15.5) |
| `Ping` | a parent's liveness check |
| `LinkKey` | the nearby link's family secret (§17) |
| `IssueTracker` | the bug repository and token (§18) |
| `PlaceEvent`, `FamilyPlaces` | where the kid's phone was, and the family's named places (§19) |

### 4.5 App names

- Items from Apple's data have bundle IDs or domains. Parents' and kids' phones name apps from the App Store's public
  lookup (`itunes.apple.com/lookup?bundleId=`, cached in `app-catalog.json`) or `BuiltInApps`, with icons; websites
  get their site icons. Nicknames override.
- Scanned items (tokens, §15.3) render by `Label(token)`. A matched scanned item is named, sorted and searched by its
  match; a matched app takes its token's icon before the store's.

### 4.6 Alerts

Rules are edited on a parent's phone, published as `RuleSet.<kid>`, and evaluated **on the kid's phone** at each
wake (`RuleEngine`), so an alert doesn't depend on the parent's phone waking up.

| Rule | How it works |
|---|---|
| **Quiet hours** | A wake inside the window → "phone in use" at once, then "still on the phone" every `repeatEvery` minutes, naming the app. |
| **Daily threshold** (whole phone or one app) | Checked at each wake against today's total or Apple's per-app seconds: fires within a minute of use of the limit. |
| **Long session** | The current run of use (from wakes) passes N minutes → alert naming the app with the most seconds in it. |
| **New app** | An app or website never seen on this phone before. |
| **Staleness** | Evaluated on parents' phones (§4.7), with the rule's hours and waking hours. |

The kid's phone also alerts on its own when data access is lost (§16) and for every request for more time (§15.4).
Alerts upload at the same wake and reach the owner's banner within about a minute. Development builds can seed one
test rule of each kind with the `-addTestRules <kid name>` launch argument (CLAUDE.md).

### 4.7 Health and tamper detection

- **Heartbeats** come from wakes, app launches, background refresh (`BGAppRefreshTask`), the nearby link, and
  **pings**: a parent's `Ping` reaches the kid app by silent push, and it answers with a heartbeat ("Ping now" under
  a kid's Health).
- **Each heartbeat reports** authorization status, registered and expected activities, the upload backlog, app version,
  last fire, battery, the last import of Apple's apps list, and the Settings switches the kid can turn off and no app can lock:
  Background App Refresh, cellular data, Local Network (as the nearby link last found it: no API says), Bluetooth,
  iCloud (signed in, on for ScreenThyme), Location (Always and precise, only while places are watched, §19) and Low
  Power Mode (`DevicePermission`, read by `DevicePermissions`). Debug → Permissions lists every permission with this
  phone's answers, and on a parent's phone what each kid's phone last reported.
- **Parents' phones check** (`HealthEvaluator`) and alert at once for: authorization not approved, approved without
  data access, missing activities, no word for more than the staleness rule's hours during waking hours (default 3 h,
  7:00–22:00), and a switch turned off. Warnings: a backlog of 50+, Low Power Mode (which also reports Background App
  Refresh as off, so that alert waits until it's off).
- `.child` authorization keeps the app installed; turning off Background App Refresh or connectivity only delays
  delivery, because data is queued locally.

### 4.8 Parent UI (tabs: Kids, Alerts, Places, Settings)

- **Kids:** a card per kid with live status ("In use · probably YouTube", or "Idle · last active 8:42pm"), the
  ruleset in effect (§15.15), today's total, top apps, a health dot, battery, and counts of new apps to match and apps
  not in the scan.
- **A kid's day:** the timeline (the in-use strip, then one lane per app or website, with pinch to zoom and long blank
  stretches cut) or the same day as a calendar with concurrent apps side by side, and the day's events marked at their
  moment (`DayEvents`: limits used up, which the kid's phone notes as `LimitReached` records when its plan newly
  shields one; one more minute; requests for more time, their answers and early ends; alerts); apps and websites with their
  minutes; Where (§19); Time by category; pickups and notifications (by app and by hour); a usage heatmap; links to
  the change history.
- **An app's details** (§15.9).
- **Alerts:** every alert, with requests for more time answered in place.
- **Places:** §19.
- **Settings:** kids (Screen Time policy, Health with permissions, energy and battery, Ping now, Apps seen, Raw usage,
  Raw location, token matches, Rules), Bug reports, Permissions, CloudKit records (the zone's records by kid, type and
  age), and test mode.

### 4.9 Kid UI

A plain status screen: Screen Time access, monitoring, last upload, and how long one more minute lasts (§15.5), which
the kid sets (it lets one app through for a few minutes, once a day, so it isn't a parent control). It
links to the kid's Apps (used in the last 30 days, each to its details), the day's timeline and Time by category
(built from this phone's App Group as parents see it), the Screen Time section (limits, Always Allowed and Blocked,
ask to always allow), and Report a problem. Setup is for a parent: Screen Time permission, joining the family, the
and the app scan.

**Parent controls** are locked once the phone has the family's link key (§17): the app scan,
choosing ScreenThyme, starting monitoring and Debug. Each of them let a kid get around enforcement: a "ScreenThyme"
pick of other apps let them through every shield, Debug's Stop monitoring stopped every activity with no alert, a scan that left an app out unshielded it. A parent unlocks them from their own phone, nearby
(Settings › Kids › the kid › Unlock), for 15 minutes (`ParentUnlock`, `LinkUnlock`); only a parent's phone sends it,
so there's no request to approve by mistake. The kid's phone keeps the unlock in memory and times it by its own clock
from when it arrived, so it locks when ScreenThyme leaves the foreground, and setting the clock only ends it sooner.
Locking goes back to the top of the screen. Each unlock goes in the journal and in heartbeats
(`Heartbeat.lastParentUnlock`), so the other parent sees it. Camera matching needs a parent anyway and stays open.
Before the link key arrives (first setup) and in single-phone test mode they're open. Debug holds the wake alarm's state, Apple's report for a day (to
compare with ours), the data access test, raw usage, the Places test, uploads, battery use, the journal,
Permissions and CloudKit records.

### 4.10 Our own battery cost

Each extension callback and app wake ends by reading the process's kernel counters (`task_info` `TASK_POWER_INFO_V2`
`task_energy`, in nanojoules, plus `getrusage` CPU time) into a per-day ledger in the App Group (`EnergyMeter`,
`EnergyLedger`). The day's `EnergyReport`, with the battery level, rides along with fire uploads (at most every 15 min)
and every heartbeat. Parents see the battery on the kid card while it's under two hours old, and energy under the
kid's Health, as mWh and, for known batteries, % of a full charge. Not counted: work iOS does for us in its own
processes (Screen Time's usage tracking, CloudKit transfers, `locationd`), and anything a process uses after its last
sample.

Measured at 2-minute wakes: the monitor extension used 2–6 J a day on each kid phone (6–37 mJ per callback), about
0.02% of an iPhone SE's charge; the app used 10–190 J. Wakes come only while the phone is in use, when the screen
draws far more, so the alarm now wakes every minute of use.

## 5. Architecture and project layout

**One app with two roles**, chosen at first launch ("This is a kid's phone" / "This is a parent's phone"): one set of
entitlements, one bundle ID family, simpler provisioning. The layout is in CLAUDE.md.

- **Targets:** the app; `ThymeMonitor` (DeviceActivityMonitor: capture, rules, enforcement, upload); `ThymeReport`
  (DeviceActivityReport, ExtensionKit: Apple's numbers); `ThymeShield` (ShieldConfiguration:
  the block page); `ThymeShieldAction` (ShieldAction: its buttons).
- **ThymeKit** (`ThymeCore`) holds the logic with Swift Testing tests and no Screen Time or CloudKit imports; `Shared/`
  is compiled into the app and the monitor extension; the app targets are thin.
- **Capabilities:** Family Controls and the `family-controls.app-and-website-usage` entitlement (app and monitor
  extension), App Groups, iCloud/CloudKit, Push Notifications, Background Modes (remote notifications, background
  fetch).
- **Deployment target:** iOS 26.4. Swift 6 language mode. Xcode 27.2 (its `devicectl` copies only from an App Group's
  `Library/`, so app files live in `Library/ScreenThyme/`).
- **No third-party dependencies**, and no SwiftData: parents' mirror and the App Group are plain JSON and JSONL files.

## 6. Status

**Built and working on the family's phones:** capture with data access and the one-minute wake alarm; reconstruction,
timeline, calendar, categories and heatmaps; CloudKit family sharing and the parents' mirror; alerts with visible
pushes on the owner's phone; heartbeats, pings and health alerts; enforcement (Downtime, limits, Always Allowed,
Blocked, restrictions, groups, temporary changes, rulesets, change history); the app scan and matching from Apple's lists;
ask for more time and ask to always allow; app details; the nearby link over Wi-Fi and Bluetooth; bug reports
with "fixed" pushes; family places and use by location; energy and battery reports; single-phone test mode, the
replay tool and the screen map.

**To verify on phones:**
- A second parent: the participant's silent push → fetch → local notification, and its latency. There's no second
  parent phone yet.
- A week of capture without opening the app (the extension reportedly stops being invoked after several days without
  the host app launching; background refresh and pushes should keep it going).
- Long-session and new-app alerts in real use.
- One more minute (§15.5): whether the submenu sends only its own actions, and whether `.defer` opens the app once the
  stores stop shielding it.
- Nearby (§17): peer-to-peer Wi-Fi with no network joined, and an offline request → approval → the app unblocking.
- Places (§19): whether a child account can grant Always location, iOS's "keep allowing Always?" prompts, and
  `locationd`'s battery cost (Settings › Battery).
- Rulesets (§15.15): the kid's phone changing ruleset at midnight with no use (the midnight restart), and a switch
  reaching it at its next wake.
- Self-approval and End now (§15.11, §15.12): the alert's push, the kid's phone picking up an end at its next wake,
  and an ended limit grant shielding again.

**To build:**
- Token expiry: nothing handles `TokenExpiryMessage` (iOS 26.5) or prompts a rescan when tokens stop working.
- Time zone changes and DST: day keys and Downtime windows use the phone's calendar; nothing handles or tests a
  change of zone.
- Nearby gaps (§17): parents forwarding a kid's records to CloudKit, parent-to-parent sync, and offline `Rule`
  deletions.
- Bug reports (§18): a report whose issue was opened but whose answer was lost is filed again (a duplicate issue).
- Places (§19): rules by place; decide whether the kid's Debug › Places test stays.
- Cleanup once every kid phone has run it: the retired `tm` matcher's stop (`RetiredTokenMatcher`), the retired
  overflow stores' emptying (journal note "cleared retired overflow stores"), and `CLMonitor`'s retirement
  (`retireMonitor`).

## 7. Testing

- **Unit tests** (ThymeKit, `swift test` on the Mac): journal and outbox, ladder and calibration, reconstruction and
  check-ins, rules, enforcement planning, shield budget, token matching, policy changes and temporary
  changes, app details, the link protocol, places, bug reports, energy, replay and the rest of ThymeCore.
- **Ground truth:** the kid phone's Debug screen shows Apple's report extension next to our numbers.
- **Device tests:** the real kid phones are the only true test environment. The Simulator gets no DeviceActivity
  fires and has no iCloud account.
- **The screen map** (`Tools/ScreenMap`, `ScreenTour`): Simulator screenshots of every screen from test data,
  published to GitHub Pages.

### 7.1 Single-phone test mode (debug builds)

- **Authorization mode:** `.individual` instead of `.child`, so an adult's phone captures its own use. Capture is the
  same; parent approval and undeletability are `.child`-only.
- **Identity override:** "Upload as kid: …" sets the `kidID` on everything the phone uploads; each fake kid has its
  own `Kid` record with `isTest`.
- **Role switch:** the same install switches between kid and parent, so the phone can view its own data after a
  CloudKit round trip. A phone set up as a kid's enters test mode only from the welcome screen, so a kid can't make
  their phone a parent's.
- Test data goes to the CloudKit **development** environment only.

### 7.2 Replay tool

For developing the parent side and the reconstruction without waiting for live use (`ThymeKit/Replay`, Debug →
Replay).

- **Sources:** a day of this phone's journal (also exportable as a trace file for test fixtures), or a synthetic day:
  school day (with visits, for Places), fast app switching, bedtime violation, catch-up burst.
- **Settings:** the kid (any, or a new test kid), the day (a time shift), speed (instant, real time, 60×), and where
  it goes: "This phone only" (works in the Simulator without iCloud) or iCloud.
- Replay exercises the pipeline after capture: sync, reconstruction, rules, UI, alerts. It doesn't test DeviceActivity
  itself, and replayed tokens render only on the phone that recorded them.

## 8. Operations (family-only)

- Builds are Xcode development builds on registered devices; kid phones need Developer Mode. Development profiles
  expire after about a year (each install starts a new one): rebuild and install over the app. Don't delete it
  first: an update keeps the App Group, the app's data and the Screen Time authorization, and deleting loses them.
  An expired build's extensions don't run, so a kid phone captures nothing until it's reinstalled.
- **Install only from a branch that contains the latest `main`**: several sessions install on the kid phones, and an
  older build silently undoes `main`'s work there.
- Bumping the mirror's snapshot version, or changing a stored type, needs every phone updated: old builds ignore new
  policy fields (an old kid build enforces a window for some apps as whole-phone Downtime; an old parent build drops
  groups when it saves).
- After each iOS update, check the health screen; a rescan can re-issue every token (§15.6).
- Device logs (`log collect`) and copied App Groups hold private data: delete them after use.

## 9. Risks

| Risk | Mitigation |
|---|---|
| Apple ends development-build data access, or changes it | Capture depends on it entirely; health alerts say when it's gone |
| A parent configures Screen Time for the kid in Settings, taking data access back | The extension alerts at the first refused fetch (§16); the recovery steps are in §16 |
| iOS drops the wake alarm or misses its midnight restart | App re-registration, the extension's rebuild, `startDayIfNeeded` at any callback, health alerts for missing activities |
| Apps installed since Apple's lists last ran have no token, so can't be shielded one by one | The lists run at every launch and background refresh; category limits and Downtime cover them meanwhile; the kid card counts apps with no token |
| Tokens re-issued by a rescan | Policies follow an app to its new token (§15.3) |
| Kid goes offline to avoid reporting | Data queues and arrives later; staleness alert; the nearby link |

## 10. Open questions

- Which waking hours each kid's staleness rule should use.
- Whether places become a regular feature (rules by place) or stay a test (§19).

## 11. Picker and registration behaviour

- "All Apps & Categories" (`FamilyActivitySelection(includeEntireCategory: true)`) returns individual tokens: on the
  first adult phone 222 apps, 297 websites and 13 categories. It leaves out Settings and Safari (and maybe Find My,
  Clock, Fitness); the picker lists Safari when searched for by name.
- "FamilyControlsAgent" (the approval sheet) shows up in Apple's report as an app.
- `DeviceActivityCenter.stopMonitoring([])` stops **every** activity. Only `Roller.registerAll` does that, on purpose.
- On an adult phone, `.individual` authorization succeeded despite an `authorizationConflict` error, probably from
  another Screen Time app.
- On the adult test phone report tokens compared equal to the scan's; on a `.child` phone with data access they don't
  (§15.6).

## 12. Never register many events

With ~7,300 registered events on a kid's iPhone SE, `UsageTrackingAgent` grew to ~1.7 GB and was killed by jetsam
(`JETSAM_REASON_MEMORY_HIGHWATER`) every 1–2 minutes, so no thresholds were delivered. The same daemon enforces
Screen Time limits. An iPhone 17 survived 19,600 events, but only thanks to its memory. With rolling registrations the
daemon sits at ~8–21 MB; a post-registration replay can spike it (once 286 MB, recovered), so registrations stay
rare. Hence one activity with 20 events (§4.1), and per-limit activities with one event each (§15.2).

## 13. Capture with Apple's data access

| Question | Result |
|---|---|
| Entitlement `family-controls.app-and-website-usage` for development builds | granted to our team; it must be on the app and the monitor extension |
| `approvedWithDataAccess` on a US account | works on an adult (`.individual`) and a child (`.child`) phone, after one re-request (no new prompt type) |
| `DeviceActivityData.activityData(...)` | exact per-app seconds with bundle IDs and domains (no display names, no tokens), including Safari and Settings; hourly is the finest segment; 0.1 s in the app |
| From the monitor extension, in the background | 0.04 s on an iPhone SE; `activitySegments` is declared in the SwiftUI overlay, so `import SwiftUI` |
| `FamilyActivityData` (Debug › Family data spike, a kid's phone, Nov 2026) | `visitedWebDomains`, `installedApplications` and `activityCategories` give every item's name (domain, bundle ID, category) **and its token**, with no picker. Every token was byte for byte the scan's, every token-pairing match agreed, and a visited-websites token shields. Apps and categories are instant. `visitedWebDomains` takes 9–10 s on every call, in a new process or the same one (no caching), once 84 s, and sometimes never returns, even with the app in front. Once stuck it stays stuck for every caller, even a new process (45+ minutes once, until the phone restarted), while apps, categories and capture's `activityData` carry on. It needs a timeout and a retry hours later. The earlier "hangs for 90+ s" was probably that. Gives tokens and matches (§15.3) |

**Pickups and notifications** come in the same fetch: per hour, `firstPickup` and `totalPickupsWithoutApplicationActivity`;
per app, `numberOfPickups` (a pickup is filed under the first app used after it) and `numberOfNotifications`.
Websites and categories have neither. They are filled in under data access, outside Apple's report extension (checked
on a kid's phone, Nov 2026). An hour's first pickup reads as the hour's start when the phone was already in use then;
`longestActivity` mostly reads 0 and isn't used. The kid's phone sends them as one `PickupReport` per day, overwritten
when its counts change and sent with the fires. It names each app by bundle ID too: an app with notifications but no
use has no item yet (its first use makes one, with a "new app" alert).

So the only thresholds are the wake alarm's (§4.1): each wake fetches today's data and uploads the difference since
the last fetch as samples. New apps, Safari and Settings are covered without a scan. Per-app thresholds were removed
(history before `a860884`); old journals' `i.<itemUUID>.<minute>` fires are ignored.

## 14. Rules and alerts delivery

- Silent pushes are rationed: one delivered new rules to the kid app within ~2 minutes once, then nothing for a
  deletion. So rules reach the extension only through the `RuleSet.<kid>` fetch (§4.3), saved to App Group
  `rules.json` under a lock (`KidSync.saveRules`). Parents must publish the rule set after every rule change.
- The owner's banners need the `alerts-visible` subscription; `modifySubscriptions` reports per-subscription failures
  only in its results, so every launch checks each one (§4.3).

## 15. Enforcement: ScreenThyme replaces Apple's Screen Time limits

Granting ScreenThyme data access resets the kid's Apple Downtime, App Limits and Always Allowed; restoring them takes
the data back (§16). So ScreenThyme rebuilds the limits. Nothing usage-based stays Apple's.

### 15.1 Model (ThymeCore, synced as one `Policy.<kid id>` record)

| Part | Meaning |
|---|---|
| Downtime windows | name, start/end minute (may wrap midnight), weekdays (of the day the window starts), and optionally items: none means the whole phone (§15.8) |
| Always Allowed | apps, websites, categories or groups exempt from Downtime and limits |
| Uncounted | some of Always Allowed whose use is left out of the day's total (below); leaving Always Allowed leaves it too |
| App limits | name, items (apps, websites, categories, groups) or **all apps**, minutes per day, optional per-weekday minutes |
| Limit warnings | percentages of a limit's day, for every limit in the ruleset |
| Blocked | items never allowed |
| Groups | the parents' own categories (§15.8) |
| Rulesets | Downtime windows, App limits and Blocked come in rulesets, one in effect each day (§15.15) |
| Restrictions | App Store (install, delete, in-app purchases, password, max rating), media (explicit, movie/TV ratings, books, Apple Music), web filter (unrestricted / limit adult with allow and block lists / allowed sites only), Siri, Game Center (multiplayer, friends), account and passcode locks, cellular locks, automatic date and time |
| Temporary changes | §15.10 |

Targets are scanned items with tokens (§15.3); items from Apple's data have no tokens.

**Uncounted** changes no shield: Always Allowed already passes Downtime and limits. It changes the numbers. The day's
total (`DayTotal`: the kid card's "Today", the day and category screens) and the phone-wide daily-threshold alert
(`RuleEngine`) leave out what Uncounted apps held, by the all-apps count (`Policy.uncountedSeconds`, from
`EnforcementPlanner.totalSeconds`). The total ladder counts all activity, so their Apple seconds come off its minutes
too. Each app's own time, its blocks on the timeline, its category's time and the heatmap still show it.

**More time:** the kid's `TimeRequest` (an item or none, the reason, 5 minutes to 4 hours on a stepper
(`MoreTime.steps`) or the rest of today / until Downtime ends, and an optional note) becomes an Alert. A parent
approves the amount asked or changes it, saved as `TimeGrant.<request id>`.
- For a limit, a grant that names an app (or category) lets only that through for its minutes of use: the limit stays
  used up for everything else, its category and all-apps shields leave the app out, and its use still counts. One that
  names nothing (an all-apps limit's category shield) adds minutes to the limit today, counted from the limit's use
  when it's applied if that was past the limit (`AppliedGrant.baselineSeconds`, `EnforcementPlanner.budget`): 15
  minutes given at 50 of a 30-minute limit run to 65, not 45.
- For Downtime, one that names an app lets only that app through; one that names nothing pauses Downtime on the whole
  phone for that many minutes of the clock, or until the window ends.
- Grants on scanned items with no match, and on the whole phone, run by the clock: Apple's data has no usage for them.
- The alert names what the time is for ("only" for one app, "for everything it counts" for none); parents' Alerts
  list shows what was asked and what was given (`MoreTime.outcome`).

### 15.2 Kid phone

- `EnforcementPlanner` (pure, ThymeCore) computes what should be blocked now from the policy (`Policy.resolved`,
  `Policy.current(at:)`), the clock, today's per-item use (`UsageSnapshot`), limit fires and applied grants: Downtime
  on or off and its exceptions, Downtime for some apps, exhausted limits, blocked items.
- `Enforcer` (Shared) applies the plan to ManagedSettings stores: `restrictions` (restrictions plus blocked items),
  `downtime` (`shield.applicationCategories = .all(except: allowed)`, the same for web), `downtime.some` (§15.8) and
  `limits` (exhausted limits' apps, websites and categories, minus Always Allowed). iOS shows the union.
- DeviceActivity activities (≤ 20 in all, with the wake alarm): one per Downtime window `dt.<id8>` (split `.a`/`.b`
  when it wraps midnight); one per limit `lim.<id8>` with one event at its budget (limit plus grants) over the
  limit's tokens; `om.end` for one more minute (§15.5). Interval starts and ends and limit fires call the Enforcer.
  **Every wake also reconciles**, so a missed callback corrects itself within a minute of use. The Enforcer runs off
  the main thread: registering activities blocks in a synchronous call to Apple's usage-tracking service, which once
  got the app killed by the watchdog.
- **All-apps limits** count Apple's per-app use, less Always Allowed, ScreenThyme, Phone and websites mirrored by
  apps (`WebMirror`), and shield `.all(except: allowed)` in `limits`, like Downtime. They get no `lim.` activity (an
  event over all activity can't leave out Always Allowed), so the wakes end them. Their shield names only a category,
  so one more minute or a request is for the whole phone.
- **A limit whose categories hold an Always Allowed app** gets no `lim.` activity either, and an earlier fire that day
  is ignored: iOS's event would count that app and end the limit early. The wakes end it, up to a minute of use late
  (`EnforcementPlanner.eventCountsAlwaysAllowed`). An unmatched scanned app has no known category, so an Always
  Allowed one still counts in the event.
- A matched scanned item uses its match's numbers; a scanned category counts through its match's name
  (`EnforcementPlanner.categoryNames`). `.all(except:)` takes apps only, so an allowed category lets through the
  scanned apps matched to its apps; unmatched ones stay shielded.
- **Limit warnings:** each reconcile (so every wake) gives the kid's phone a local notification ("15 min left: Social")
  for a limit not yet used up whose use reached one of its ruleset's percentages of today's budget (`LimitWarning`,
  `PolicyRuleSet.limitWarningPercents`, the same for every limit in the ruleset; `current(at:)` copies the one in
  effect's into `Policy.limitWarningPercents`): the highest reached, once a day, remembered with the budget in
  `EnforcementDayState.limitWarnings`, so more time starts them over. The kid app asks for
  notifications at launch once some ruleset has warnings and a limit; heartbeats then carry the answer, and parents are
  alerted when it's off.
- The block page (ShieldConfiguration extension) reads App Group `enforcement.json` to say why: "Downtime until 7:00",
  "Time limit: Social (1 h)", "Not allowed". iOS 26 draws the primary button much lighter than the color given, so
  its label is dark. The secondary button opens ScreenThyme (§15.4), or while one more minute is left, a submenu
  (§15.5).
- The policy, rules and answers arrive by name at wakes and app launches (§4.3), plus the kid app's zone fetch on
  silent pushes and the nearby link (§17).

### 15.3 The app scan

- **Apple's lists** (`InventoryRefresh`, logic in ThymeCore's `FamilyInventory`): under data access,
  `FamilyActivityData` lists every installed app, recently visited website and category with its name and its
  token, byte for byte the picker's (§13). At every launch and background refresh the kid's phone makes each one's
  scanned item, the one a scan would make (the same id), and matches it (`TokenMatching.apply`), so new apps and
  websites need no scan. It never drops a token. Apple's service behind the lists can stop
  answering for every caller for 20+ minutes (websites most often, apps too), and a call can't be cancelled: launch
  never waits on a refresh, each list is waited for 20 s (websites 60 s), and a list still waiting keeps another call
  to it from starting. Websites take about 10 s even when well, so they're listed at most hourly. It also saves ScreenThyme's own token when no scan picked
  one, and its apps list is the last import heartbeats report (§15.6). The journal notes each list ("inventory: …");
  Debug shows when they last ran. The scan below stays as the way back.
- On the kid's phone a parent selects All Apps & Categories once: a token for every installed app, website and
  category, each a `TrackedItem` with identifier `token:<hash>` and no name (`TrackedItem.isScanned`). A second pick
  of ScreenThyme alone gives its own token, which Downtime and limits always let through (`exempt-tokens.json`).
  The pick must be one app, no categories or websites, and the Enforcer ignores a file with more (an older build took
  any pick). It's a parent control (§4.9): once at setup, again only if its token stops working.
  Apps installed later are covered by their category until Apple's lists (or the next scan) give their token.
- The shield extensions can read the App Group but the configuration one can't write it; the action extension can.
- A press on a category shield (Downtime's `.all(except:)`, category limits) calls
  `handle(action:for: ActivityCategoryToken)`: the category, not the app.
- **Shield caps:** a store's `shield.applications` or `webDomains` with more than 50 tokens shields nothing; an
  `.all(except:)` or `.specific(_:except:)` list takes at most 50 exceptions; and 50 apps (and 50 websites) shielded
  one by one is the cap for all stores together. Downtime shields every category except Always Allowed: no app
  list, so no cap. Blocked, Downtime for some apps and exhausted limits share the 50 (`ShieldBudget`): past it, the
  apps used most recently today, and any other that's opened moves up at the next wake. The limit editor warns past
  50 apps. The overflow stores of older builds (`limits.2` …) are emptied once per phone (App Group
  `retired-stores-cleared.json`).
- **A rescan can re-issue every token.** A scan drops only tokens the last scan picked, and a token picked again goes
  back to its item, match and all (tokens picked in Ask for more time are kept). Items it didn't pick lose their
  token but keep their match, so they say what they were. Policies follow an app to its new token
  (`Policy.followingNewTokens`: a scanned item with a token matched to the same app replaces the old one), on the kid's
  phone when it enforces and on parents' phones when they show or save the policy. Items with no new token to follow
  show under "No longer on the phone", by their match's name, and parents can remove them.
- Parents pick scanned items by `Label`, sorted and searched by their match's name; unmatched ones are listed apart.

### 15.4 Ask for more time in ScreenThyme

The block page's "Ask for more time" opens ScreenThyme (`openParentalControlsApp`, iOS 26.5). Just before, the action
extension writes what was blocked (`ask.json`: item and category ids), and the app shows `AskForTimeView`:
- From a limit or Blocked page the app is known. From a Downtime page only the category is, so the kid picks the app
  in Apple's picker; its token matches a scanned item, or becomes one.
- How much (`MoreTimePicker`) and an optional note. With no app chosen, Downtime pauses for the whole phone.
- The screen uploads the request (and sends it nearby) and checks for the answer every 5 s while open. ScreenThyme is
  exempt from Downtime through the scan's ScreenThyme pick.
- **Ask to always allow:** the Screen Time section's "Ask to always allow an app" picks an app the same way and sends
  a request with reason `BlockReason.alwaysAllow`. The parent's row offers Always allow / Decline; approving saves the
  policy with the app Always Allowed (and no longer Blocked, `Policy.applying`) before the grant, which lets nothing
  through by itself.

### 15.5 One more minute

From a Downtime or limit block page the kid can let the app through without asking, like Apple's. The kid's phone
sets how long (1–5 minutes, default 1; `SharedConfig.extraMinutes`); past 1 the item reads "N more minutes". "Ask for
more time" opens a submenu (`secondaryButtonSubmenuItems`, iOS 26.4): **One more minute** / **Ask a parent**. Once
used, the button asks straight away. Never for Blocked apps.
- The press decides what is lifted (`ShieldContext.requestScope`): an app shielded by itself lets that app through; a
  category shield lets the category through; Downtime's shield names no app, so Downtime pauses for the whole phone.
  Once a day per app, or for Downtime once per window (`EnforcementDayState.canTakeExtraMinute`). The block page
  computes the menu for what its press will name (`ShieldContext.pressed`).
- The ShieldAction extension records an `ExtraMinute` in `enforcement-state.json`, runs the `Enforcer` (it compiles
  the Enforcer and `UsageSnapshot`, without Apple's data or SwiftUI), and answers `.defer`, so iOS re-evaluates the
  shield and opens the app.
- Shielded again by `om.end`: schedules count whole minutes and last at least 15, so it's a ~16-minute interval whose
  end warning falls at the first whole minute after the extra time ends; any wake after it also reshields.
- No alert to parents. Each use is journaled and kept as an `ExtraMinuteUse` (App Group `Outbox/extra-minutes.jsonl`),
  uploaded and sent nearby, so an app's details show it on parents' phones.

### 15.6 Matching scanned tokens to Apple's data (`TokenMatching`)

Apple's lists (§15.3) give each installed app, visited website and category its token and its identifier at once, so
each scanned item is matched to the item for its bundle ID, domain or category name (`TokenMatching.apply`). A scanned
item matched elsewhere before loses that match.
- Only scanned items with a token count as matched (`TokenMatching.matchedIDs`): a scan can re-issue every token, and
  a tokenless item's match only says its app needs matching again, to the new token.
- Kid heartbeats carry the last import of Apple's apps list (`Heartbeat.lastTokenPairing`, named for the matching it
  replaced). Parents' phones list the apps used lately that no scanned item matches and that an import since didn't
  match (`TokenMatching.unmatched`) as **Not installed**: Apple files a website's time under its App Store app too.
  Apps nothing blocks (`BuiltInApps.unblockable`: Phone, Settings, Compass, the Screen Time unlock screen) and apps
  that are websites (`WebMirror`) are left out.
- Before Apple's lists, a kid's phone matched tokens itself: one report per bit of each scanned item's number,
  filtered by the scan's tokens, drew QR codes of what it saw, read back from screenshots or by a parent's camera
  over the nearby link. Apple's lists made that unneeded and it was removed, with the minute-of-use matcher before it
  (`tm`, stopped at launch with the old files by `RetiredTokenMatcher`); both are in the git history.

### 15.7 Change history

Every Save on the policy screen that changes something also saves a `PolicyChange.<uuid>`: the kid, the time, the
parent's name (from Settings, else "Parent A"/"Parent B") and the policy before and after. It keeps whole policies, so
it names apps as they're named now (`PolicyEdit.between` diffs them). Screen Time → Change history lists a kid's
changes with each parent's answers to requests, by day, opening on the latest. Only parents' phones read it.

### 15.8 Groups and Downtime for some apps

- **Groups** (`ItemGroup`, `Policy.groups`): a name and apps, websites and Apple's categories. An app may be in
  several; groups don't nest. Limits, Always Allowed, Blocked and Downtime windows name groups by id beside items, so
  a change to a group changes everything that uses it. `Policy.resolved` replaces group ids with their items for the
  planner, Enforcer and block page. Deleting a group removes its uses.
- **Downtime for some apps:** a window with items blocks only those. Whole-phone Downtime is the first window that's
  on; every window for some apps that's on is applied at once (`EnforcementPlan.scopedDowntime`) in `downtime.some`:
  app and website tokens one by one, categories as `.specific(except:)` Always Allowed and granted apps. A window of an
  emptied group blocks nothing (`Policy.downtimeItems`). Its shields name the app or category, so a request or one
  more minute lets just that through until the window ends. Grants and minutes are per window occurrence
  (`AppliedGrant.windowStart`).
- Excepted apps are shared across the windows that are on: an app granted in one passes another's categories too
  (not its own token shield). Rare, and accepted.

### 15.9 An app's details

One screen per app or website (`AppDetailsView`, logic in ThymeCore's `AppDetails`), the same on parents' phones and
the kid's: whether it's blocked now and why; its use (today, yesterday, 7 and 30 days, a daily average, a 30-day
chart and a heatmap); the groups, Always Allowed and Blocked lists it's in; the Downtime windows and limits that cover
it (itself, a group, its category, or the whole phone); the last 30 days' requests and one more minutes for it or its
category; its alert rules; its bundle ID, category and match; and Where it was used (§19). Raw usage opens the raw
list narrowed to the app.
- A matched app is two items, Apple's (usage) and the scan's (the token the policy names); the details cover both and
  every category item for its category.
- Parents open it from a kid's day, Apps seen, Always Allowed and Blocked; the kid from Apps and the Screen Time
  lists.
- Parents' phones work out "blocked now" from what has synced, with `EnforcementPlanner`; the kid's phone reads its
  applied plan. The kid's phone keeps every answer it applied (App Group `grants.jsonl`).

### 15.10 Temporary changes

Save on the policy screen asks whether the changes are permanent or temporary, for 1–30 days counting today ("Today
only" ends at midnight). A temporary save adds a `TemporaryChange` to the policy (`Policy.temporary`): its id (the
`PolicyChange`'s), the midnight it ends, and the policy before and after.
- **The kid's phone changes back by itself**, offline too: `AppGroup.loadPolicy` returns `Policy.current(at:)`, with
  each ended change undone, so the Enforcer, block page and kid screens all see it; the wake alarm's midnight restart
  reconciles. Parents' phones work it out the same way (`FamilyData.policy(for:)`); their next save drops ended changes.
- **Only what the change changed goes back** (`Policy.reverting`), where it still holds: a window, limit or group it
  added goes unless edited since, one it removed comes back, one it changed goes back field by field; list items and
  Content & Privacy settings likewise. A later save of the same thing wins. Changes ending together unwind latest
  first. Temporary changes follow new tokens like the rest of the policy.
- **Change history:** the save says it's temporary and when it changes back; the change back is its own entry
  (`PolicyRevert`), shown under "Coming up" until then. The policy screen lists pending temporary changes.

### 15.11 Self-approval

When no parent can answer (no signal, nobody picks up), the kid can approve their own request for more time, for
what they asked. It's for real emergencies, and the screen says so bluntly; what keeps it rare is that parents see
every use, not a count.
- **Where:** under a request that's waiting, in Ask for more time and in the kid's Screen Time section: "Can't reach
  a parent? Approve it myself…" opens `SelfApproveView`: the warning, what it would approve, a required reason (at least
  `TimeGrant.minimumSelfApprovalReason` characters) and a second "Is this really an emergency?" confirmation. So the
  parents always got the request first.
- **What:** Downtime and limit requests only (`TimeRequest.canSelfApprove`); never Blocked apps (as with one more
  minute) or Always Allow, which changes the policy.
- **How:** a `TimeGrant` the kid's phone writes itself, with `selfApproval` (the reason) and `by` the kid's name. The
  Enforcer applies it like a parent's answer; `Enforcer.apply` refuses a request that already has one, so a parent's
  answer that got there first wins. It's queued in `Outbox/self-grants.jsonl`, uploaded as `TimeGrant.<request id>` (so
  parents' phones see the request as answered) and sent nearby; parents' phones take only self-approved grants from a
  kid's phone.
- **Alert:** "⚠️ <kid> self-approved more time", with what and the reason, at once (pushed like any alert).
- **Parents' phones mark it** in orange: the alert (`TimeGrant.selfApproved(with:from:)` finds its grant by moment), the
  ask alert's outcome ("self-approved, no parent answered"), Change history (with the reason), the app's details and
  the kid's card on Home ("Self-approved more time today"). Usage during the time is recorded as always.
- **Not yet:** there's no cap or switch to turn it off per kid. A parent can end it early (§15.12).
- Race: a parent answering in the same seconds overwrites the `TimeGrant` record; the kid's phone keeps what it
  applied first and the alert stays.

### 15.12 Ending more time early

A parent can end any approval that may still be running, theirs, another parent's or the kid's own.
- **Where:** Alerts › "More time running now" (approvals today still within their minutes of the clock, or for the
  rest of the day or window: `TimeGrant.mightBeRunning`), and an app's details under More time. "End now" asks first.
- **How:** the parent saves the same `TimeGrant.<request id>` again with `endedAt` and `endedBy`; everything else
  stays, so a self-approval stays marked. It goes nearby too. The kid's phone fetches today's running approvals by name
  at its wakes (`KidSync.runningGrants`, with the policy), and `Enforcer.apply` records the end on the grant it
  applied and reconciles: from `endedAt` the grant lets nothing through (`EnforcementPlanner.isLeft`). A limit grant
  for no app (extra minutes on the limit) keeps only the minutes of the clock it ran, at most its own, so the limit
  is used up again at once unless other time is left.
- An end is final: a parent's mirror doesn't take a copy without it over one with it (the kid's phone resends its
  self-approvals nearby).
- Shown as "‹parent› ended it early" in Alerts, Change history, the app's details and the kid's Screen Time section.

### 15.13 Mandatory breaks

A parent can make the kid take breaks (`Policy.breaks`, a `BreakRule`; the policy screen's Breaks section): after
`useMinutes` of use (45 by default) with no rest of `breakMinutes` (15), everything but Always Allowed is blocked for
`breakMinutes` of the clock.
- **Counting:** use as all-apps limits count it (Apple's per-app use minus Always Allowed, ScreenThyme, Phone and
  mirrored apps). `BreakTracker` (in `EnforcementDayState`) takes in each reconcile's count: a stretch begins at the
  first growth after a rest and ends only with a rest as long as the break, measured as clock time between wakes that
  saw the count grow; shorter pauses don't start it over. Use during a break starts no stretch, and a stretch after a
  break counts from its end. A new day starts over.
- **Shield:** while `EnforcementPlan.breakTime` is on, the `breaks` store shields every category but
  `breakExceptions`, like whole-phone Downtime. Its block page says "Break time" until the end (`BlockReason.breakTime`);
  Downtime, limits and Blocked explain a shield first, since they last longer.
- **Ending:** with no use there are no wakes, so `brk.end` is an alarm at the break's end, built like one more
  minute's `om.end` (an end warning; a longer interval when the break is longer than 15 minutes). Its callback ends a
  break due within 30 s and reconciles.
- **More time:** as for whole-phone Downtime: a request, self-approval or one more minute that names an app lets it
  through; one that names nothing lifts the break while it has time left (the break still ends on time). One more
  minute is once per break. Grants and minutes from an earlier break don't count.
- Changes show in the change history and go back with temporary changes. Parents' phones don't see the kid's breaks
  yet: the state stays on the kid's phone.

### 15.14 Custom categories

- Apple's categories, as the parents sort them (`CustomCategories`): a group per Apple category (`ItemGroup.category`),
  holding Apple's category items for it (`items`, its own and scanned ones) and the apps and websites moved into it
  from another (`moved`, Apple's items). Ids are stable (kid + name), so parents' phones agree. A parent's phone sets
  them up at launch for kids with a policy, and when Screen Time › Categories opens (`Policy.withCustomCategories`):
  one per category the kid's phone has seen, and every use of an Apple category in Downtime, limits, Always Allowed,
  Uncounted and Blocked (and what temporary changes change back to) then names its custom category. The parents' own
  groups keep Apple's categories (groups don't nest); those stand for the custom ones anyway.
- Screen Time › Categories lists each with its last 7 days' use (a browser's time on websites is the sites'), opening
  to its apps and websites, most used first; a tap moves one to another category, saved at once. Moves are in the
  change history (`PolicyEdit.categoryMove`). Pickers offer the custom categories, not Apple's.
- Moves are the family's, not one kid's (`FamilyCategoryMoves`): an app or website, by bundle ID or domain, is in the
  same custom category for every kid. Each kid's policy keeps its own copy (what its phone enforces, so kid phones
  are unchanged): a move saves every kid's policy that has the app (`Policy.withFamilyMoves`, adding the category
  where that kid's phone hasn't seen it), and set-up gives a kid the family's moves for apps it starts using later.
  The family's moves are read back from the policies: where they disagree (moves made before they were shared), a
  move beats none and the newest policy's wins.
- Enforcement never goes by Apple's categories alone. A moved app counts with its new category (`categorizing`),
  is shielded by its token with it (`Policy.resolved(items:)` adds the moved-in apps and the scanned items holding
  their tokens wherever their category is named), and is let through its Apple category's shields (`movedOut`, as
  `.specific(except:)`). iOS's threshold event can't leave an app out of a category, so a limit whose categories lost
  an app gets none: the wakes end it from our own count, up to a minute late (`EnforcementPlanner.eventMiscounts`).
- A kid's phone on an older build sees the groups as plain groups of Apple's categories: what it enforced before,
  without the moves.

### 15.15 Rulesets

Downtime, limits and Blocked differ by day (school days, weekends, a trip); the rest doesn't. So a kid's policy holds
rulesets (`Policy.ruleSets`, `PolicyRuleSet`): a name, weekdays, and its own Downtime windows, limits, limit warnings
and Blocked. Warnings saved before rulesets had their own (the policy's, for every ruleset) load into each ruleset.
Groups, custom categories, Always Allowed, Uncounted, breaks and Content & Privacy are the policy's, the same in every
ruleset.
- **Which is in effect:** exactly one each day (`Policy.ruleSet(on:)`): the one a parent chose for that day
  (`ruleSetChoice`), else the one whose weekdays hold it, else the first. A weekday is in one ruleset at most (saving
  one's days takes them from the others); one with no days is in effect only when chosen.
- **Defaults:** Weekday (Monday to Friday), Weekend (Saturday, Sunday) and Travel (only when chosen), each a copy of
  the Downtime, limits and Blocked the policy had, so nothing changes until a parent edits one
  (`Policy.withDefaultRuleSets`). Weekday keeps the windows' and limits' ids; the others' copies get stable ids of
  their own. Ruleset ids are stable (kid + name), so parents' phones agree; a parent's phone sets them up at launch for
  kids with a policy, and a kid's first policy starts with them. Pending temporary changes get them too.
- **Choosing one:** Screen Time › Switch ruleset… picks one for today only or 1–30 days counting today, or goes back
  to each day's own; it saves at once (a `RuleSetChoice`: the ruleset, the midnights it starts and ends, who), with a
  change history entry. The kid's phone goes back by itself at the end, offline too. It's disabled while the screen
  has unsaved edits, which would undo it.
- **Enforcing:** `Policy.current(at:)` (the kid's `AppGroup.loadPolicy`, parents' `FamilyData.policy(for:)`) sets the
  policy's own Downtime, limits, limit warnings and Blocked to the ruleset in effect's, so the planner, Enforcer, block
  page, details and screens are unchanged. Limits, warnings and Blocked are today's ruleset's. A Downtime window that started yesterday is
  yesterday's ruleset's (Friday's bedtime runs into Saturday morning by Weekday's), one that starts today today's: on a
  day the ruleset changes, each window is kept to the one weekday it starts. The midnight restart reconciles, as for
  temporary changes. A choice is kept a day past its end, for the Downtime that began on its last day.
- **Older builds:** saves (`Policy.saving(at:)`) keep the ruleset in effect's rules, as they are, in the policy's own
  fields, so a kid's phone on a build from before rulesets enforces the ruleset in effect at the last save, every day.
- **Editing:** Screen Time shows the ruleset in effect prominently (and the kid's card on Home, and the kid's Screen
  Time section), then the rulesets, then what every ruleset shares. Each ruleset has a screen of its own
  (`RuleSetView`): its name and weekdays, Downtime, App Limits, Blocked and limit warnings. Screen Time adds one (empty
  or a copy, with new ids) and deletes one (not the last). These are draft edits of the one draft, saved with Save on
  either screen, permanent or temporary like any other.
- **History:** a ruleset's edits are named with it ("Weekend: Changed Blocked"); setting up, adding, removing,
  renaming, its days and choices have entries of their own. With rulesets, the policy's own Downtime, limits and
  Blocked are only the ruleset in effect's and aren't compared. Temporary changes change rulesets back field by field.
- Grants and limit fires go by window and limit id, so a ruleset change mid-day starts the new ruleset's limits from
  its own budgets (the use still counts) and a grant for the old ruleset's window doesn't carry over.

## 16. Losing data access, and iOS's count restarting

**Apple's Screen Time settings take data access back silently.** When a parent's device sends the kid's Screen Time
settings (even unchanged), `ScreenTimeAgent` requests its own authorization and FamilyControls resets ScreenThyme to
"not determined"; iOS stops our activities. Fires keep coming after the app re-registers, but every fetch fails
`unauthorized`. The extension alerts parents at the first refused fetch (`RuleEngine.accessAlert`, once per loss and
day), and heartbeats report it.

**A new grant can restart iOS's count of today's use lower** (by tens of minutes), while thresholds still replay from
midnight in iOS's count, so an alarm registered above our total would wait that much use for its next wake. A fresh
registration adds **probes** below our total (1, 2, 4, 8, … minutes under it, and minute 1; `p.<minute>`, never
journaled).
iOS replays those it has passed; after 3 s the highest settles `LadderCalibration.offset` (ours minus iOS's), and
the alarm re-registers in iOS's minutes. Fires are journaled as `t.<our minute>`. Replays within 60 s of a
registration only refine the offset. Midnight clears it.

`UsageTrackingAgent` logs "`t.<n>/<activity>/<team>.<bundle id>` has N seconds remaining" for each threshold: the
quickest way to see where iOS's count is.

### Apple's Always Allowed outlives App & Website Activity

The family's Screen Time blueprints stay installed after a data-access grant turns App & Website Activity off:
Always Allowed, bedtime Downtime and usage limits. `ScreenTimeAgent` applies the allowed apps through its own store
(container `com.apple.ScreenTime`, `AllowedAppsStore`), and an app it allows passes every shield, ours included. With
App & Website Activity off, Settings has no Always Allowed list to show, and nothing in our App Group shows it either.
In device logs, `dmd` logs each app's verdict when a shield store changes: "has policy OK", "Shielded" (with its
category) or "is unblockable".

**Setting up a kid's phone** (or fixing one): on a parent's phone, turn the kid's App & Website Activity on, empty
Always Allowed (Phone stays), delete the App Limits and turn Downtime off. That resets ScreenThyme to "not
determined"; on the kid's phone, "Allow Screen Time access", then usage data access (which turns App & Website
Activity off again), then restart.

## 17. Nearby link: family phones talk directly, without the internet

When ScreenThyme is open on a kid's phone and a parent's phone near each other (in a car, on a plane, camping), they
talk directly, so parents see current use and can answer requests with no internet. CloudKit stays the source of
truth: records keep their CloudKit ids, so copies that arrive later overwrite what came nearby.

**Foreground only, by design.** iOS suspends sockets with the app, the monitor extension lives for seconds, and
background Bluetooth between iPhones is too unreliable. The link starts when the app becomes active (before any
network call) and stops when it goes to the background. Asking for more time already opens ScreenThyme on the kid's
phone.

**Routes**, both at once with the same protocol (`LinkTransport`):
- Wi-Fi (`NetworkTransport`): Bonjour (`_screenthyme._tcp`) over Network.framework with `includePeerToPeer`, on a
  shared network or peer-to-peer Wi-Fi. A failed browser or listener is replaced.
- Bluetooth (`BluetoothRadio`), for Wi-Fi off: the kid phone publishes an L2CAP channel and advertises a service whose
  one characteristic holds the channel number; the parent scans, reads it and opens the channel. Ids derive from the
  family secret. No pairing (the link encrypts). Tens of KB/s; a first bundle is ~40 KB.
- A phone reachable both ways gets updates on Wi-Fi only (else its oldest connection); the other stays open, idle.
  The parent rescans every 15 s, since a scan reports a phone only once.
- Each phone asks once for Local Network and Bluetooth access. Events go to Application Support/nearby-diagnostics.txt.

**Who talks:** kid phones listen; parent phones browse and dial (`ScreenThyme/Nearby/NearbyLink.swift`).
- Kid → parent: kid, items, epoch, today's and yesterday's fires and samples, a fresh heartbeat (`source: .nearby`),
  alerts, requests and extra-minute uses. Every 15 s the kid sends what changed (`LinkSentFilter`)
  and samples Apple's data every 60 s. The parent ingests it into its mirror and shows a banner for alerts under an
  hour old.
- Parent → kid: the kid's policy (newer `updatedAt` wins), the last rule set this phone published (an older set from a
  parent nearby can't replace a newer one from CloudKit), and answers from the last two days.
- Parent controls (§4.9): a parent's phone sends `.unlock` or `.lock` to one kid's phone at once; the kid's phone
  says whether they're unlocked (`.state`) in every bundle and whenever that changes.

**Pairing is the family zone.** The owner creates `LinkKey.<fixed id>` (32 random bytes, create-only so two launches
can't race); every phone fetches it by name at refresh (`LinkKeyService`), so each needs the internet once. The
protocol (`ThymeCore/Link`, unit-tested):
- Bonjour TXT `f` is a tag derived from the secret, so parents skip other families' services; a kid's service name is
  derived too, so it doesn't name the kid.
- Frames: 4-byte length + AES-GCM. Hellos (role, kid id, name, a fresh 32-byte nonce) are sealed with a key derived
  from the secret. Bundles (lzfse-compressed JSON) use HKDF keys from the secret and both nonces, one per direction,
  with a counter as the GCM nonce, so recorded, replayed, reordered or reflected frames fail. A peer counts as
  connected only after its first bundle opens.
- Trust is CloudKit's: every family phone has the secret, as it has read/write access to the zone.

Works on the family's phones over the home Wi-Fi (connected within a second) and over Bluetooth with Wi-Fi off
(connected 2 s after the parent app opened; updates moved to Wi-Fi when it came back). Not covered: parents don't
forward a kid's records to CloudKit; no parent-to-parent sync; an offline rule deletion reaches the kid through the
rule set but the `Rule` record's deletion needs the network; the owner may get a second banner when the kid's phone
later uploads an alert.

## 18. Bug reports from family phones

Every screen has a bug at the top right (`.bugButton(help:)` beside each `navigationTitle`), and the kid's home screen
links to it. It opens **Report a problem** with a picture of the screen already attached (removable) and that
screen's source file and line. The reporter must choose Bug, Feature or Question, writes what happened (or the idea,
or the question) and adds up to five pictures from Photos (`PhotosPicker`, no photo-library permission). Tapping a
picture opens it to draw on with a red pen (Undo, Cancel, Done); the marks are drawn into the picture that's sent. The phone files a GitHub issue itself; nobody needs a GitHub account.
Beside the bug, a question mark opens that screen's help: what it shows and what can be done there (`ScreenHelp`,
in `ScreenThyme/Help/`).
This repository is public, so issues go to a **private** repository: a kid's words and screenshots must not be
published.

- **Where:** a parent enters the repository (`owner/name`) and a fine-grained token in Settings › Bug reports, saved as
  `IssueTracker.<fixed id>` in the family zone and fetched by name when a phone files (`IssueTrackerService`). Every
  family phone can read the token, so scope it to that repository with Issues and Contents read and write.
- **Screenshots:** GitHub's API can't attach images to issues. Each picture is shrunk to at most 2000 px as JPEG (which
  drops location metadata), committed under `reports/<day>-<id8>/` with the Contents API, and shown in the issue from
  its page (`…/blob/<branch>/<path>?raw=true`), which renders only for people with access.
- **The issue:** labeled by its kind with GitHub's default labels (`bug`, `enhancement`, `question`; reports queued
  before kinds have none); title `<reporter>: <first line>`; body: their words, the pictures, a table (time, role, screen, app
  version, build date, iOS, phone model, family; on a kid's phone Screen Time access, monitoring, last wake, backlog;
  on a parent's the number of kids and saves waiting for the internet; phones nearby) and yesterday's and today's
  journal notes, collapsed. Logic is in `ThymeCore/BugReport` (`GitHubIssues`, tested with a fake transport).
- **Queue:** reports wait in Application Support (`BugReportQueue`, `BugReports/`), sent at once, then at every launch,
  background refresh and visit to the screen, until filed. Each upload is saved as it succeeds, so a retry skips
  screenshots already committed. Filing stops at the first failure and says why ("Waiting for the internet",
  "Waiting for a parent to set up bug reports", GitHub's message). The last 20 filed reports stay listed.
- **Closed:** when an issue is closed, the phone that filed it gets a push quoting the reporter's first line and
  saying whether it was fixed (closed as completed; for an idea "done", for a question "answered") or closed without
  a fix (not planned, a duplicate). A workflow in the bug repository sends it to APNs (`Tools/BugPush`, with the family's APNs key as secrets):
  the issue ends with a hidden marker naming the phone, and each phone keeps its device token in `phones/<id>.json`
  there. The phone also looks its issues up (at most every 30 minutes, or on pull to refresh) to show "Fixed" or
  "Closed".
- **Not covered:** a lost answer to a filed issue files it again (a duplicate); the picture can't show Apple's own
  views (the report extension's, the pickers).

## 19. Where apps get used: places

Goal: say where each app was used ("YouTube: 50 min at home, 12 at school") without hurting the kid's battery.

- **No periodic fixes.** The monitor extension can't get location (~3 s per callback, a fix takes 5–30 s, extensions
  can't ask for access), and fixes from the app every minute would need continuous background location.
- **Instead, where the phone was, joined to the timeline afterwards.** iOS watches visits
  (`CLLocationManager.startMonitoringVisits`) and circular regions (`startMonitoring(for: CLCircularRegion)`,
  `didDetermineState`, 20 at most) itself, and wakes or relaunches the app only at a visit or crossing: a few times a
  day, no location background mode. `PlaceWatcher` asks for Always access and restarts at every launch, background
  ones included. Visits catch every stop of six minutes or more; departures arrive 1–5 minutes late, arrivals 1–17.
  Region exits arrive about a minute after the visit's departure. `CLMonitor` was dropped (it reported an exit six
  hours late, and lost a fence); each phone removes its old fences once (`retireMonitor`), and the region code
  touches only regions named by a place's id (`ownRegions`): iOS lists others among them too.
- **Kid phone:** events go to App Group `Places/events.jsonl` (`PlaceEvent`: when it happened, when the app heard,
  coordinates for visits, which API) and upload as `PlaceEvent` records right away from the app and with the
  extension's uploads otherwise (ledger `Places/events-uploaded.jsonl`). `KidSync` fetches `FamilyPlaces` at every wake
  (`Places/family-places.json`), and `PlaceWatcher` fences the family's places before the Debug › Places test's own
  ("Mark this spot"), re-adding a fence a parent moved or resized. `Places/diagnostics.txt` logs every start, raw
  event and problem; `thyme-inspect` takes the copied `Places/` as a fourth argument.
- **Logic (`ThymeCore/Places`):** `PlaceStays.build` turns crossings and visits into non-overlapping stays (a fence
  wins over a visit; a visit inside a fence counts as that place; a visit outside a fence ends that fence's stay).
  `LocationDay` shares each timeline block's seconds out among a family place, other locations (a visit no place
  covers) or moving (outside every visit).
- **Parents' Places tab:** a map of the last 60 days' visits. Visits no place covers are grouped into spots
  (`VisitClusters`: within the larger of their accuracies, 50 m at least, the most precise seeding spots). Tapping a
  spot names it: the place is centered on the spot, weighted by precision, with a fence of its median accuracy or
  spread (100 m to 1 km, adjustable). The family's places are one record, `FamilyPlaces.<fixed id>`, last writer wins.
- **Use by location:** a kid's day's Where section (`LocationDayView`), an app's Where in its details (today or the
  last 7 days), and Raw location (the day's visits on a map, stays, and every event with coordinates, accuracy, the
  place it matched and how late it came).
- **Parents are told when it stops:** while places are watched, heartbeats carry Location; anything short of Always
  with Precise Location is `denied` and raises the usual permission alert. A phone not watching places reports nil.
- The replay tool's school day comes with visits (spots in a public park) for the Simulator and the screen map.
