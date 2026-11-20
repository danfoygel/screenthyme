# ScreenThyme

Family-only iPhone app: kids' phones capture per-app screen time (a Screen Time threshold alarm wakes the extension every minute of use; it reads Apple's per-app hourly data, iOS 26.4 data access); parents' phones show it within a minute or two. One app, two roles (kid / parent). The design, platform constraints and spike plan are in `PLAN.md`; read it before changing capture or reconstruction.

## Project layout

```
project.yml          XcodeGen spec — source of truth for the Xcode project
ThymeKit/            local Swift package, product ThymeCore: pure logic, no Apple Screen Time/CloudKit imports
  Model/             records (Kid, TrackedItem, UsageFire, UsageSample, Heartbeat, AlertRecord, Rule, Ping, LadderEpoch), DayKey
  Ladder/            RollingLadder (the 1-minute wake alarm), EventName encoding
  Journal/           append-only JSONL with flock + fsync, upload ledger
  Reconstruction/    total fires + samples → in-use strip, per-app blocks and totals, live status
  Rules/             RuleEngine (kid-side alerts), HealthEvaluator (parent-side)
  Details/           AppDetails: one app's groups, lists, Downtime, limits, use and requests (its details screen)
  Link/              nearby link protocol: LinkKey (family secret), LinkSession (hello, AES-GCM frames), LinkBundle
  Energy/            EnergyLedger: our processes' daily energy from kernel counters (sampled by Shared/Energy)
  Places/            Place, PlaceEvent, PlaceStays: geofences and visits → stays → use by place (PLAN.md §19)
  BugReport/         a kid's bug report, the family's GitHub repo and token (IssueTracker), filing it (GitHubIssues)
  Replay/            Trace, retarget/schedule, synthetic traces and scenarios
Shared/              compiled into the app AND the monitor extension: App Group files, SharedConfig, CloudKit records, Uploader
ScreenThyme/         app target: App/ (model, delegates), Sync/ (zone, share, fetch, local mirror), Nearby/ (local link), Kid/, Parent/, Components/, Debug/
ThymeMonitor/        DeviceActivityMonitor extension: journal → sample (≤3 s) → rules → roll → ≤3 s upload. Keep it small (~6 MB limit)
ThymeReport/         DeviceActivityReport extension (ExtensionKit): Apple's own numbers, kid phone only; also the
                     token-pairing QR codes (reads the App Group, can't write it)
ThymeShield/         ShieldConfiguration extension: the block page (reads the App Group; can't write it)
ThymeShieldAction/   ShieldAction extension: "Ask for more time" notes what was blocked and opens ScreenThyme;
                     "One more minute" runs the Enforcer itself (PLAN.md §15.5)
ScreenTour/          UI test, Simulator only: the screen map's screenshots
Tools/ScreenMap/     the screen map (kid and parent screen flows, published to GitHub Pages); see its README
Tools/BugPush/       the bug repository's workflow that pushes "fixed" to the reporter's phone; see its README
```

- **`ScreenThyme.xcodeproj` and the Info.plist / .entitlements files are generated and git-ignored.** Change `project.yml`, then `xcodegen generate`. Run it after adding or removing files.
- Logic belongs in ThymeKit with Swift Testing tests; the app targets are thin.
- The monitor extension reads `SharedConfig` (App Group `config.json`) on every fire and never writes it; the app owns it.
  Rules live in `rules.json`, which both write (`KidSync.saveRules`, under a lock).

## Identifiers

| | |
|---|---|
| App / extensions | `com.danfoygel.screenthyme`, `.monitor`, `.report`, `.shield`, `.shieldaction` |
| App Group | `group.com.danfoygel.screenthyme` |
| iCloud container | `iCloud.com.danfoygel.screenthyme` (CloudKit; zone `Family`) |
| Signing team | `ZVU48K8YCD`, automatic signing, development builds only (no Family Controls distribution entitlement) |
| Deployment target | iOS 26.4; Swift 6 language mode (toolchain: Xcode 27.2, Swift 6.4.2) |
| Devices | The parent's iPhone 17 and the kid's iPhone SE (child account); their UDIDs are in `CLAUDE.local.md` (git-ignored) |

## Commands

```bash
xcodegen generate
(cd ThymeKit && swift test)                       # unit tests, run on the Mac

# Pull the App Group off a phone (Xcode 27's devicectl only copies from Library/) and reconstruct
xcrun devicectl device copy from --device <udid> --domain-type appGroupDataContainer \
  --domain-identifier group.com.danfoygel.screenthyme --source Library/ScreenThyme --destination /tmp/st
(cd ThymeKit && swift run thyme-inspect /tmp/st/Journal/journal-YYYY-MM-DD.jsonl /tmp/st/Outbox/samples.jsonl /tmp/st/items.json)

# A parent's local mirror of the family zone
xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
  --domain-identifier com.danfoygel.screenthyme --source "Library/Application Support/FamilyData" --destination /tmp/fd

xcodebuild -project ScreenThyme.xcodeproj -scheme ScreenThyme \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build

# The screen map: screenshots from a Simulator (test data only), the page, then GitHub Pages.
# A change to the app's navigation changes Tools/ScreenMap/build.py's graph too.
Tools/ScreenMap/capture.sh "iPhone Air" /tmp/screen-map && python3 Tools/ScreenMap/build.py /tmp/screen-map
Tools/ScreenMap/publish.sh /tmp/screen-map

# On a parent phone (unlocked): save one test rule of each kind for a kid, set to fire soon (stable ids);
# -removeTestRules <kid name> deletes them
xcrun devicectl device process launch --device <udid> --terminate-existing com.danfoygel.screenthyme -- -addTestRules <kid name>
# Parent phones write notification settings and installed subscriptions to
# Library/Application Support/push-diagnostics.txt (copy with --domain-type appDataContainer)
```

## Pull requests

- **Never push more work to a merged PR's branch: a merged PR can't be updated.** Check first
  (`gh pr view <n> --json state`); once it's merged, branch from the latest `main` and open a new PR.

## What runs where

- **Simulator:** parent UI, test mode, replay tool with "This phone only". No DeviceActivity fires and no iCloud account, so no capture or sync.
- **Real device:** everything else. The first device build with `-allowProvisioningUpdates` registers the App IDs, App Group and iCloud container on the team. CloudKit containers can't be deleted.
- **Device logs:** `sudo log collect --device-udid <udid> --last 30m --output ~/Dev/screenthyme/x.logarchive` (needs
  the user's password). `*.logarchive` is git-ignored; it holds private data, so delete it after use.

## Gotchas

- **Never register many events.** Thousands crashed Apple's `UsageTrackingAgent` on smaller phones (PLAN.md §12).
  The wake alarm is one activity with 20 total-use events (`Shared/ScreenTime/Roller.swift`, `RollingLadder`),
  re-registered by the extension when half are used and at midnight. A fresh registration adds about 9 probes below
  today's total, because iOS can restart its count lower after a grant (PLAN.md §16). Per-app thresholds were removed once data access
  worked (PLAN.md §13; history before `a860884`).
- **Data access** (`AuthorizationStatus.approvedWithDataAccess`, iOS 26.4) needs the
  `com.apple.developer.family-controls.app-and-website-usage` entitlement on the app *and* the monitor extension.
  `DeviceActivityData.activitySegments` is declared in the SwiftUI overlay, so import SwiftUI.
  `FamilyActivityData.installedApplications` hangs.
- `AuthorizationCenter.shared.authorizationStatus` is unreliable in the extension: don't gate on it there.
- Any new authorization grant stops all monitoring; `requestAuthorization` re-registers. It can also restart iOS's
  count of today's use lower: `LadderCalibration` finds the offset, and journaled fires are in our minutes.
- Apple's Screen Time settings for the kid (even re-sent unchanged from a parent's device) can reset ScreenThyme to
  "not determined": extension fetches fail `unauthorized`, and the extension alerts parents (PLAN.md §16).
- **Apple's family Always Allowed list outlives App & Website Activity.** It stays installed on the kid's phone after
  our data-access grant turns Apple's activity off, nothing in Settings shows it, and its apps pass every shield,
  ours included. Empty it (and delete Apple's App Limits and Downtime) before granting data access (PLAN.md §16).
  In device logs, `dmd` gives each app's verdict: "has policy OK", "Shielded" or "is unblockable".
- Silent pushes are rationed: don't depend on one reaching the kid app. Rules reach the extension through the
  `RuleSet.<kid id>` and `Policy.<kid id>` records, fetched at every wake (`KidSync`, App Group `rules.json` and `policy.json`); parents must publish it after every rule change.
- The wake alarm's state is `Rolling/activity.json`. Without it the alarm runs but never rolls or restarts at midnight:
  no fires for the rest of the day. The app re-registers when it's missing, and the extension rebuilds it from the
  epoch; the app holds a background task while registering, since a suspension mid-registration lost it once.
  The midnight restart (`Roller.startDayIfNeeded`) runs at any extension callback of a new day, and the app
  re-registers when the state is from an earlier day. The journal notes each restart ("wake alarm: new day").
- Several sessions install builds on the kid's phone. A build from a branch behind `main` silently undoes `main`'s
  work there (it once dropped `tm`): install only from a branch that contains the latest `main`.
- **`DeviceActivityCenter.stopMonitoring([])` stops every activity.** Only `Roller.registerAll` does that, on purpose.
- Every registration replays today's already-passed thresholds (counted from midnight), in random order, sometimes ~2/s.
  A first registration late in the day becomes a chain of rolls for a few minutes, each journalled as an
  `intervalEnd`/`intervalStart` pair. The reconstruction treats the replays as one burst; avoid needless
  re-registration (`ensureMonitoring` is throttled).
- After a kid's phone grants `.child` authorization, restart it, or no Screen Time data reaches apps.
- **Shields need tokens; Apple's usage data has only bundle IDs.** Enforcement uses the app scan's items
  (`AppScan`, `TrackedItem.isScanned`, PLAN.md §15.3). A shield list with more than 50 tokens shields nothing.
- Scanned tokens are matched to Apple's bundle IDs by a parent's camera or by screenshot (`TokenPairing`, PLAN.md §15.6): the report
  extension's tokens use another key than the scan's and never compare equal, but a report filtered by scanned tokens
  honors them, so one filtered report per bit of each item's number draws a QR code (our own `QRCode`: Core Image
  draws nothing in that extension) that the kid app reads back. Categories pair in reports of their own, by name.
  With a camera, the kid's phone shows one report at a time and a parent's phone sends the codes it read back over
  the nearby link (`LinkPairing`); the reports learn which way to draw from App Group `token-pairing-display.json`.
  The kid's home screen counts new apps to match. By default only unmatched tokens are numbered and only unmatched
  apps drawn (`TokenPairing.Mode`, saved in the App Group for the extension), so new apps take one screenshot. The
  minute-of-use matcher (`tm`) is retired: launch stops it (`RetiredTokenMatcher`).
- A press on a category shield (Downtime) names only the category, so the kid picks the app in ScreenThyme's
  `AskForTimeView` (PLAN.md §15.4).
- Token `Label`s don't render inside menus (menu-style `Picker`); use lists.
- Quick simulator taps don't flip SwiftUI `Toggle`s; use a ~0.2 s press.
- `DeviceActivityEvent` with no tokens means all activity (the wake alarm).
- The Enforcer's activities are `dt.<id8>`, `lim.<id8>` and `om.end` (`Enforcer.owns`); everything else is the wake alarm's
  (or the retired `tm`, stopped at launch).
- Event names are `t.<minute>` (in iOS's count; journaled in ours) and probes `p.<minute>` (never journaled); the activity is `st.<epoch8>.tot`. Old journals also hold per-app `i.<itemUUID>.<minute>`
  fires, which are ignored.
- The nearby link (PLAN.md §17) runs only while the app is open, over Wi-Fi (Bonjour) and Bluetooth (L2CAP) at once:
  kid phones listen, parent phones dial. It needs the family's `LinkKey` record, fetched once with the internet.
  Records sent nearby keep their CloudKit ids. Its events go to Application Support/nearby-diagnostics.txt.
- **Bug reports go to a private GitHub repo, never this public one** (PLAN.md §18). Each phone files its own with the
  token in the family zone's `IssueTracker` record (Settings › Bug reports on a parent's phone); screenshots are
  committed under `reports/` in that repo, since GitHub's API can't attach images to issues. A new screen gets
  `.bugButton()` beside its `navigationTitle`.
- A parent's mirror (`FamilyData`) carries a snapshot version: bump it when stored types change, so phones re-fetch.
- Record names are `<Type>.<uuid>`, saved with `.allKeys`, so every upload is idempotent.
