# ScreenThyme on Android — Plan

ScreenThyme's capabilities on Android phones, for kids and parents, with iPhones and Android phones in one family.
Nothing here is built yet. Section numbers like §15.4 refer to `PLAN.md`.

## 1. Bottom line

- **Capture gets simpler.** On Android, `UsageStatsManager` gives every app's foreground start and stop to the
  millisecond, plus the app's name, icon and package name. The package name is also what blocking uses. That makes a
  lot of the iOS machinery unnecessary on Android: the wake alarm, probes and calibration, handling replay bursts,
  guessing when use happened (`CheckIns`), tokens, the app scan, token matching and the 50-token shield cap
  (`ShieldBudget`).
- **Three things are harder:**
  - **Blocking:** Android has no Screen Time–style API for third-party apps. Real enforcement means making
    ScreenThyme the kid phone's **Device Owner**.
  - **Websites:** there's no per-site time at all.
  - **Sync:** CloudKit isn't native on Android.
- **Recommended shape:**
  - Compile ThymeKit for Android with Swift's Android SDK, so the policy logic isn't written twice.
  - Use Kotlin and Jetpack Compose for the screens and platform code.
  - Keep CloudKit as the source of truth, reached through CloudKit Web Services, with FCM (Firebase Cloud Messaging)
    for pushes.
  - Mixed families (iPhone parents with an Android kid, or the reverse) work from the start, and the iOS side barely
    changes.

## 2. Key differences

| Area | iOS today | Android | Consequence |
|---|---|---|---|
| **Usage data** | Apple's per-app seconds, hourly at finest; a fire each minute of use wakes us | `queryEvents`: each app coming to the front or leaving it, timestamped; also screen on/off and unlock. Needs "Usage access" | Exact sessions: the in-use strip is exact, and live status says "using YouTube" rather than "probably". Android keeps events only for days, so upload promptly |
| **Websites** | Per-domain seconds | Nothing; a browser counts as one app. Per-site time only by reading Chrome's address bar with an accessibility service (fragile), or domains without time from a local VPN's DNS | **The biggest loss.** No website timelines or limits. Web filtering moves to Chrome policies |
| **Running in the background** | An extension gets seconds per callback, ~6 MB | A foreground service runs while the screen is on (with a persistent notification); WorkManager at most every 15 min otherwise; Samsung, Xiaomi and others kill background apps aggressively | The capture loop is simpler, but it has to survive manufacturers' battery killers: ask to be exempt from battery optimisation and check it in health |
| **Blocking** | ManagedSettings shields with opaque tokens, 50-token cap | No public API. As Device Owner: suspend apps (`setPackagesSuspended`), hide them (`setApplicationHidden`) and set user restrictions. Without it: an accessibility service puts our screen over the app, which a kid can get around | **A Device Owner is a setup prerequisite**: it's installed with adb on a phone with no accounts, or after a factory reset |
| **Block page** | Our ShieldConfiguration and ShieldAction extensions | Either the system's "app isn't available" dialog for suspended apps, or our own full-screen activity | Ask for more time and One more minute live in ScreenThyme. The blocked app is always known, so the kid never picks it, as they do after an iOS Downtime shield (§15.4) |
| **Tamper resistance** | Under `.child` the kid can't delete the app, but Apple's settings can silently revoke data access (§16) | A Device Owner can block uninstall, force stop, factory reset, safe boot, clock changes, new users and guest, Private Space, and developer options | **Stronger than iOS.** There's no §16-style silent revocation. A kid can still turn off Usage access unless Settings is locked down, and heartbeats report it |
| **Sharing with the platform's own controls** | Apple's Screen Time and our data access exclude each other | Usage data works alongside Family Link. Whether Family Link supervision and our Device Owner can coexist is **unknown** | Spike 1 (§7) |
| **App names and categories** | Bundle IDs, named from the App Store lookup; Apple's fixed categories | Name and icon come from the phone's PackageManager; no public Play Store lookup. `ApplicationInfo.category` is often UNDEFINED | Kid phones upload names and icons. Custom categories (§15.14) do more of the work |
| **Sync** | Native CloudKit, a zone share, subscriptions | CloudKit Web Services (REST), signed in with an Apple Account; no CloudKit pushes | **Every Android user needs an Apple Account** (a kid's can be made from a parent's iPhone) |
| **Pushes** | APNs, silent pushes rationed | FCM high-priority data messages, much more dependable | Pings can be close to instant. Adds a Google Play services and Firebase dependency |
| **Nearby link** | Bonjour, peer-to-peer Wi-Fi (AWDL) and Bluetooth L2CAP | Android's NsdManager (Bonjour-compatible) on a shared network, and Bluetooth LE L2CAP channels (Android 10+). No AWDL | Between an iPhone and an Android phone with no shared Wi-Fi, the link uses Bluetooth only |
| **Places** | `CLVisit` plus 20 regions | Geofencing (100 fences), but no visits API | Visits are approximated from activity recognition (still or moving) plus a location fix. "Allow all the time" is a separate prompt |
| **Battery cost** | `task_info` energy counters | `SystemHealthManager.takeMyUidSnapshot()` power estimates and CPU time | A comparable `EnergyReport` |
| **Installing** | Development builds on registered devices | Sideloaded APK over adb. Android 13+ "restricted settings" block accessibility and notification access for sideloaded apps until allowed. Google's developer verification for sideloading is rolling out in 2026–27 (adb installs are exempt) | Install over adb |

## 3. Architecture decisions

1. **Share ThymeKit rather than rewrite it.** The policy rules are where a Kotlin port would drift from iOS: rulesets,
   temporary changes reverting field by field, custom categories, grants, breaks and self-approval. ThymeKit imports
   only Foundation, plus CryptoKit in 4 files, so porting it is realistic:
   - Swap CryptoKit for swift-crypto, which has the same API.
   - Replace lzfse in `LinkSession`, since Apple's Compression framework doesn't exist on Android. Either bundle the
     open-source lzfse library or add zlib with a version check in the hello.
   - Check `flock`/`fsync` in `JSONLinesFile` on Android's C library.
   - Expose a narrow JSON-in, JSON-out layer to Kotlin through swift-java: the planner, reconstruction, `RuleEngine`,
     `HealthEvaluator`, `AppDetails` and `LinkSession`.
   - **Fallback:** a Kotlin Multiplatform port, using the Swift tests' cases as shared fixtures.
2. **Keep CloudKit.** iOS phones and history stay as they are.
   - Android uses CloudKit Web Services against the same container and environment as the development builds, with an
     API token from CloudKit Console.
   - Records are already `<Type>.<uuid>` JSON payloads, so the Android client is a thin REST layer.
   - Pushes to Android go through a family `PushRelay` record (FCM key, scoped like the `IssueTracker` token). Kid
     phones, iOS ones included, send each alert to Android parents' FCM tokens as well as saving it to CloudKit.
   - **Fallback:** if Web Services can't read and write a share participant's `Family` zone, move every phone to
     Firebase. That's much larger: iOS sync gets rewritten.
3. **ScreenThyme is the Device Owner on Android kid phones.** That gives suspension, uninstall blocking and
   restrictions, and lets setup grant Usage access with `adb shell appops`. Accessibility-only mode is the weaker
   fallback, for example if Family Link refuses to coexist with a Device Owner.

## 4. Kid phone

- **Setup (a parent, at a computer):**
  1. Factory reset, or remove the phone's accounts.
  2. `adb install`, then `dpm set-device-owner`, then grant Usage access with appops.
  3. Re-add the Google account (see spike 1).
  4. Sign in to the kid's Apple Account, then join the family.

  This replaces §16's routine of emptying Apple's settings.
- **Capture:**
  - A foreground service starts at boot. While the screen is on it reads events every 5–10 s, journals sessions (same
    JSONL and locking) and uploads every 60 s and at screen off. These are `UsageSample`s with exact start and end.
  - While the phone is asleep, WorkManager sends heartbeats and fetches the policy and rules every 15 min.
  - Pickups come from unlock and screen-on events.
  - Notifications per app come from a notification listener that counts packages only and never reads content.
- **New apps:** an "app installed" broadcast creates the `TrackedItem` (name, icon, category) and raises the new-app
  alert at once.
- **Enforcement:**
  - The same `EnforcementPlanner`. A new Android Enforcer turns the plan into sets of apps to suspend and unsuspend,
    with no caps.
  - Downtime suspends everything except Always Allowed and essentials (the dialer, launcher, ScreenThyme and emergency
    apps; Settings to be decided).
  - Limits are counted from our own exact sessions, so they end within seconds, not up to a minute late.
  - There are no `dt.`/`lim.` activities. Exact alarms handle window edges, the end of one more minute and the end of a
    break.
  - Blocked apps are hidden.
- **Web:** Chrome reads managed settings from a Device Owner (URL blocklist or allowlist, SafeSearch, Incognito off).
  Other browsers are Blocked by default. Website time limits aren't offered.
- **Content & Privacy (§15.1):**
  - App Store: install and uninstall restrictions, with Play's content ratings left to Family Link.
  - Date and time: automatic time required.
  - Accounts and passcode: account changes disallowed.
  - Cellular: mobile network settings locked.
  - Siri, Game Center, Apple Music and Books have no equivalent and are hidden for Android kids.
  - New ones worth adding: no safe boot, no factory reset, no new users or guest, no Private Space, no developer
    options. USB debugging has to be switched on around each install.
- **Block page and more time:** spike which works better:
  - the suspension dialog's link opening ScreenThyme's Ask for more time, or
  - our own activity drawn over a limited app the moment it comes to the front (needs "Display over other apps").

  One more minute unsuspends that one app for N minutes and sets an exact alarm to suspend it again.
- **Health:** a new Android set of switches: Usage access, Device Owner status, notification listener,
  battery-optimisation exemption, background restriction, standby bucket, Data Saver, Battery Saver, notification
  permission, location ("all the time", precise), Bluetooth and Nearby devices, Wi-Fi.
- **Parent controls:** locked and unlocked over the nearby link, the same as iOS's `ParentUnlock`.

## 5. Parent phone

- Compose screens for the same four tabs, with help text from the existing `ScreenHelp`.
- A local mirror as JSON files with the same snapshot versioning. Timelines and the calendar are drawn from ThymeKit's
  reconstruction.
- Alerts arrive as FCM notifications, and requests are answered in place. Zone changes are polled every 30 s while the
  app is open, and by WorkManager in the background.
- For Android kids, scan, matching, "Not installed" and website limits are hidden, and a Chrome filter list replaces
  Apple's web filter.
- Nearby: dials over Bonjour and Bluetooth L2CAP, and unlocks parent controls.
- Places map: MapLibre (no Google key needed) or the Google Maps SDK.

## 6. Changes to ThymeKit and the iOS app

- `Kid.platform`. `DevicePermission` and `Heartbeat` gain the Android switch set.
- A flag for exact `UsageSample`s, so `CheckIns` keeps them where they are. For Android kids the in-use strip comes
  from screen sessions, not fires.
- Policy targets for Android kids are plain package items, not scanned items, and the editors accept them.
- An Android table in `BuiltInApps` (dialer and call screen, launcher, System UI, permission controller), and a
  mapping from Android categories to custom categories.
- iOS kid phones send FCM to Android parents: one extra POST in the monitor extension, with the access token minted by
  the app.
- `Tools/BugPush`: an FCM path beside APNs.

## 7. Order of work

0. **Spikes** on a spare Android phone (a Pixel, ideally also a Samsung):
   1. Can a Family Link–supervised child account and our Device Owner coexist? If not, the choice is a teen's
      unsupervised account, no Google account, or accessibility-only.
   2. Suspension on current Android: what the dialog and its link do, versus our own screen over the app.
   3. Usage events: latency from a foreground service, how long Android keeps them, behaviour across a reboot and on
      Samsung.
   4. CloudKit Web Services as a share participant: the `Family` zone, how long the sign-in token lasts, rate limits.
   5. ThymeKit on Swift's Android SDK: it builds, its tests pass on an emulator, APK size.
   6. An iPhone and an Android phone talking over Bonjour and L2CAP with the current link protocol.
1. **Android kid to iPhone parents:** capture, upload, heartbeats and alerts. iPhone parents see an exact timeline.
   This is the most value for the least risk.
2. **Enforcement** on the Android kid's phone.
3. **Kid screens:** Ask for more time, one more minute, self-approval, bug reports.
4. **The Android parent app.**
5. **Nearby link, places and battery cost.**
6. **Tooling:**
   - `thyme-inspect` on files pulled with `adb exec-out run-as`.
   - Test mode and the replay tool.
   - Screen map captured from an emulator.
   - New sections in PLAN.md and CLAUDE.md.

## 8. Main risks

| Risk | Fallback |
|---|---|
| Family Link refuses to coexist with a Device Owner | A choice between Google's supervision and ours, or accessibility-only enforcement |
| CloudKit Web Services doesn't work for a share participant | Move every phone to another backend (Firebase) |
| Swift on Android isn't mature enough | A Kotlin Multiplatform port of ThymeCore |
| Manufacturers' battery killers stop the capture service | Battery-optimisation exemption, health alerts, WorkManager catch-up from Android's retained events |
| Google's sideloading verification changes how we install | adb installs, or the free hobbyist verification |
| No website time | Permanent unless reading Chrome's address bar proves reliable enough |
