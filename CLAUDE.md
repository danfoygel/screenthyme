# ScreenThyme

Family-only iPhone app: kids' phones capture per-app screen time with Screen Time threshold events; parents' phones show it within a minute or two. One app, two roles (kid / parent). The design, platform constraints and spike plan are in `PLAN.md`; read it before changing capture or reconstruction.

## Project layout

```
project.yml          XcodeGen spec — source of truth for the Xcode project
ThymeKit/            local Swift package, product ThymeCore: pure logic, no Apple Screen Time/CloudKit imports
  Model/             records (Kid, TrackedItem, UsageFire, Heartbeat, AlertRecord, Rule, Ping, LadderEpoch), DayKey
  Ladder/            LadderSpec (5/15-min item ladder, 1-min total), EventName encoding, LadderPlanner (≤20 activities)
  Journal/           append-only JSONL with flock + fsync, upload ledger
  Reconstruction/    fires → totals, attributed timeline with confidence, live status
  Rules/             RuleEngine (kid-side alerts), HealthEvaluator (parent-side)
  Energy/            EnergyLedger: our processes' daily energy from kernel counters (sampled by Shared/Energy)
  Replay/            Trace, retarget/schedule, synthetic traces and scenarios
Shared/              compiled into the app AND the monitor extension: App Group files, SharedConfig, CloudKit records, Uploader
ScreenThyme/         app target: App/ (model, delegates), Sync/ (zone, share, fetch, local mirror), Kid/, Parent/, Components/, Debug/
ThymeMonitor/        DeviceActivityMonitor extension: journal → rules → ≤3 s upload. Keep it small (~6 MB limit)
ThymeReport/         DeviceActivityReport extension (ExtensionKit): Apple's own numbers, kid phone only
```

- **`ScreenThyme.xcodeproj` and the Info.plist / .entitlements files are generated and git-ignored.** Change `project.yml`, then `xcodegen generate`. Run it after adding or removing files.
- Logic belongs in ThymeKit with Swift Testing tests; the app targets are thin.
- The monitor extension reads `SharedConfig` (App Group `config.json`) on every fire and never writes it; the app owns it.

## Identifiers

| | |
|---|---|
| App / extensions | `com.danfoygel.screenthyme`, `.monitor`, `.report` |
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
  --domain-identifier group.com.danfoygel.screenthyme --source Library/ScreenThyme/Journal --destination /tmp/st/Journal
(cd ThymeKit && swift run thyme-inspect /tmp/st/Journal/journal-YYYY-MM-DD.jsonl [/tmp/st/config.json])

xcodebuild -project ScreenThyme.xcodeproj -scheme ScreenThyme \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
```

## What runs where

- **Simulator:** parent UI, test mode, replay tool with "This phone only". No DeviceActivity fires and no iCloud account, so no capture or sync.
- **Real device:** everything else. The first device build with `-allowProvisioningUpdates` registers the App IDs, App Group and iCloud container on the team. CloudKit containers can't be deleted.
- **Device logs:** `sudo log collect --device-udid <udid> --last 30m --output ~/Dev/screenthyme/x.logarchive` (needs
  the user's password). `*.logarchive` is git-ignored; it holds private data, so delete it after use.

## Gotchas

- **Never register whole ladders.** Thousands of events crash Apple's `UsageTrackingAgent` on smaller phones
  (PLAN.md §12). Capture is rolling (`Shared/ScreenTime/Roller.swift`, `RollingLadder`): a few events per item,
  re-registered by the extension after each crossing and at midnight.
- **`DeviceActivityCenter.stopMonitoring([])` stops every activity.** Only `Roller.registerAll` does that, on purpose.
- Every registration replays today's already-passed thresholds (counted from midnight), in random order, sometimes ~2/s.
  The reconstruction treats them as one burst; avoid needless re-registration (`ensureMonitoring` is throttled).
- "All Apps & Categories" on an adult phone returned 222 apps, 297 websites and 13 categories. Settings and Safari
  aren't offered.
- After a kid's phone grants `.child` authorization, restart it, or no Screen Time data reaches apps.
- Token `Label`s don't render inside menus (menu-style `Picker`); use lists.
- Quick simulator taps don't flip SwiftUI `Toggle`s; use a ~0.2 s press.
- `DeviceActivityEvent` with no tokens means all activity (the total ladder).
- Event names are `i.<itemUUID>.<minute>` / `t.<minute>`; activities are `st.<epoch8>.<n|total>`.
- Record names are `<Type>.<uuid>`, saved with `.allKeys`, so every upload is idempotent.
