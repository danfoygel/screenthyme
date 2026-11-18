# Screen map

Screen flow diagrams of the kid and parent modes: every screen, sheet and Apple prompt, the tap that leads to each,
and a screenshot of each screen on hover. Published at https://danfoygel.github.io/screenthyme/ (the `gh-pages`
branch).

```bash
Tools/ScreenMap/capture.sh "iPhone Air" /tmp/screen-map   # screenshots, from a fresh install (about 10 minutes)
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
- Some boxes can't have a Simulator screenshot: the block page, Apple's Screen Time prompt, anything that needs limits
  in force, data access, an iCloud family or a real camera. Their `WHY` notes say so.
- **Only test data.** The site is public: never capture from a real family's phones.
