# Bug closed pushes

When an issue in the family's bug repository is closed, the phone that filed it gets a notification, even when
ScreenThyme isn't running (PLAN.md §18): "A problem you reported is fixed" when it's closed as completed, "A problem
you reported was closed … without a fix" for any other reason (not planned, a duplicate). GitHub sends it straight to
Apple's push service; there's no server.

- Each phone saves its APNs device token as `phones/<phone id>.json` in the bug repository, again whenever it
  changes (`BugReportQueue.pushToken`, `GitHubIssues.save`).
- Each issue a phone files ends with a hidden `<!-- screenthyme-fixed {...} -->` marker naming the phone and the
  words to show either way (`GitHubIssues.fixMarker`). Issues filed by hand have none and push nothing; issues filed
  before closings without a fix were told carry only the fixed words, and the script makes the other from them.
- `notify-fixed.yml` runs `notify-fixed.mjs` on `issues: closed`. An issue reopened and closed again sends again,
  replacing the earlier notification.

## Setting it up (once)

1. **An APNs key.** In the Apple Developer account, Certificates, Identifiers & Profiles › Keys › +, tick Apple Push
   Notifications service (APNs), and download the `.p8` (it can be downloaded only once). Note its Key ID.
2. **The workflow,** in the bug repository: copy `notify-fixed.yml` to `.github/workflows/notify-fixed.yml` and
   `notify-fixed.mjs` to `.github/scripts/notify-fixed.mjs`.
3. **Three secrets** in the bug repository (Settings › Secrets and variables › Actions, or `gh secret set`):
   `APNS_KEY` (the `.p8` file's contents), `APNS_KEY_ID` and `APNS_TEAM_ID` (`ZVU48K8YCD`).

```bash
gh secret set APNS_KEY --repo <owner>/<bug repo> < AuthKey_XXXXXXXXXX.p8
```

The phones' token also needs Contents write on the bug repository, which bug reports already need.

## Testing

```bash
node --test Tools/BugPush/*.test.mjs
```

On a phone: send a report, wait for `phones/` to appear in the bug repository, close the issue as completed, and see
the workflow's run under Actions. Every build is a development build, so the push goes to APNs' sandbox (the phone's
`environment`).
