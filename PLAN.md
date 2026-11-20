# ScreenThyme — Plan

Near-real-time, per-app screen time for our kids' iPhones, viewed on the parents' iPhones.

## 1. Problem

Apple's built-in Screen Time has two problems for us:

1. **Precision.** It shows totals per app and per hour, but not *which app was used, when, and for how long*.
2. **Latency.** Kid usage sometimes takes hours or days to reach the parents' phones, because of iCloud Screen Time sync.

## 2. Goals and non-goals

**Goals (v1)**
- **Every app** tracked individually, with no hand-picking. Setup is a single "select all" tap on the kid's phone.
- **Per-app totals** to the nearest 5 minutes (up to 60 min per app per day), then to the nearest 15 minutes.
- A **timeline** showing roughly when each app was used. The phone-wide total is tracked minute by minute, and that is used to place each app's usage in time (§4.2).
- On both parents' phones, about **1 minute** after use to see that the phone is in use, and **≤ 5 minutes** to see which app.
- Push **alerts** for:
  - quiet-hours usage
  - daily thresholds
  - long sessions
  - new or untracked app usage
- **Tamper and health alerts**: the kid device stopped reporting, authorization was lost, or monitoring stopped.
- **Websites**: Safari domains tracked like apps.
- History kept **forever**.
- 2 parents and 1–2 kids, all on **iOS 26+**.

**Non-goals (v1)**
- Single-minute precision for each app.
- Blocking or limiting apps. Apple's Screen Time controls stay in place for that. The architecture doesn't rule it out later through ManagedSettings.
- Mac, iPad or web viewers.
- App Store distribution. This is a family-only app installed with development builds from a paid developer account.
- Content inspection: no screenshots, messages or browsing contents.

## 3. Platform reality (researched Nov 2026; iOS 27 is current)

This section drives the whole design. Apple deliberately prevents third-party apps from reading raw usage data.

| Fact | Status | Consequence |
|---|---|---|
| The **DeviceActivityReport** extension (the only place exact per-app usage is visible) is sandboxed: no network, no App Group writes, no export. DTS calls this "a fundamental, deliberate architectural decision." | Verified | We can't read Apple's own numbers and ship them. It's useful only for on-device display. |
| The **DeviceActivityMonitor** extension gets `eventDidReachThreshold` callbacks ("token X has reached N minutes in this interval"). It **can** write to the App Group, make network requests (if it blocks briefly before returning) and post local notifications. Memory limit is about 6 MB. | Verified / community-confirmed | This is our capture mechanism: **threshold ladders** (§4.1). |
| At most **20 monitored activities** per app. No documented cap on events per activity. Minimum schedule interval 15 min. | Verified (cap on events per activity unknown) | Ladders for about 100 apps mean thousands of events, which must be stress-tested (S1). Apps can be split across activities if needed. |
| `FamilyActivityPicker` with `FamilyActivitySelection(includeEntireCategory: true)` returns individual app tokens when the user selects whole categories or "All Apps & Categories." | Documented; behavior with "select all" unverified | One tap gives us every installed app. Apps installed later are **not** included until the next re-scan. |
| **Threshold reliability is poor on iOS 26+**: early or immediate fires (often on the charger or on first pickup), overcounting, missed fires, throttling. DTS acknowledges a known issue; it is reportedly unfixed in iOS 27. | Widely reported | Treat each callback as a hint and validate it (§4.2). Show confidence on the timeline. |
| Tokens (`ApplicationToken`, `WebDomainToken`, `ActivityCategoryToken`) are opaque. There are no bundle IDs or names in the extension. Tokens are Codable and documented as usable "within the same Family Sharing group." They can expire (iOS 26.5 added `TokenExpiryMessage`) and are voided on deauthorization. | Verified; cross-device rendering unproven | **Critical when tracking all apps:** nicknaming about 100 apps isn't practical, so names on the parents' phones depend on S2 or S4 (§4.5). Never use a token as a long-term key. |
| Categories are **Apple's fixed list**: Social, Games, Entertainment, Creativity, Education, Health & Fitness, Information & Reading, Productivity & Finance, Shopping & Food, Travel, Utilities, Other. Apple assigns each app to one, mostly from its App Store category. We can't define categories, change which apps are in one, or list a category's apps. | Verified | We use categories as-is for totals and as a catch-all for apps installed after the last scan. Custom groupings are display-only, built from apps we already track. |
| **`.child` authorization** needs a parent's approval on the kid's device. The kid then **can't delete the app** or sign out of iCloud. There is no callback when authorization is revoked. | Verified | Use `.child`. Detect tampering ourselves with heartbeats (§4.7). |
| **iOS 26.4 data-access API** (`approvedWithDataAccess`, `DeviceActivityData.activityData(...)`, `FamilyActivityData` with real bundle IDs and domains) is intended for export. It is EU-only for customer installs, **but reportedly works with development profiles in any region**. It is undocumented whether it works under `.child`, and its granularity is probably hourly. | Verified API; our use case unverified | A potentially big win: real app names, Apple-accurate hourly totals, and new-app discovery. Spike it (S4). It would supplement the ladders, not replace them. |
| The extension reportedly stops being invoked after several days without the host app being launched. | Community report | Keep the host app waking up (§4.7). |
| Family Controls **distribution** entitlement: required for TestFlight and the App Store, approved per bundle ID including extensions, with waits of up to about 2 months. Development builds don't need it. | Verified | Ship with Xcode development builds. Request the entitlement early anyway as an option for later. |

**What this means:** we can't get Apple's ground truth off the device. What we can get, in near real time, is a per-app account of usage to the nearest 5 or 15 minutes, placed in time using the phone-wide total. That fixes both problems, at the cost of some approximation, which we measure and show.

## 4. Design

### 4.1 Capture: threshold ladders (kid device)

**Setup: the "scan" (one tap).** On the kid's phone, the parent opens `FamilyActivityPicker` (configured with `includeEntireCategory: true`) and taps **All Apps & Categories**. The selection gives us:
- an `ApplicationToken` for every installed app
- an `ActivityCategoryToken` for every category
- `WebDomainToken`s for any domains selected (spike: does "select all" include domains, or do they have to be added?)

Each token becomes a `TrackedItem` with our own stable UUID.

**Ladders (rolling, see §12):** registration holds only each item's **next 2** thresholds and the total's next 20 minutes. The monitor extension re-registers an activity after each crossing in it, and at midnight resets it to the first steps. The step sequence is:
- **Apps and categories:** every **5 min** from 5 to 60 min, then every **15 min** from 75 min to 12 h.
- **Websites:** every 5 min up to 60 min only (12 events). Their time also counts as Safari's, and a real scan returns hundreds of sites (§11).
- If everything doesn't fit, the app ladder is cut from the top (5–60 is always kept), and a total at the top of its ladder shows as "60+ min".

Event names encode the item and the minute, e.g. `i.<itemUUID>.<minute>`.

**Plus one total ladder:** `includesAllActivity`, every **1 min** up to 16 h (960 events). This is cheap: a single series. It gives us:
- **"phone in use right now"**, within about 1 minute
- the minute-by-minute **in-use timeline** that app usage is placed onto (§4.2)
- untracked time: the total minus all tracked apps
- an implicit heartbeat

**Schedules:** each activity is a repeating **daily** `DeviceActivitySchedule` (00:00–23:59).

**Activity budget (max 20):**
- total: 1
- apps and categories: as many as needed at ≤ 1,000 events each
- websites: their own activities (83 sites each)
- spare: whatever is left. A re-scan registers the new epoch before stopping the old one if both fit; otherwise it stops the old one first, and catch-up covers the gap

When an event fires, the monitor extension:
1. Appends `{eventName, firedAt}` to an **append-only JSONL file** in the App Group, with an fsync. This step must survive the extension being killed.
2. Runs the lightweight on-device rule checks (§4.6).
3. Tries the CloudKit upload with a short synchronous wait (≤ 3 s). If that fails, the host app sends the backlog later.

The extension stays tiny: no SwiftData, no large dependencies, under the 6 MB limit.

**Re-scans** (to pick up newly installed apps):
1. Register the new selection into a spare activity with `includesPastActivity: true`.
2. Ignore the immediate catch-up fires for thresholds already passed today.
3. Retire the old activity.

Record each scan as a `LadderEpoch` so the reconstruction knows the baseline.

### 4.2 Reconstruction: fires to timeline (pure Swift, runs on the parent device)

**Inputs** for one kid on one day:
- **in-use minutes** from the 1-min total ladder: each minute the phone was in use
- **app crossings**: app X reached k minutes (a multiple of 5 or 15) at time t

**Per-app totals.** An app's total is its last crossing, plus a possible remainder below the next step. That remainder is visible as untracked in-use time near the app's last crossing. Totals are shown as "25–30 min."

**Placing usage in time.** This is an attribution step. Between two consecutive crossings of app X (at k−5 and k), X used exactly 5 in-use minutes. An iPhone has one foreground app at a time, so each in-use minute belongs to exactly one app.
- Assign in-use minutes to the apps whose crossing windows cover them, so that every app's crossing counts are satisfied.
- Where only one app's window covers a stretch, the assignment is **certain**.
- Where several overlap (fast app switching), the minutes are shared among those apps as a **shaded "mixed" block**: "Mixed: YouTube, Roblox, Messages."
- A greedy pass handles the common case. A small constraint solver handles overlaps, and the problem is tiny.

**Sessions** are runs of in-use minutes attributed to the same app. A gap of more than 2 min ends a session.

**Validation rules** that flag suspect fires:
- `k` must never exceed the minutes elapsed since the interval start.
- An app can't gain more minutes than the in-use minutes available.
- Fires must be monotonic in `k` and time. Drop duplicates.
- A **burst** (several thresholds within seconds) is either a system catch-up or a misfire. Mark the segment *low confidence*; never stack minutes at a single instant.
- Known misfire patterns, such as immediate fires right after midnight or a pickup, are learned from spike data and encoded as heuristics.

**Live status.**
- "**Phone in use**": the latest total fire is under 90 s old.
- "**Now: probably X**": the app with the most recent crossing, if that crossing lies within the current in-use run.

**Untracked time** is the total minus all tracked apps beyond the ladder remainders. It usually means an app installed after the last scan. Its category ladder says which category it's in.

This is a deterministic, unit-tested module (`ThymeKit/Reconstruction`). Raw fires are the source of truth; timelines are derived and cached. That means better heuristics later can re-render all of history.

### 4.3 Sync: CloudKit

- **Topology:** Parent A owns a custom zone `Family` in their **private DB**. A zone-wide `CKShare` adds Parent B (read/write) and each kid's Apple ID (read/write). The kids are Family Sharing child accounts, so they have iCloud.
- **Kid devices** write the `UsageFire`, `Heartbeat`, `Alert`, `TrackedItem` and `LadderEpoch` records.
- **Parents** write the `Rule`, `Ping` and `Kid` records, and the nicknames on `TrackedItem`s.
- **Freshness:**
  - Kid side: each fire is uploaded within seconds of the threshold.
  - Parent side, foreground: the app uses push-triggered fetches plus a 30 s poll.
  - Parent side, background: silent push, then a fetch.
- **Push for alerts:**
  - Parent A (owner) gets a `CKQuerySubscription` on `Alert`, with visible `notificationInfo` built from the record's fields. That gives reliable visible pushes without waking the app.
  - Parent B (participant) gets a `CKDatabaseSubscription` on the shared DB, which triggers a fetch and then a local notification. Spike S5 checks whether a visible notification works on a database subscription.
  - **Fallback:** a tiny APNs relay, e.g. a Cloudflare Worker. Use it only if the spike fails.
- **Volume:**
  - total ladder: about one fire per in-use minute
  - app ladders: about one fire per 5 min of app use
  - in all, roughly 300–800 records per kid per day, so keeping everything forever is trivial
- A nightly `DayRollup` record per kid keeps history views fast; raw fires are kept as well.

### 4.4 Data model (CloudKit record types; also mirrored locally in SwiftData on parent devices)

| Record | Key fields |
|---|---|
| `Kid` | `id`, `displayName`, `color`, `deviceName` |
| `TrackedItem` | `id` (our UUID, the stable key), `kidId`, `kind` (app/domain/category/total), `tokenData` (encoded token), `nickname?`, `categoryId?`, `firstSeenEpoch`, `active` |
| `LadderEpoch` | `kidId`, `activityNames`, `startedAt`, `itemIds`, `ladderSpec` |
| `UsageFire` | `kidId`, `itemId`, `minute`, `firedAt`, `day`, `epochId`, `uploadedAt` |
| `Heartbeat` | `kidId`, `at`, `source` (fire/bgRefresh/ping/launch), `authStatus`, `activeActivities`, `appVersion`, `backlogCount`, `batteryLevel` |
| `EnergyReport` | `kidId`, `day`, `deviceModel`, `monitor` and `app` usage (energy, CPU time, wake-ups, callbacks, launches); one per kid per day, overwritten |
| `Alert` | `kidId`, `ruleId`, `itemId?`, `at`, `title`, `body` |
| `Rule` | `kidId`, `type` (quietHours/dailyThreshold/longSession/untrackedUsage/staleness), `params` |
| `Ping` | `kidId`, `at`, `from` (parent-initiated liveness check) |
| `DayRollup` | `kidId`, `day`, `perItemMinutes`, `timeline` (compact JSON) |

### 4.5 App names on the parent's phone

With about 100 tracked apps, naming has to be automatic.

1. **Preferred:** decode `tokenData` on the parent device and render `Label(token)`, which shows the icon and name. Apple documents this as working within a Family Sharing group. **Spike S2. It's now critical.**
2. **If S4 succeeds:** real bundle IDs and domain names from `FamilyActivityData`.
3. **Fallback:**
   - The kid app shows the **top apps by usage** with `Label(token)`, and the parent types nicknames for those apps.
   - Other apps appear as "App #37 · Games" (category from the category ladders) until named.
   - Nicknames always override.

Tokens can expire. On `TokenExpiryMessage` or a re-authorization, the app prompts a re-scan. To keep history, map new tokens onto existing `TrackedItem.id`s: tokens for the same app should compare equal within an epoch. If they don't, use the label or nickname to match, and ask the parent about any that remain ambiguous.

### 4.6 Alerts

Rules are edited on the parent device and synced to the kid device. They are evaluated **on the kid device**, in the monitor extension where possible, so an alert doesn't depend on the parent's phone waking up.

| Rule | How it works |
|---|---|
| **Quiet hours** (bedtime, school) | A total fire inside the window → "Phone in use during bedtime" within about 1 min. Updated with the app name once it crosses a threshold. Throttled, with a "still using" alert every N min. |
| **Daily threshold** (whole phone or one app) | Checked at each wake against today's total or Apple's per-app seconds, so it fires within one wake (a minute of use) of the limit. |
| **Long session** | The extension tracks the current in-use run (from total fires) and Apple's per-app seconds within it. The run passes N min → alert naming the dominant app. |
| **New app** | An app or website never seen on this phone before (by bundle ID or domain) → alert. |
| **Staleness / tamper** | Evaluated on the **parent** device. See §4.7. |

All alerts are recorded in the timeline, so the alert feed and the timeline match.

### 4.7 Health and tamper detection

- **Liveness sources:**
  - every fire
  - `BGAppRefreshTask` (opportunistic)
  - host-app launch
  - **Ping/Pong**: a parent writes a `Ping`, the kid device's `CKDatabaseSubscription` silent push wakes the host app, and it writes a `Heartbeat`
- **Each heartbeat reports:**
  - `AuthorizationCenter.shared.authorizationStatus`
  - `DeviceActivityCenter().activities` (are our schedules still registered?)
  - backlog size
  - app version
  - the Settings switches the kid can turn off for ScreenThyme and no app can lock: Background App Refresh, cellular
    data, Bluetooth, and Low Power Mode (`DevicePermissions`). The kid app uses no notifications, so they aren't one
- **Parent-side checks:**
  - authorization not approved → **immediate alert**
  - missing activities → **immediate alert**, and the kid app re-registers on its next launch
  - no heartbeat for more than X hours during waking hours → **alert** ("offline since 3:12pm"), which covers airplane mode, Wi-Fi off and Background App Refresh off
  - backlog growing → warning
  - one of those switches off → **immediate alert**; Low Power Mode → warning (it also reports Background App Refresh
    as off, so that alert waits until Low Power Mode is off)
- The host app wakes regularly (background refresh, silent pushes, a nightly rollup). That also works around the reported "extension stops after days without the host app launching" problem.
- `.child` authorization means the kid can't delete the app. Turning off Background App Refresh or connectivity only delays delivery, because data is queued locally.

### 4.8 Parent UI (SwiftUI)

- **Home:** a card per kid showing:
  - Live status ("In use · probably YouTube", or "Idle · last active 8:42pm")
  - Today's total
  - Top apps
  - Health dot
- **Kid → Day timeline:**
  - The in-use strip across the top, minute by minute.
  - Below it, one lane for each **app used that day**, sorted by time spent, with session bars. "Mixed" blocks are shaded.
  - Tap a bar for the time range and minutes.
- **Kid → Totals:** day, week and month bar charts by app and category (Swift Charts). Optional display-only groups built from tracked apps, e.g. "Homework" = Docs + Classroom.
- **Alerts feed:** filterable by kid and rule.
- **Settings:** rules per kid; nicknames; device health details (last heartbeat, auth, activities, backlog, app version, last scan); a "Ping now" button.

### 4.9 Kid UI

A minimal, honest screen: "This phone shares app usage with your parents." It shows:
- Status: authorized, monitoring, last upload, last scan
- Optionally, the DeviceActivityReport extension's view of today, so the parent can compare Apple's numbers with ours

Scanning and naming are parent-only actions, behind a parent-approved flow or the device being handed to the parent. In the kid app, re-authorization requires a parent's approval anyway.

## 5. Architecture and project layout

There is **one app with two roles** (chosen at first launch: "This is a kid's phone" / "This is a parent's phone"). That means one set of entitlements, one bundle ID family and simpler dev provisioning.

```
ScreenThyme.xcodeproj
├─ ScreenThyme/              App target (SwiftUI). Role switch → KidRoot / ParentRoot
├─ ThymeMonitor/             DeviceActivityMonitor extension (capture, rules, upload). Tiny.
├─ ThymeReport/              DeviceActivityReport extension (kid-side "Apple's view" only)
└─ Packages/ThymeKit/        Local Swift package
   ├─ Model/                 Record types, Codable DTOs, CloudKit mapping
   ├─ Ladder/                Ladder builder: selection → activities/events, epochs, re-scans
   ├─ Reconstruction/        Fires → totals, attributed timeline, confidence (pure, heavily unit-tested)
   ├─ Rules/                 Rule evaluation (shared by extension and app)
   ├─ Journal/               App Group append-only JSONL writer/reader (extension-safe)
   ├─ Sync/                  CloudKit zone/share/subscription management, upload queue
   └─ Replay/                Trace export/import, re-upload under another kid ID with time shift (debug only)
```

- **Capabilities:**
  - Family Controls (app and both extensions)
  - App Groups (`group.<team>.screenthyme`)
  - iCloud/CloudKit (app and monitor)
  - Push Notifications
  - Background Modes (remote notifications, background fetch)
- **Deployment target:** iOS 26.0. Swift 6, strict concurrency.
- **No third-party dependencies.** The parent-side mirror is plain JSON files (one per kid per day for fires), not SwiftData; the extension uses only JSONL files in the App Group.

## 6. Phases

### Phase 0: feasibility spikes (go/no-go, about 1–2 weeks)

Each spike is a throwaway branch with measurements written to `spikes/RESULTS.md`.

| # | Question | Pass criterion |
|---|---|---|
| **S1** | Ladders at scale and accuracy, three parts: (a) Does a "select all" scan return individual tokens for every app? (b) Do about 6,000 events register, in how many activities? (c) Over 3+ days of real kid use on iOS 26/27, compared against Apple's report extension: how accurate are the per-app totals and the attributed timeline, and what do the misfire patterns look like? | Registration succeeds within the 20-activity budget; per-app daily totals within one ladder step of Apple's for ≥ 90% of apps; misfires are identifiable |
| **S2** | Encode a token on the kid device; does `Label(token)` render on both parents' devices? | Renders names/icons. Otherwise → top-apps nickname fallback |
| **S3** | Can the monitor extension do a CloudKit write within the memory and time limits? Measure memory and success rate. | ≥ 99% of fires uploaded within 2 min, or recovered by the host app's backlog flush |
| **S4** | Is `approvedWithDataAccess` available with a development profile under `.child` authorization on our devices? What granularity does `activityData` give? | Any data at all = bonus feature track |
| **S5** | Parent B visible push via a shared-DB `CKDatabaseSubscription`; latency from fire to parent notification. | Visible push ≤ 1 min. Otherwise → APNs relay fallback |
| **S6** | Does the extension keep firing for 7+ days with only background refresh and silent-push wakes? | No silent gaps |

**Devices needed.** Most of Phase 0 runs on **one iPhone** (your own, with `.individual` authorization) plus the **iOS Simulator** signed into a second Apple ID. See §7.1.

| # | One phone + Simulator? | What else is needed |
|---|---|---|
| S1 | ✅ (a), (b) and (c) on your own usage | A short confirmation run on a kid's phone under `.child` |
| S2 | ❌ The phone can always decode its own tokens, so a loopback proves only the plumbing | A second device in the Family Sharing group (iPad or a parent's phone), for about 10 minutes |
| S3 | ✅ | — |
| S4 | ⚠️ Development build + `.individual` only | A kid's phone, to check `.child` |
| S5 | ⚠️ The Simulator plays Parent B (a CKShare participant receiving a push). For pushes to the phone, make the change from the Simulator or the CloudKit Dashboard/`cktool`, not from the phone itself (CloudKit may not notify the device that made the change) | — |
| S6 | ✅ But don't launch or reinstall ScreenThyme for the whole 7 days. A spare old iPhone is ideal | — |

**Decision point:**
- If S1(b) fails, split apps across more activities, cap the ladder at 6 h, or drop the domain ladders.
- If S2 and S4 both fail, accept nicknames for the top apps only.
- If S1 and S3 pass, the project is viable.

### Phase 1: capture pipeline (kid side)
- Role selection, `.child` authorization flow, the "select all" scan, re-scan.
- Ladder builder and epoch management; monitor extension journal plus upload; host-app backlog flush.
- Debug screen: raw fires, reconstructed timeline, Apple's report extension side by side.
- Single-phone test mode (§7.1): `.individual` authorization, kid identity override, role switch.

### Phase 2: sync and family setup
- The Family zone and CKShare; invite flow for Parent B and the kids (QR or link from Parent A).
- Subscriptions, fetch-changes pipeline, SwiftData mirror on parent devices.

### Phase 3: parent viewer
- Home cards, day timeline, totals charts, live status.
- The reconstruction and attribution module, with a full unit-test suite built from recorded S1 fire traces.
- Replay tool (§7.2), so parent UI work uses 2–3 simulated kids from the start.

### Phase 4: alerts
- Rule editor; on-device evaluation in the extension; Alert records and push; alerts feed.
- Untracked-usage alert and re-scan prompt.

### Phase 5: health and tamper
- Heartbeats, Ping/Pong, staleness rules, health UI, automatic re-registration.

### Phase 6: hardening
- Token expiry and re-scan identity matching; nightly `DayRollup` compaction; midnight and time-zone and DST edges; iOS updates.
- Optional: the S4 data-access track (hourly reconciliation, real names, new-app detection).

## 7. Testing

- **Unit tests** (ThymeKit):
  - ladder generation and activity splitting
  - reconstruction and attribution against synthetic and recorded traces: one app at a time, fast switching, gaps, bursts, early fires, midnight split, duplicates, re-scan catch-up
  - rule evaluation
  - journal durability
- **Ground-truth harness:** a debug toggle on the kid phone shows our per-app totals next to Apple's report extension. Spot-check weekly, and log the discrepancies as new trace fixtures.
- **Device tests:** the real kid phones are the only true test environment. The simulator doesn't produce DeviceActivity fires.

### 7.1 Single-phone test mode (debug builds only)

The goal is to develop and run most spikes on one iPhone plus the Simulator, without the kids' phones.

- **Authorization mode:** a debug setting picks `.individual` instead of `.child`. Capture (ladders, monitor extension, journal, upload) is identical. `.child`-only behavior is out of scope here: the parent approval flow, the app being undeletable, and `.child` support for the S4 export option.
- **Identity override:** "Upload as kid: Emma / Leo / Test 3 / …". This sets the `kidId` stamped on every `UsageFire`, `Heartbeat`, `TrackedItem` and `LadderEpoch`. Each fake kid gets its own `Kid` record.
- **Role switch:** the same install can switch between the kid and parent roles without reinstalling, so the phone can capture and then view its own data after a CloudKit round trip. A phone set up as a kid's enters test mode only from the welcome screen: the switch on the kid's home screen once let a kid make their phone a parent's.
- **Second parent:** the Simulator, signed into a second Apple ID, accepts the Family CKShare as Parent B. It covers sharing, `CKDatabaseSubscription` pushes and parent UI testing. It can't render `Label(token)` for the phone's tokens, so it shows "App #n · Category."
- **Push trigger:** to test pushes arriving on the phone, write records from the Simulator, the CloudKit Dashboard or `cktool` on the Mac, not from the phone itself.
- **Separate environment:** test mode writes only to the CloudKit **development** environment, plus an `isTest` flag on `Kid`, so test data never mixes with the real family's data.

### 7.2 Replay tool

This is for developing the parent side and the reconstruction without waiting for live usage.

- **Export:** on the phone, debug menu → "Export day" writes that day's journal (raw fires and the epoch) as a JSONL trace file. The traces also become unit-test fixtures.
- **Replay:** `ThymeKit/Replay` re-uploads a trace with three settings:
  - **kid ID:** any (fake) kid
  - **time shift:** e.g. move yesterday's trace to today
  - **speed:** instant (bulk), real time, or accelerated (e.g. 60×, to watch live status, alerts and push latency happen)
- **Where it runs:** in the app on the phone, or in the Simulator. The Simulator can fill a whole family with several kids from a few recorded days.
- **Synthetic traces:** a small generator for edge cases that are hard to produce by hand:
  - fast app switching
  - midnight crossings
  - bursts and misfires
  - re-scan catch-up
  - an offline backlog arriving hours late
- **Limits:**
  - Replayed tokens belong to the recording phone, so names display only there. Replay says nothing about S2.
  - Replay exercises the pipeline *after* capture: sync, reconstruction, rules, UI. It doesn't test the DeviceActivity behavior itself.

## 8. Operations (family-only)

- **Installs:**
  - Builds are Xcode development builds on registered devices (kids' and parents' UDIDs).
  - Kid phones need **Developer Mode** enabled. Check that this works under the kids' Screen Time restrictions.
  - Development profiles expire after about 1 year. Set a calendar reminder to rebuild and reinstall.
- **Distribution entitlement:** request it early (app + 2 extensions) so TestFlight becomes possible later if reinstalling via Xcode gets tiresome.
- **iOS updates:** after each update, check the health screen and the spike metrics. Tokens may be reissued, which triggers a re-scan prompt.

## 9. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Threshold misfires make timelines noisy | High | Validation rules, confidence shading, raw data kept for re-processing |
| Events-per-activity cap is too low for about 100 apps | Medium | Split across activities; shorter ladder cap; fewer domains |
| "Select all" doesn't yield per-app tokens | Low–Medium | Category-by-category selection; worst case, hand-pick the top apps |
| Tokens don't render on parent devices (and S4 fails) | Medium | Nicknames for the top apps; "App #n · Category" for the rest |
| Fast app switching blurs the timeline | Medium | Shaded "Mixed" blocks; totals stay accurate |
| CloudKit from the extension is unreliable or over the memory limit | Medium | Journal first; host-app flush via background refresh and silent push |
| Apple changes or tightens the APIs | Medium | Keep the capture layer isolated in ThymeKit/Ladder |
| Kid goes offline to avoid reporting | Medium | Data queues and arrives later; staleness alert |
| Apps installed after the last scan aren't tracked individually | High | Category ladders plus the untracked-usage alert and a one-tap re-scan |

## 10. Open questions

- **Region:** are any of our Apple Accounts EU accounts? That affects S4 beyond development builds.
- **Waking hours** per kid, for staleness alerts.
- Should kids see their own timeline in their app (transparency), or just the status?

### 4.10 Our own battery cost

Each extension callback and app wake ends by reading the process's kernel counters (`task_info` `TASK_POWER_INFO_V2`
`task_energy`, in nanojoules, plus `getrusage` CPU time) into a per-day ledger in the App Group (`EnergyMeter`,
`EnergyLedger`). The day's `EnergyReport` rides along with fire uploads (at most every 15 min) and every heartbeat.
Parents see it under the kid's Health settings, as mWh and, for known batteries, % of a full charge.
Not counted: work iOS does for us in its own processes (Screen Time's usage tracking, CloudKit's network transfers
through the system's sync daemon), and anything a process uses after its last sample.

Measured Nov 15–19, 2026 at 2-minute wakes: the monitor extension used 2–6 J a day on each kid phone (6–37 mJ per
callback), about 0.02% of an iPhone SE's charge; the app used 10–190 J. Wakes come only while the phone is in use,
when the screen draws far more. So the wake alarm moved to **one wake per minute of use, 20 thresholds registered**
(the same 20-minute window, so re-registrations stay as rare). Check the next days' reports against these.

## 11. Findings from the first device run (Nov 14, 2026, iOS 26.6, adult phone, `.individual`)

**S1(b), scale: passed.**
- 20 activities were accepted and kept: 1 × 960 total events plus 19 × 980 app events, 19,580 in total.
- "All Apps & Categories" returned **222 apps, 297 websites and 13 categories**.
- Settings and Safari are **not offered** by the picker. Their use only shows in the total and the categories (as "unexplained").

**S1(c), accuracy: promising.**
- Same day, matched by token in the report extension: **24 of 25 tracked apps and sites** within ±1 minute of Apple's numbers.
- Misses: one app ran 2–6 min below Apple's number; another passed only because of the ±1 allowance.
- The **total runs about 14 min below Apple's**. Cause unknown; keep watching.

**S3, upload from the extension: works.** The parent's synced copy matched the kid journal fire for fire.

**Platform behaviour learned:**
- `DeviceActivityCenter.stopMonitoring([])` stops **every** activity. Never pass an empty list.
- Each registration replays today's already-passed thresholds:
  - counted from **midnight** (not the round hour)
  - in **random order**
  - all at once or throttled to ~2/s
  - for up to **~8 minutes**

  That use is reported as "before tracking started". The kid uploads a tracking-start marker (a total fire at minute 0).
- Categories and websites overlap apps, so they get totals only, not timeline minutes.
- `Label(token)` renders names and icons on the kid's own phone. Cross-device rendering is still S2.
- The report extension **can read the App Group**, which is how the on-phone comparison works.
- On an adult phone, `.individual` authorization succeeded despite an `authorizationConflict` error, probably caused by another Screen Time app on the phone.

**Still open:** S2 (names on another device), S4, S5 (second parent's push), S6 (a week without opening the app), and `.child` on a real kid phone.

## 12. Second device run (Nov 15, 2026): a real kid phone

A kid's iPhone SE (3rd gen, iOS 26.6, Family Sharing child account, `.child` authorization) as kid; the parent's iPhone 17 as parent (owner).

- **S2 passed:** the parent's phone renders the kid's tokens as real app names and icons (`Label(token)` in a List).
  `Picker` in menu style draws them blank, so use list-style UI for token labels.
- **Child authorization works:** approved with the parent's Apple Account on the kid's phone. The kid's phone joined the
  family as a CKShare participant and writes to the shared zone. The share sheet's options page is blank when only
  read/write is offered, and that's fine.
- **After child authorization the phone needed a restart.** Until then, neither thresholds nor Apple's own report
  extension got any data.
- **Full ladders crashed Apple's Screen Time daemon.** With ~7,300 registered events, `UsageTrackingAgent` grew to
  ~1.7 GB and was killed by jetsam (`JETSAM_REASON_MEMORY_HIGHWATER`) every 1–2 minutes, so no thresholds were delivered.
  The same daemon enforces Apple's own limits and Downtime. The parent's iPhone 17 survived 19,600 events, but only thanks to
  its memory. **Fix: rolling ladders** (§4.1): ~20 events per activity, 380 in total on the kid's phone.
  Live delivery then worked: total minute by minute, per-app crossings 5→10→…→30 as the extension re-registers.
  Logs after the switch: the daemon sits at ~8–21 MB and only exits on iOS's routine idle limit (`PERPROCESSLIMIT`
  while inactive). One 286 MB spike during the post-registration catch-up recovered on its own, so keep
  registrations (scan, re-register) rare.
- Settings and Safari aren't offered by the picker on the kid's phone either. "FamilyControlsAgent" (the approval
  sheet) shows up in Apple's report as an app.
- **Toolchain:** Xcode 27.2 (iOS 27.2 SDK) adds `AuthorizationStatus.approvedWithDataAccess` and
  `DeviceActivityData.activityData(...)`, so **S4 is now buildable**. The minimum deployment target is raised to iOS 26.4.
  Its `devicectl` only copies from the App Group's `Library/`, so app files moved to `Library/ScreenThyme/`.

**Still open:** S1(c) on the kid phone over a full day; whether the daemon's memory stays healthy with rolling (check
the logs); S5 (alert pushes); S6 (a week untouched); the midnight reset of rolling ladders; S4 (optional).

## 13. S4: Apple's data-access option works (Nov 15, 2026, Xcode 27.2)

| Question | Result |
|---|---|
| Entitlement `family-controls.app-and-website-usage` for development builds | ✅ granted to our team. It must also be on the **monitor extension** to fetch there. |
| `approvedWithDataAccess` on a **US** account | ✅ after one re-request (no new prompt type) on both an adult (`.individual`) and a child (`.child`) phone |
| `DeviceActivityData.activityData(...)` | ✅ exact per-app minutes with **bundle IDs** (no display names), including Safari and Settings; hourly is the finest segment; fresh to the second; 0.1 s in the app |
| From the **monitor extension**, in the background | ✅ 0.04 s on the kid's iPhone SE. It needs `import SwiftUI` for `activitySegments` (memory cost not yet measured). |
| `FamilyActivityData.installedApplications` | ⚠️ hung for 90+ s; not needed |
| Side effect | ⚠️ **a new authorization grant stops every DeviceActivity schedule.** The app re-registers right after any authorization request. |
| Totals | Apple's data runs ~13 min above our total-threshold count on the same day, on both phones. The data-access numbers match Apple's Screen Time. |

**Capture redesign (built in `a860884`; the per-app fallback below was not kept):** keep only the rolling *total* thresholds, as a once-every-N-minutes-of-use
alarm. On each wake the extension fetches today's per-app data, takes the difference from the previous fetch, and uploads
exact per-app minutes for that interval. Per-app thresholds, scans and tokens are no longer needed, and new apps, Safari and
Settings are covered. Keep the per-app rolling thresholds as a fallback when authorization isn't `approvedWithDataAccess`
(officially EU-only for customers, one app per phone, and Apple can change it). Fire every ~2 min and upload every ~5
min (immediately for alerts); measure battery under Settings → Battery.

## 14. Alerts end to end (Nov 15, 2026, the kid's iPhone SE → the parent's iPhone 17)

Test rules were seeded from the parent phone with `-addTestRules <kid name>` (see CLAUDE.md).

| Step | Result |
|---|---|
| Live capture | ✅ one wake every 2 min of use, each with per-app samples (e.g. 120 s of one app per wake), once the extension stopped gating on `authorizationStatus` (it never reads `approvedWithDataAccess` there) |
| Rules → kid phone | ⚠️ the silent push to the kid app delivered new rules within ~2 min once, then not at all for a deletion (iOS rations silent pushes, and the kid gets one for every change in the zone). Fix: parents also save the kid's whole list as `RuleSet.<kid id>`; the monitor extension fetches it by name at every wake (`KidSync`), into App Group `rules.json`. |
| Quiet hours | ✅ "phone in use" at the first wake in the window; "still on the phone" 30+ min later at the next wake |
| Daily total | ✅ fired one minute past the limit |
| Alert → parent | ✅ uploaded at the same wake; in the parent's Alerts tab within about a minute |
| Visible banner on the owner's phone | ✅ after a fix. The `alerts-visible` CKQuerySubscription was missing: the phone set up the family as a test kid, and `modifySubscriptions` only reports per-subscription failures in its results. Every launch now ensures the role's subscriptions and checks each result; `Application Support/push-diagnostics.txt` shows what a phone has. |
| Long session, new app | not yet triggered (short sessions; no new app) |
| Second parent (participant: local notification after a silent push) | not tested; there is no second parent phone yet |

Unrelated observation: the kid phone's Screen Time settings (limits, downtime, Always Allowed) were found reset on Nov 15.
ScreenThyme never writes ManagedSettings. The likeliest trigger is the re-authorization for data access, which
also cleared all of our DeviceActivity schedules. Watch whether they reset again.

## 15. Enforcement: ScreenThyme replaces Apple's Screen Time limits (Nov 15, 2026)

Apple's Screen Time and an app with data access can't share a phone. Only one "app or service" holds usage data
(`approvedWithDataAccess` docs; the consent sheet says Screen Time "will lose access"). Granting ScreenThyme data access
reset the kid's Downtime, App Limits and Always Allowed. Restoring them about an hour later took the data back
(ScreenThyme's fetches failed with `unauthorized` two minutes after). We keep exact data and rebuild the limits.
Communication Limits are out of scope (no API).

**What stays Apple's:** nothing usage-based. The parent must not configure Screen Time for the kid in Settings
again, or it takes the data back. The kid's phone reports that as a health issue ("data access lost").

### 15.1 Model (ThymeCore, synced as one `Policy.<kid id>` record)

| Part | Meaning |
|---|---|
| Downtime windows | name, start/end minute (may wrap midnight), weekdays (of the day the window starts) |
| Always allowed | apps, websites or categories (TrackedItem ids) exempt from Downtime and limits |
| App limits | name, items (apps, websites, **categories**) or **all apps**, minutes per day, optional per-weekday minutes |
| Blocked | items never allowed |
| Restrictions | App Store (install, delete, in-app purchases, password, max rating), media (explicit, movie/TV ratings, books, Apple Music), web filter (unrestricted / limit adult with allow+block lists / allowed sites only), Siri, Game Center (multiplayer, friends), account and passcode locks, cellular locks, automatic date and time |

Targets are TrackedItems with tokens: the app scan's apps, websites and categories (§15.3). Items from Apple's data
have bundle IDs but no tokens, so they can't be shielded.

Ask for more time: the kid's **TimeRequest** (item, reason, 15 min / 1 h / rest of day) becomes an Alert (banner on
parents' phones). A parent answers with a **TimeGrant** saved as `TimeGrant.<request id>`. For a limit, a grant that names an app (or
a category) lets only that through the limit for its minutes of use: the limit stays used up for everything else, its
category and all-apps shields leave the app out, and its use still counts. One that names nothing (an all-apps limit's
category shield) adds minutes to that limit today. For Downtime, it pauses Downtime on the whole phone for that many minutes of the clock, or
until the window ends (a press on a category shield can't say which app, §15.3).

### 15.2 Kid phone

- `EnforcementPlanner` (pure, ThymeCore) computes what should be blocked now from the policy, the clock, today's per-item
  use (from the Sampler), limit threshold fires and applied grants: Downtime on or off, its exceptions, exhausted limits,
  blocked items.
- `Enforcer` (Shared) applies the plan to three ManagedSettingsStores: `restrictions` (restrictions plus blocked
  items), `downtime` (`shield.applicationCategories = .all(except: allowed)`, the same for web), and `limits` (exhausted
  limits' apps, websites and categories, minus always allowed). iOS shows the union of the stores.
- DeviceActivity activities (≤ 20 in total): the wake alarm `st.<epoch8>.tot`; one per Downtime window `dt.<id8>`
  (split `.a`/`.b` when it wraps midnight); one per limit `lim.<id8>` with one event at its budget (limit plus grants)
  over the limit's tokens. Interval starts and ends and limit fires call the Enforcer. **Every wake (each minute of use) also
  reconciles**, so a missed callback corrects itself within one wake of use.
- **All-apps limits** count Apple's per-app use, less Always Allowed, ScreenThyme and Phone (websites only to subtract
  allowed ones: they also count toward Safari), and shield `.all(except: allowed)` in the `limits` store, like
  Downtime. They get no `lim.` activity: an event over all activity can't leave out Always Allowed, so the wakes
  reconcile them. Their shield names only a category, so one more minute or a request is for the whole phone.
- `Roller.registerAll` no longer stops every activity, only the wake alarm's.
- Block page (ShieldConfiguration extension) reads App Group `enforcement.json` to say why: "Downtime until 7:00",
  "Time limit: Social (1 h)", "Not allowed". The secondary button "Ask for more time" opens ScreenThyme (§15.4), or
  while one more minute is left, a submenu (iOS 26.4): One more minute / Ask a parent (§15.5).
- The kid's policy and grants arrive through a fetch by name (`Policy.<kid>`, `RuleSet.<kid>`,
  `TimeGrant.<open request ids>`) at wakes and app launches, plus the kid app's zone fetch on silent pushes.

### 15.3 First device run: tokens are the catch (Nov 15, 2026)

- **Downtime works:** the block page names the app and when Downtime ends. iOS 26 draws the primary
  button much lighter than the color given, so its label must be dark.
- **Apple's data has bundle IDs, never tokens** (`application.token` is nil for all apps, sites and categories), and
  the block page gets a token, never a bundle ID. So items from the data can't be shielded or matched to a block
  page, and Blocked and per-app limits did nothing.
- **The shield configuration extension can read the App Group but not write it.** The action extension can write.
- **A press on a category shield** (Downtime's `.all(except:)`, category limits) calls
  `handle(action:for: ActivityCategoryToken)`: the category, not the app.
- **50-token caps:** a store's `shield.applications` or `webDomains` with more than 50 shields nothing; an
  `.all(except:)` or `.specific(_:except:)` list takes at most 50 exceptions (Apple docs, developer forums).

**The app scan:** on the kid's phone a parent selects All Apps & Categories once
(`FamilyActivitySelection(includeEntireCategory: true)`): a token for every installed app, website and category,
each an item with identifier `token:<hash>` and no name (`TrackedItem.isScanned`). Parents pick them by `Label`, so
no search or sorting. A second pick of ScreenThyme alone gives its own token, which Downtime and limits always let
through (`exempt-tokens.json`). Apps installed later are covered by their category until the next scan.
- Downtime shields every category except Always Allowed: no app list, so no cap.
- Blocked apps and exhausted limits' apps are shielded one by one over `restrictions`/`limits` plus overflow stores
  `.2`…`.6` (50 each).
- Grants on scanned items and the whole phone run by the clock: Apple's data has no usage for them.

### 15.4 Ask for more time in ScreenThyme

The block page's one extra button, "Ask for more time", opens ScreenThyme (`openParentalControlsApp`, iOS 26.5;
confirmed on the kid's phone). Just before, the action extension writes what was blocked (`ask.json`: item and
category ids) for the app, which shows `AskForTimeView`:
- From a limit or Blocked page the app is known. From a Downtime page only the category is, so the kid picks the app
  in Apple's picker (names, icons, search); its token matches a scanned item, or becomes one.
- How much (15 min, 1 hour, until Downtime ends or the rest of today) and an optional note for the parents.
- The request names the app: a Downtime or limit grant lets that app through (`.all(except:)`), not the whole phone
  or everything the limit counts. With no app chosen, Downtime pauses for the whole phone.
- The screen uploads the request and checks for the answer every 5 s while open. ScreenThyme is exempt from
  Downtime through the scan's ScreenThyme pick.
- **Works end to end on the kid's phone** (Nov 15, 2026): scan, Downtime block page, ask with the app picked, parent's
  approval, the app opens while Downtime stays on for the rest.

### 15.5 One more minute

Like Apple's: from a Downtime or limit block page, the kid can let the app through for a minute without asking, once a
day. The kid's phone sets how long (1–5 minutes, default 1; `SharedConfig.extraMinutes`, on the kid's home screen);
past 1 the menu item reads "N more minutes". "Ask for more time" then opens a submenu (`secondaryButtonSubmenuItems`, iOS 26.4): **One more minute** /
**Ask a parent** (§15.4). Once the minute is used, the button asks straight away. Never for Blocked apps.
- The press decides what is lifted, as a request would (`ShieldContext.requestScope`). An app shielded by itself (a
  per-app limit) lets that app through. A category shield (a category limit) names only the category, so that
  category is let through. Downtime's shield is always a category shield and names no app, so Downtime pauses for the
  whole phone for the minute. Once a day per app, or for a Downtime press, once per window
  (`EnforcementDayState.canTakeExtraMinute`). The block page computes the menu for what its press will name
  (`ShieldContext.pressed`), so the action extension maps the item pressed back to the same choice.
- The ShieldAction extension records an `ExtraMinute` (the chosen minutes of the clock) in `enforcement-state.json`, runs the
  `Enforcer`, which lifts it from the stores, and answers `.defer`, so iOS re-evaluates the shield and opens the app.
  The extension compiles the Enforcer and `UsageSnapshot` (today's use, without Apple's data or SwiftUI).
- Shielded again by the activity `om.end`: schedules count whole minutes and last at least 15, so it is a ~16-minute
  interval whose end warning falls at the first whole minute after the extra time ends. The
  monitor's `intervalWillEndWarning` ends what is due and reconciles. Any wake after the minute also
  reshields it.
- No alert to parents; the journal notes each one. Each is also kept as an `ExtraMinuteUse` (App Group
  `Outbox/extra-minutes.jsonl`), uploaded like requests and sent nearby, so an app's details show it on parents'
  phones too (§15.9).
- **Not yet tried on a phone:** whether the submenu sends only the submenu actions, and whether `.defer` opens the app
  once the stores stop shielding it.

### 15.6 Matching scanned tokens to Apple's data

Tokens can't be decoded (only Apple's daemons can), and iOS shows a token beside its bundle ID only inside the report
and shield extensions, which can't export anything. Matches now come from screenshots (the "By screenshot" item
below); the kid's home screen counts apps first used since the last import that nothing is matched to (apps only:
browsing turns up new domains all the time). **Retired Nov 16:** learning the match from use (`TokenMatching`,
`TokenMatcher`, history before this change); launch stops its `tm` activity on phones that still have it. It worked
like this:
- One activity, `tm`, with an event `m.<item id>` at 1 minute of use (`includesPastActivity: false`) for each scanned
  app and website not matched yet (81 apps and 88 websites on the kid's phone after the scan; 380 events ran fine
  there, §12). Registered after a scan, at app launch if missing or watching less than the build would
  (`State.coverage`), and on the first interval start of each day, which drops matched items.
- A fire wakes the monitor, which samples Apple's data. The one unmatched item of the same kind (app or website) from
  the data with 50–180 s of use since registration (since midnight on later days) is the match, saved as
  `TrackedItem.match`. Of several, only those used since the fetch before the fire count (another may have spent its
  minute long ago, its own event dropped or not matched). Still two or more, or none: the item's event is spent (an
  event fires once per registration), so it is noted in `State.spent`, and the matcher registers again at a miss or
  at the next wake once the last registration is 15 minutes old. That restarts every unmatched item's minute.
- Websites: Apple's data lists subdomains apart (`ss.example.edu` beside `example.edu`), and pages count embedded
  frames' domains too (ad and video SDKs), so a website's minute can coincide with another domain's and come out
  ambiguous more often than an app's. Not yet seen on a phone.
- The baseline is taken from a fresh fetch of Apple's data. A fire whose baseline came from stale data (the app's
  fetch failed, or nothing had fetched for hours) re-registers from the data the fire just fetched, instead of
  matching against it.
- **By screenshot** (`TokenPairing`, Debug → "Match scanned apps by screenshot" on the kid's phone). Only the report
  extension sees a token beside its bundle ID or domain, and on the kid's phone (`.child`, data access) its tokens are
  encrypted under another key than the scan's: same 128-byte layout and 12 zero bytes, different from the first
  encrypted byte, so they never compare equal (they did on the adult test phone in §11). But a report **filtered by
  the scan's tokens** shows exactly those apps (tested Nov 16: the 7 matched apps gave exactly their 7 bundle IDs),
  and several reports run on one screen. So iOS does the comparison: each scanned app and website gets a number (its
  place in `TokenPairing.order`, from 1), and the app shows one report per bit, filtered to the items with that bit
  set, plus a parity report (9 for 169 items; the extension declares 10 scenes, `pair.p`, `pair.b0`…`pair.b8`).
  Each draws a QR code of 6-hex hashes of the identifiers it saw over the last 7 days (28 until Nov 18), named by a fingerprint of
  the order (the extension reads the App Group). Core Image draws nothing in the report extension (not even its
  software renderer), so the codes come from our own encoder (`QRCode`) and a `Canvas`. An identifier's number is the sum of its reports' bits. The kid
  takes 2 screenshots; the app reads them from the photo library with Vision and saves the matches. A pair
  overrides a match from watching use, and another scanned item matched to the same app loses its match and is
  watched again. Hashes are looked up among items from Apple's data and the identifiers a names report (`pair.n`,
  filtered to every scanned item, one large code) spells out; a failed parity check (two scanned tokens for one app)
  is skipped. A match to an app or website the phone hasn't seen in Apple's data (used in the window, before
  tracking began) creates a bare item for it, so parents can name the match; it never counts as a new app. First run
  (Nov 16, kid's phone): 24 new matches, the 7 earlier ones confirmed, no conflicts, and 42
  identifiers unknown without the names report; with it, all 42 matched (73 of 169 in all). Apps unused in the window
  still wait for their minute.
- **Codes too small to read** (Nov 17, a kid's phone with over 200 identifiers): every bit report needed two 600-byte
  codes, stacked in a 190-point cell, with modules rounded to half points (1.5 px on a 3x screen). Codes at 3 whole
  pixels a module still failed: Vision scales a whole screenshot (1179 × 2556) down, and read none of a screenful at
  3 px, about half at 4 px, and all at 5 px. Now modules are 5 whole pixels (`TokenPairing.pixelsPerModule`), centered,
  and a code holds up to 1150 bytes (version 28: as wide as a 2x phone's screen at 5 px). The app sizes each report
  from the scan (`TokenPairing.estimatedCodes`), in one column unless two fit; the extension lays several codes out in
  the grid that draws them largest. About 5 screenshots on a 3x phone with 200 identifiers.
- **By a parent's camera** (Nov 18; `CameraPairingView` on the kid's phone, `PairingScannerView` on the parent's, under
  Settings → the kid). The same reports and the same pairing, in either mode (new apps or everything, the same
  switch as the screenshots'), without screenshots or the photo library. The kid's
  phone shows one report at a time, filling the screen, names report first; reports drawn for a camera
  (`TokenPairing.Display`, saved in the App Group before any report draws) hold at most 600 bytes a code (version 19,
  93 modules: about 7 px a module across a 2x phone) and cycle through their codes every 0.7 s. The parent's phone
  reads them with VisionKit's live scanner and, whenever it has every part of a report (`TokenPairing.complete`),
  sends every complete report's codes over the nearby link (`LinkBundle.pairing`, `LinkPairing.codes`); the kid's
  phone moves on to the first report not read yet. The kid's phone tells parents what it shows (`.progress`, also in
  every 15 s bundle, so a parent's phone that connects later knows) and, once all are read, pairs and sends what it
  found (`.result`). A parent's phone sends a report again when the kid's phone shows one it has read (reopened, or a
  message lost). A report that draws no code can be skipped by hand; a skipped bit report means nothing pairs.
  Needs both apps open and the link up, so a parent each time new apps are to be matched. Tried on the phones Nov 18:
  the link came up over Wi-Fi in seconds and a "new apps" round matched 11 categories and a website, none missing or
  in conflict. Kid heartbeats carry the last match's time (`Heartbeat.lastTokenPairing`; the kid's phone sends one
  after each match), so a parent's phone counts the apps used since that no scanned item matches
  (`TokenPairing.toMatch`, as the kid's home screen does) and says so on the kid's card and day, with a link to
  the camera.
- **Categories** (Nov 17) pair the same way, in reports of their own: a report filtered by a category shows every app
  in it, so categories can't share the apps' bits. The scan's categories (`TokenPairing.categoryOrder`, about a dozen)
  get a parity report and up to 5 bit reports (`pair.cp`, `pair.c0`…`pair.c4`), filtered by category tokens only, which
  spell out the names of the categories they see (`localizedDisplayName`, as the Sampler names category items). A
  scanned category's match is Apple's category item of that name; one the phone hasn't seen is created. A category
  unused in the window stays unmatched. **Works on the kid's phone** (Nov 18): a filter of category tokens alone
  shows just those categories, and every category used in the window matched its own label. The scan also returns
  a category token labelled "AllAppsAndCategories" (the All Apps & Categories pick itself, it seems): it never
  matches, and nothing on the phone tells its token from a real category's, so it stays listed as not matched.
- **New apps only** (Nov 17, `TokenPairing.Mode`, the default): after a first round, a new app's match can't come
  from one code (the token is what's unknown), but every code can be tiny. In `unmatched` mode the numbers go only
  to scanned items with no match (a rescan keeps matches, so these are the new tokens and those still unused), and
  the reports leave out apps, websites and categories already matched, so each bit report holds the hashes of the few new
  identifiers: about 45 modules, three to a row, and all the codes in one screenshot. "Everything" (`all`) checks
  every match again. The app saves the mode in the App Group (`token-pairing-mode.json`) before the reports draw,
  since the report extension can't be told it any other way. The app sizes the reports from at most the apps and
  websites nothing is matched to, plus 4 spare (`TokenPairing.estimatedLines`). An app installed since the last scan
  has no token: scan again first.
- **A rescan can re-issue every token** (Nov 19, kid's phone): the scan's tokens share their first encrypted bytes,
  and those bytes changed between Nov 16 and Nov 19 with no new grant in the journal (a shield's token that evening had
  the new ones too). Old tokens still worked in report filters, but a rescan returned the same apps under new tokens
  (`189 picked, 371 changed`): new, unmatched items, while the old ones lost their tokens and kept their matches.
  Those matches counted, so `unmatched` rounds skipped those apps and nothing could be blocked by name. Now only
  scanned items with a token count as matches (`TokenPairing.matchedIDs`); a tokenless item's match says its app needs
  a match round, not a scan (`TokenPairing.unmatched`).
- **"Apps" that are websites** (Nov 19, kid's phone): Depop, Urban Outfitters, Amazon, NYTimes and NYT Cooking had
  use, but no scan or match found them, and the picker listed only their websites, even searched for by name. None was
  installed (`devicectl device info apps --include-all-apps`): every minute of theirs fell inside Safari's in the same
  interval (`2.0` beside Safari's `2.0`), and Apple listed no website for those shops. Apple's data reports a website's
  time under its App Store app's bundle ID too, so it counted twice in all-apps totals. `WebMirror` finds them: no live
  match and 95% of the last 7 days inside Safari's. The Sampler keeps a tally (`web-mirror.json`); all-apps limits and
  parents' "Apps (Apple's count)" leave them out (through `exempt`), and so does the unmatched list. Category limits
  still count them: Safari isn't in the shop's category, and it's the only record of the shop.
- **Apple's apps need a search:** "All Apps & Categories" leaves out Safari (and maybe Find My, Clock, Fitness), but the
  picker lists it when searched for by name; ticking it adds it to the scan. Ask for more time's picker gave Safari's
  token too, and the next scan dropped it: a scan now drops only tokens the last scan picked, and a token picked again
  goes back to its item, match and all.
- **Apps nothing blocks** (Phone, Settings, Compass, the Screen Time unlock screen; `BuiltInApps.unblockable`) are left
  out of the unmatched list: a token wouldn't block them.
- **Speed** (Nov 18): the codes took 20+ s to appear on the SE. Drawing them isn't it (a small code is ~10 ms in a
  debug build). Each report fetched 28 daily segments, and every redraw of the screen made new filters (their end
  was `Date()`), so every report fetched again. Now the window is the last 7 days in one `.weekly` segment
  (`TokenPairing.days`; iOS may still split it at a week boundary), its end is fixed while the screen is open, sizes
  are computed without drawing a code (`QRCode.size(bytes:)`), and each mask's penalty is computed once. Each
  report's caption shows its segments and the seconds spent fetching and drawing.
- A matched scanned item uses its match's numbers (`UsageSnapshot.todayUsage`): limits count it, grants run by use.
  A scanned category counts through its match's name (`EnforcementPlanner.categoryNames`): before, a limit on one
  counted nothing in our numbers (only its `lim.` event enforced it), and Always Allowed categories neither left all-apps
  limits nor let their apps through Downtime. `.all(except:)` takes apps only, so an allowed category lets through
  the scanned apps matched to its apps; unmatched apps stay shielded.
- Parents' and kids' phones name apps from the App Store's public lookup (`itunes.apple.com/lookup?bundleId=`, cached in
  `app-catalog.json`) or `BuiltInApps`, with icons; the policy pickers sort and search scanned apps by their match's
  name, and scanned categories by their match's. Unmatched ones are listed apart, by `Label` only.

### 15.7 Change history (Nov 17, 2026)

Every Save on the policy screen also saves a `PolicyChange.<uuid>` record: the kid, the time, the parent's name (as
on grants: their name from Settings, else "Parent A"/"Parent B") and the policy before and after. A save that changes
nothing adds none. The history keeps whole policies, not text, so it names apps as they're named now
(`PolicyEdit.between` diffs them in ThymeCore). Screen Time → Change history lists a kid's changes with each parent's
answers to requests for more time (`TimeGrant`s), oldest first, by day, opening on the latest. Only parents' phones
read it; kids' phones never fetch it. Changes made before this build aren't in it.

### 15.8 Groups and Downtime for some apps (Nov 18, 2026)

- **Groups** (`ItemGroup`, in `Policy.groups`) are the parents' own categories: a name and apps, websites and Apple's
  categories. An app may be in several; groups don't nest. Limits, Always Allowed, Blocked and Downtime windows name
  groups by id beside items, so a change to a group changes everything that uses it. `Policy.resolved` replaces group
  ids with their items; the planner, Enforcer and block page work on it. Deleting a group removes its uses.
- **Downtime for some apps:** a window with `items` blocks only those (and its groups' items), not the whole phone;
  none means the whole phone, as before. Whole-phone Downtime is still the first window that's on; every window for
  some apps that's on is applied at once (`EnforcementPlan.scopedDowntime`), in its own store `downtime.some`
  (`.2` … for more than 50 apps): app and website tokens one by one, categories as `.specific(except:)` Always
  Allowed and granted apps. A window of an emptied group blocks nothing (`Policy.downtimeItems`), never the whole
  phone.
- Its shields name the app (or the category), so a request or one more minute lets just that through until the
  window ends; only a press that names nothing pauses the window. Grants and minutes are per window occurrence
  (`AppliedGrant.windowStart`, now taken from the policy, so it's right even while Downtime is paused).
- Excepted apps are shared across the windows that are on: an app granted in one window passes another window's
  categories too (not its own token shield). Rare, and accepted.
- Old builds ignore both fields: a kid phone on an old build enforces a window for some apps as whole-phone Downtime,
  and an old parent build drops groups when it saves. Update every phone.

### 15.9 An app's details (Nov 19, 2026)

One screen per app or website (`AppDetailsView`), the same on parents' phones and the kid's: whether it's blocked now
and why, its use (today, yesterday, 7 and 30 days, a daily average over the days before today the phone reported, and
a 30-day chart), the groups, Always Allowed and Blocked lists it's in, the Downtime windows and limits that cover it
(each saying how: itself, a group, its category, or the whole phone), the last 30 days' requests for more time and one
more minutes for it or its category, its alert rules, and its bundle ID, category and whether the scan is matched.
Its Raw usage opens the raw list (`RawUsageView`) narrowed to the app, on the last day it was used.
- ThymeCore's `AppDetails` works it out. A matched app is two items, Apple's (usage) and the scan's (the token the
  policy names), and the details cover both and every category item for its category.
- Parents open it from a kid's day (Apps, Websites), Apps seen, Always Allowed and Blocked; the kid from Home › Apps
  (`KidAppsView`, apps used in the last 30 days) and the Screen Time lists.
- Parents' phones work out "blocked now" from what has synced: the policy, today's samples, answers and one more
  minutes, with `EnforcementPlanner`; the kid's phone reads its applied plan. A limit's numbers count everything the
  limit counts.
- The kid's phone keeps every answer it applied (App Group `grants.jsonl`): the enforcement state keeps only today's.

## 16. Losing data access, and iOS's count restarting (Nov 15, 2026, the kid's iPhone SE)

A parent's Always Allowed change didn't reach the kid's phone for over an hour: the monitor extension hadn't woken
for hours, so nothing fetched the policy. The device logs (`log collect`) showed two separate causes, in this order:

1. `ScreenTimeAgent` receives the family's Screen Time settings ("blueprints": bedtime, budgets; the restore in §15).
2. Half a minute later it requests "internal authorization", and FamilyControls logs *Reset authorization … not
   determined* for ScreenThyme. iOS stops our activities.
3. The app re-registers. Threshold fires keep coming, but every fetch in the extension fails `unauthorized`.
4. Hours later, "Allow usage data access" → *Approved with Data Access*. Screen Time's internal authorization is
   revoked, and iOS stops our activities 0.4 s after the app re-registered.
5. The app re-registers again. `UsageTrackingAgent` now puts the next threshold about half an hour of use away;
   just before the grant it was under a minute away.

- **Apple's Screen Time takes data access back silently.** The app learned of it only at a heartbeat (app launch).
  The extension now alerts parents at the first refused fetch (`RuleEngine.accessAlert`, once per loss and day).
- **A new grant can restart iOS's count of today's use lower** (by tens of minutes), while thresholds still replay
  "from midnight" in iOS's count. A ladder registered above our total then waits that much use for its next wake.
  A fresh registration now adds **probes** below our total (2, 4, 8, … min under it, and 2 min; `p.<minute>`).
  iOS replays those it has passed; after 3 s the highest one settles `LadderCalibration.offset` (ours minus iOS's),
  and the ladder re-registers in iOS's minutes. Fires are journaled as `t.<our minute>`. Ladder replays within 60 s
  of that registration only refine the offset. Probe and replay fires aren't journaled as use. Midnight clears it.
- `UsageTrackingAgent` logs "`t.<n>/<activity>/<team>.<bundle id>` has N seconds remaining" for each threshold:
  the quickest way to see where iOS's count is.

### Apple's Always Allowed outlives App & Website Activity (Nov 15, 2026, evening)

During Downtime about 30 apps (location sharing, banking, maps, calendar, utilities…) opened normally, though our
`downtime` store was `.all(except:)` only the 5 Always Allowed apps and ScreenThyme. The device logs:
- `dmd` logs each app's combined verdict when a shield store changes: *Requested application `<bundle id>` has policy
  OK* or *Shielded* (with its category, `DH10xx`), or *is unblockable* (Phone, Settings, Compass and a few system
  services). The OK apps were the kid's Apple Always Allowed list, restored by a parent in §15, plus Apple's defaults
  (Messages, FaceTime, Find My, Safari, Clock, Wallet).
- **The family's Screen Time blueprints stay installed after a data-access grant turns App & Website Activity off**:
  `always_allow_activation_family_…` (enabled), the bedtime downtime and the usage limits. `ScreenTimeAgent` applies
  the allowed apps through its own store (container `com.apple.ScreenTime`, `AllowedAppsStore`), and an app it allows
  passes every shield, ours included. With App & Website Activity off, Settings has no Always Allowed list to show
  or edit, and nothing in our App Group shows it either.
- **Fix:** on a parent's phone, turn the kid's App & Website Activity back on, empty Always Allowed (Phone stays),
  delete the App Limits and turn Downtime off. That resets ScreenThyme to "not determined" (as above); on the kid's
  phone, "Allow Screen Time access", then usage data access (which turns App & Website Activity off again), then
  restart. Afterwards every app but ours to allow and the unblockable ones showed the Downtime hourglass.

## 17. Nearby link: family phones talk directly, without the internet (Nov 15, 2026)

CloudKit needs the internet on both phones. In a car, on a plane or camping, the kid's phone keeps capturing and
enforcing, but parents see nothing and a request for more time can't be answered. When ScreenThyme is open on a kid's
phone and a parent's phone near each other, the two now talk directly: Bonjour (`_screenthyme._tcp`) over
Network.framework with `includePeerToPeer`, so a shared Wi-Fi network isn't needed (Apple's peer-to-peer Wi-Fi works
with Wi-Fi on and no network joined, including in airplane mode with Wi-Fi turned back on).

**Foreground only, by design.** iOS suspends the sockets with the app, the monitor extension lives for seconds, and
background Bluetooth between two iPhones is too unreliable to build on. So the link starts when the app becomes active
(before any network call) and stops when it goes to the background. Asking for more time already opens ScreenThyme on
the kid's phone, which is the case this is mostly for. CloudKit stays the source of truth: every record keeps its
CloudKit id, so the copies that arrive later overwrite what came nearby.

**Routes:** both at once, the same protocol over either (`LinkTransport`).
- Wi-Fi (`NetworkTransport`): TCP to a Bonjour service, on a shared network or peer-to-peer Wi-Fi.
- Bluetooth (`BluetoothRadio`), for Wi-Fi off: the kid phone publishes an L2CAP channel and advertises a service whose
  one characteristic holds the channel number; the parent phone scans for it, reads the number and opens the channel.
  Service and characteristic ids are derived from the family secret. No Bluetooth pairing (the link encrypts), and
  foreground only like Wi-Fi: no background modes. Throughput is tens of KB/s; the first bundle was 37 KB.
- A phone reachable both ways gets updates on Wi-Fi only (else on its oldest connection); the other connection stays
  open, idle, for when Wi-Fi drops. The parent rescans every 15 s, since a scan reports a phone only once.
- Each phone asks once for Local Network and once for Bluetooth access. Development builds log the link's events to
  Application Support/nearby-diagnostics.txt (copy with `--domain-type appDataContainer`).

**Who talks:** kid phones listen; parent phones browse and dial (`ScreenThyme/Nearby/NearbyLink.swift`).
- Kid → parent: kid, items, epoch, today's and yesterday's fires and samples, a fresh heartbeat (`source: .nearby`),
  alerts and requests. Every 15 s while connected the kid sends what changed (`LinkSentFilter`), and samples Apple's
  data every 60 s, so a parent watching sees current numbers. The parent ingests it into its mirror and shows a banner
  for alerts under an hour old ("asks for more time" is one).
- Parent → kid: the kid's policy (newer `updatedAt` wins, as with CloudKit), the last rule set this phone published
  (`LocalRules.updatedAt` now records the `RuleSet` date, so an older set from a parent nearby can't replace a newer
  one from CloudKit), and answers from the last two days (`Enforcer.apply`, once per request).
- A parent's saves of grants, policies, rules and rule sets that fail for lack of network wait in `PendingSaves`
  (archived `CKRecord`s) and are retried at every refresh. The kid's phone already queues its own uploads.

**Pairing is the family zone.** The zone's owner creates `LinkKey.<fixed id>` (32 random bytes, create-only so two
launches can't race to different secrets); every phone fetches it by name at refresh (`LinkKeyService`). So each phone
needs the internet once after this version, and no other pairing step. The protocol (`ThymeCore/Link`, unit-tested):
- Bonjour TXT `f` = a tag derived from the secret: parents skip other families' services. A kid's service name is
  derived too, so it doesn't name the kid.
- Frames: 4-byte length + AES-GCM. Hellos (role, kid id, name, a fresh 32-byte nonce) are sealed with a key derived
  from the secret. Bundles (lzfse-compressed JSON) use HKDF keys from the secret and both nonces, one per direction,
  with a counter as the GCM nonce: recorded, replayed, reordered or reflected frames fail. A peer counts as connected
  only after its first bundle opens, since a hello alone could be a recording.
- Trust is the same as CloudKit's: every family phone, the kid's included, has the secret, as it already has
  read/write access to the zone.

**Not covered:** parents don't forward a kid's records to CloudKit for it (the kid's phone uploads them itself when
it's back online); parent-to-parent sync; rule deletions made offline reach the kid (through the rule set) but the
`Rule` record's deletion needs the network. The owner may get a second "asks for more time" banner when the kid's
phone later uploads the alert.

**Status (Nov 15, 2026, the two phones):**
- Wi-Fi on the home network: connected within a second of the kid phone starting, 596 records (37 KB compressed) in
  the first bundle, then a few records every 15 s.
- Bluetooth with Wi-Fi off on both: found and connected 2 s after the parent app opened; the kid's first bundle, 611
  records (38 KB), arrived within a second, then updates every 15 s. When Wi-Fi came back, updates moved to it.
- Testing found the kid app killed by the watchdog (`0x8badf00d`, 10 s) while applying a policy on the main thread:
  `Enforcer.registerActivities` blocks in a synchronous call to Apple's usage-tracking service. It happened before the
  nearby link too, after a push (`refresh()` → `KidSync.savePolicy`). The app now enforces off the main thread
  (`Enforcer.offMain`). Monitoring checks (`DeviceActivityCenter().activities`) still run on it.
- Still to check: peer-to-peer Wi-Fi with no network joined, and an offline request → approval → the app unblocking.

## 18. Bug reports from family phones (Nov 18, 2026)

Every screen, kid and parent, has a bug at the top right (`.bugButton()` beside each `navigationTitle`). It opens
**Report a problem** as a sheet, with a picture of the screen it was pressed on already attached (removable) and that
screen's source file and line in the report. The kid's home screen also links to it. The reporter writes what happened
and adds pictures from Photos (`PhotosPicker`, no photo-library permission), five in all. The phone itself files it as
a GitHub issue; nobody needs a GitHub account. This repository is public, so the issues go to a **private** repository: a kid's words and screenshots
(names, usage) must not be published.

- **Where:** a parent enters the repository (`owner/name`) and a fine-grained token in Settings › Bug reports. It is
  saved as `IssueTracker.<fixed id>` in the family zone and fetched by name each time a kid's phone files
  (`IssueTrackerService`). Every phone in the family can read the token, as it can read the zone; scope it to that
  one repository, with Issues and Contents read and write, so a leak can only file issues and add files there.
- **Screenshots:** GitHub's API can't attach images to an issue. Each picture is shrunk to at most 2000 px as JPEG
  (which also drops its location metadata), committed under `reports/<day>-<id8>/` with the Contents API, and shown
  in the issue from its page (`…/blob/<branch>/<path>?raw=true`), which renders only for people with access.
- **The issue:** title `<reporter>: <first line>` (the kid's name, or the parent's from Settings); body: their words,
  the pictures, a table (time sent, the phone's role, screen, app version, when the build was made, iOS, phone model,
  family; on a kid's phone Screen Time access, monitoring, last wake, upload backlog; on a parent's the number of kids
  and changes waiting for the internet; phones nearby) and yesterday's and today's journal notes, collapsed. Logic and formatting are in
  `ThymeCore/BugReport` (`GitHubIssues`, unit-tested with a fake transport).
- **Queue:** reports wait in the app's Application Support (`BugReportQueue`, `BugReports/`), sent at once, then at
  every launch, background refresh and visit to the screen, until filed. Each upload is saved as it succeeds, so a retry
  skips screenshots already committed (a 422 on one already there is answered by fetching it). Filing stops at the
  first failure; the kid sees why ("Waiting for the internet", "Waiting for a parent to set up bug reports", GitHub's
  message). Pictures are deleted once filed; the last 20 filed reports stay listed as "Sent".
- **Not covered:** a report whose issue was opened but whose answer was lost is filed again on retry (a duplicate
  issue). The picture of the screen can't show Apple's own views (the report extension's, the pickers).
