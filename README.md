# ScreenThyme

Per-app screen time from a kid's iPhone, on the parents' iPhones within a minute or two, and Screen Time limits that
ScreenThyme enforces itself. A family-only app: one app with two roles (kid / parent), installed with development
builds, not on the App Store.

### [Screen flows →](https://danfoygel.github.io/screenthyme/)

**[The screen map](https://danfoygel.github.io/screenthyme/)** draws every screen, sheet and Apple prompt of both
roles, the tap that leads to each, and a screenshot of each screen on hover:
[kid mode](https://danfoygel.github.io/screenthyme/#kid) ·
[parent mode](https://danfoygel.github.io/screenthyme/#parent). It's built from Simulator screenshots of test data
([Tools/ScreenMap](Tools/ScreenMap/README.md)).

## What it does

Apple's Screen Time shows totals per app and per hour, but not which app was used when, and a kid's usage can take
hours or days to reach a parent's phone. ScreenThyme fixes both, and replaces Apple's limits, since an app that reads
the usage data and Apple's Screen Time can't share a phone.

### On a parent's phone

- **Kids:** a card per kid with live status ("In use · YouTube", or idle since when), today's total, top apps and a
  health dot. A kid's day has a timeline (when the phone was in use, and a lane per app) or the same day as a calendar,
  apps and websites with their minutes, and where they were used; a heatmap shows when in the week use happens.
- **An app's details:** whether it's blocked now and why, its use over 30 days, the groups, lists, Downtime windows and
  limits that cover it, its requests for more time and its alert rules.
- **Screen Time** for each kid, enforced by the kid's phone:
  - Downtime windows, for the whole phone or for some apps
  - daily limits on apps, websites, categories, groups or all apps, with per-weekday minutes
  - Always Allowed and Blocked lists, and **groups**: the parents' own categories
  - Content & Privacy restrictions (App Store, media ratings, web filter, Siri, Game Center, account locks)
  - changes saved for good or for 1–30 days, after which the kid's phone changes back by itself
  - a change history: who changed what, and every answer to a request
- **Alerts**, pushed to both parents: quiet-hours use, daily thresholds, long sessions, new apps, requests for more
  time, and health problems (the phone stopped reporting, lost Screen Time access, or a setting the kid can turn off,
  such as Background App Refresh, was turned off).
- **Places:** a map of where the kid's phone has been. Name a spot and it becomes a place; the day's use is split by
  place ("50 min at home, 12 at school").
- **Settings:** kids, rules, each phone's health and permissions, and where bug reports go.

### On a kid's phone

- A plain status screen: Screen Time access, monitoring, last upload, and the kid's own apps and limits.
- **The block page** says why an app is blocked ("Downtime until 7:00", "Time limit: Social (1 h)", "Not allowed").
  From it the kid can take **one more minute** once a day, or **ask for more time**: pick how long and add a note; a
  parent approves it or changes it, and only that app is let through.
- **Ask to always allow** an app.
- A parent does the setup here: Screen Time permission, the app scan (every installed app, so limits can block them)
  and matching scanned apps to Apple's usage data.

### Everywhere

- **Nearby:** while ScreenThyme is open on a kid's phone and a parent's phone close by, they talk directly over Wi-Fi
  or Bluetooth, with no internet: in a car, on a plane, camping.
- **Bug reports:** a bug button on every screen files a GitHub issue in the family's private repository, with a
  picture of the screen; the phone gets a push when it's fixed.

## How it works

Apple doesn't let apps send usage data off the phone in real time, so ScreenThyme's design is mostly about what iOS
allows. [PLAN.md](PLAN.md) has the design, the platform constraints, and what each device run found;
[CLAUDE.md](CLAUDE.md) has the gotchas.

### Capture (kid's phone)

1. **A wake alarm.** One `DeviceActivity` activity with 20 rolling total-use thresholds, one per minute of use, wakes the
   monitor extension each minute the phone is in use. The extension re-registers when half are used and at midnight.
2. **Apple's data.** With iOS 26.4's data access (`approvedWithDataAccess`), the extension reads today's per-app use by
   bundle ID and domain (hourly segments), and keeps the difference from the last read as samples.
3. **Journal → rules → upload.** Each wake appends to an fsynced JSONL journal in the App Group, evaluates the alert
   rules, applies the Screen Time policy, and uploads to CloudKit within about 3 seconds. Anything left over waits in
   an outbox for the next wake or the app.

The extension has a ~6 MB memory limit and a few seconds per callback, so it stays small: no SwiftData, only JSON files.

### Reconstruction (parent's phone)

The minute-by-minute wake fires and the per-app samples become an in-use strip, per-app blocks and totals, sessions and
a live status. It's pure Swift in `ThymeKit/Reconstruction`, run over the raw records, so better heuristics re-render
all of history.

### Sync

- **CloudKit:** the first parent owns a `Family` zone in their private database and shares it with the other parent
  and each kid. Records are named `<Type>.<uuid>` and saved whole, so every upload is idempotent.
- Kids' phones write fires, samples, heartbeats, alerts, requests and place events; parents write kids, rules, policies
  and answers. The kid's extension fetches its `Policy` and `RuleSet` records by name at every wake, since silent pushes
  are rationed.
- Parents keep a local mirror of the zone as JSON files (`FamilyData`) and get alerts as visible pushes from CloudKit
  subscriptions.
- **The nearby link** is Bonjour over peer-to-peer Wi-Fi and an L2CAP Bluetooth channel at once, with AES-GCM frames
  keyed from a family secret in the zone. Records keep their CloudKit ids, so the copies that arrive later overwrite
  them.

### Enforcement (kid's phone)

- `EnforcementPlanner` (pure, in ThymeKit) works out what's blocked now from the policy, the clock, today's use and
  the answers to requests. The `Enforcer` applies it to `ManagedSettings` stores (restrictions, Downtime, limits) and
  registers a `DeviceActivity` activity for each Downtime window and limit; every wake also reconciles.
- **Shields need tokens, and Apple's usage data has only bundle IDs.** So a parent scans every installed app once
  (`FamilyActivityPicker`), or Apple's lists of installed apps give them (iOS 26.4 data access), each with the
  bundle ID it's matched to.
- Shield extensions draw the block page and handle its buttons: "One more minute" runs the Enforcer itself, and "Ask
  for more time" opens ScreenThyme.

### Health

Heartbeats (from wakes, launches, background refresh and parents' pings) report authorization, registered activities,
the upload backlog and the Settings switches the kid can turn off. Parents' phones evaluate them (`HealthEvaluator`)
and alert when something's wrong.

### Code

| | |
|---|---|
| `ThymeKit/` | Swift package `ThymeCore`: the logic (model, journal, wake alarm, reconstruction, rules, enforcement planning, app details, nearby protocol, places, bug reports, replay), with no Screen Time or CloudKit imports, so it's tested on the Mac. Also `thyme-inspect`, which reconstructs a day from files copied off a phone. |
| `Shared/` | Compiled into the app and the monitor extension: App Group files, CloudKit records, the uploader, the wake alarm and the Enforcer. |
| `ScreenThyme/` | The app: the kid and parent screens, sync, the nearby link, debug tools. |
| `ThymeMonitor/` | `DeviceActivityMonitor` extension: the capture loop above. |
| `ThymeReport/` | `DeviceActivityReport` extension: Apple's own numbers on the kid's phone. |
| `ThymeShield/`, `ThymeShieldAction/` | The block page and its buttons. |
| `ScreenTour/` | UI test that takes the screen map's screenshots in a Simulator. |
| `Tools/ScreenMap/` | The [screen map](https://danfoygel.github.io/screenthyme/). |
| `Tools/BugPush/` | The bug repository's workflow that pushes "fixed" to the reporter's phone. |

## Building

Needs Xcode 27.2 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project, Info.plists and
entitlements are generated from `project.yml` and git-ignored.

```bash
xcodegen generate
```

```bash
(cd ThymeKit && swift test)
```

```bash
xcodebuild -project ScreenThyme.xcodeproj -scheme ScreenThyme -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build build
```

The Simulator runs the parent screens, a single-phone test mode and the replay tool's synthetic days; capture,
enforcement and sync need real phones in a Family Sharing group, and the Family Controls and usage-data entitlements
on the signing team. [CLAUDE.md](CLAUDE.md) has the device commands.
