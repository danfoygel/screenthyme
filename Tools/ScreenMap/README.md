# Screen map

Screen flow diagrams of the kid and parent modes: every screen, sheet and Apple prompt, the tap that leads to each,
and a screenshot of each screen on hover. Published at https://danfoygel.github.io/screenthyme/ (the `gh-pages`
branch).

```bash
Tools/ScreenMap/capture.sh "iPhone Air" /tmp/screen-map   # screenshots, from a fresh install (about 4½ minutes)
python3 Tools/ScreenMap/build.py /tmp/screen-map           # index.html
open /tmp/screen-map/index.html
Tools/ScreenMap/publish.sh /tmp/screen-map                 # push to gh-pages
```

- `build.py` holds the graph: boxes, their places and the edges between them, kept by hand. Change it with the app's
  navigation (`NavigationLink`, `.sheet`, `.popover`, tabs, Apple's pickers and prompts). A box's screenshot is
  `shots/<k|p>-<key>.jpg`; a box without one shows its `WHY` note.
- `capture.sh` runs the `ScreenTour` UI test (`ScreenTour/ScreenTour.swift`) in a Simulator on iOS 26.4 or later:
  single-phone test mode, the Replay tool's synthetic school day for a test kid, then each screen it can reach. Add a
  screen to the tour when you add a box.
- The tour is a few tests, run in name order in one `xcodebuild` run: `test1Setup` (Welcome, the parent role, Leo's
  day and a named place), then one per part of the app (`test2Kids`, `test3ScreenTime`, `test4Rules`,
  `test5Settings`, `test6Kid`, `test7AskSheet`). Name tests after the site dir to capture only those, after
  `test1Setup`; the site's other screenshots stay:

  ```bash
  Tools/ScreenMap/capture.sh "iPhone Air" /tmp/screen-map test3ScreenTime   # about 1½ minutes
  ```

- It prints `TOUR saved <name>` for each screenshot, each test's time, and `TOUR missing <label>` for a button it
  couldn't find, which costs a scroll to the list's end and back. The helpers wait for what they need, never a fixed
  time, except a short settle before each screenshot: keep it that way when adding screens. The app runs with
  `-screenTour`, which turns its animations off, so each tap's wait for the app to settle is short.
- Some boxes can't have a Simulator screenshot: the block page, Apple's Screen Time prompt, anything that needs limits
  in force, data access, an iCloud family or a real camera. Their `WHY` notes say so.
- **Only test data.** The site is public: never capture from a real family's phones.
