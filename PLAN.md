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

**One ladder shape for every app, domain and category:**
- every **5 min** from 5 to 60 min (12 events)
- then every **15 min** from 75 min to 12 h (44 events)
- **56 events per item**, so about 100 apps plus categories comes to roughly **6,000 events**

Event names encode the item and the minute, e.g. `a:<itemUUID>:<minute>`.

**Plus one total ladder:** `includesAllActivity`, every **1 min** up to 16 h (960 events). This is cheap: a single series. It gives us:
- **"phone in use right now"**, within about 1 minute
- the minute-by-minute **in-use timeline** that app usage is placed onto (§4.2)
- untracked time: the total minus all tracked apps
- an implicit heartbeat

**Schedules:** each activity is a repeating **daily** `DeviceActivitySchedule` (00:00–23:59).

**Activity budget (max 20):**
- app/domain ladders: 1–4 activities, split by item count if the per-activity cap requires it (S1)
- categories: 1
- total: 1
- spare: the rest, for re-scans without gaps

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
| `Heartbeat` | `kidId`, `at`, `source` (fire/bgRefresh/ping/launch), `authStatus`, `activeActivities`, `appVersion`, `backlogCount` |
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
| **Daily threshold** (app or category) | Thresholds snap to the ladder (multiples of 5 up to 60, multiples of 15 above). If the parent wants an exact value off the ladder, add one extra event for it. |
| **Long session** | The extension tracks the current in-use run (from total fires) and the app crossings within it. The run passes N min and is dominated by one app → alert. Precision is about ±5 min. |
| **New / untracked usage** | Untracked in-use time over N min → alert ("9 min on apps added since the last scan, category Games") plus a prompt to re-scan. If S4 works, real new-bundle-ID detection is also possible. |
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
- **Parent-side checks:**
  - authorization not approved → **immediate alert**
  - missing activities → **immediate alert**, and the kid app re-registers on its next launch
  - no heartbeat for more than X hours during waking hours → **alert** ("offline since 3:12pm"), which covers airplane mode, Wi-Fi off and Background App Refresh off
  - backlog growing → warning
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
- **Role switch:** the same install can switch between the kid and parent roles without reinstalling, so the phone can capture and then view its own data after a CloudKit round trip.
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
