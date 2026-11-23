"""The screen map: ScreenThyme's kid and parent screen flows, drawn as SVG, with a screenshot of each screen on hover.

    python3 Tools/ScreenMap/build.py <site dir>

writes <site dir>/index.html from page.html. Screenshots are <site dir>/shots/<k|p>-<key>.jpg (capture.sh); a box
without one shows its WHY note instead. The graph below is kept by hand: change it with the app's navigation.
"""
import datetime, html, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SITE = sys.argv[1]
SHOTS = os.path.join(SITE, "shots")   # <prefix>-<key>.jpg
WHY = {}   # (prefix, key) -> why a box has no screenshot

W, H, P, R = 184, 60, 354, 78   # node width/height, column pitch, row pitch
ML, MT = 28, 64

def esc(s): return html.escape(s, quote=True)

class Diagram:
    def __init__(self, prefix):
        self.p = prefix
        self.nodes = {}
        self.edges = []
        self.frames = []

    def node(self, key, col, row, title, typ="", note="", kind="screen", h=H, tag=None, rows=None):
        x = ML + col * P
        if rows:  # a tall node spanning rows[0]..rows[1]
            top = MT + rows[0] * R
            h = (rows[1] - rows[0]) * R + H
        else:
            top = MT + row * R
        if kind == "mode":
            h = 42
            top = MT + row * R + (H - h) / 2
        self.nodes[key] = dict(key=key, x=x, y=top, w=W, h=h, title=title, typ=typ, note=note, kind=kind, tag=tag)

    def edge(self, a, b, label="", kind="push", sp=0, dp=0, at="dst", bend=None, pts=None, lpos=None):
        self.edges.append(dict(a=a, b=b, label=label, kind=kind, sp=sp, dp=dp, at=at, bend=bend, pts=pts, lpos=lpos))

    def frame(self, keys, label):
        self.frames.append((keys, label))

    # ---- geometry
    def cy(self, k): n = self.nodes[k]; return n["y"] + n["h"] / 2

    def route(self, e):
        a, b = self.nodes[e["a"]], self.nodes[e["b"]]
        if e["pts"]:
            return e["pts"]
        x1, y1 = a["x"] + a["w"], self.cy(e["a"]) + e["sp"]
        x2, y2 = b["x"], self.cy(e["b"]) + e["dp"]
        if abs(y1 - y2) < 0.5:
            return [(x1, y1), (x2, y2)]
        bend = e["bend"] or "src"
        tx = x1 + 24 if bend == "src" else x2 - 24
        return [(x1, y1), (tx, y1), (tx, y2), (x2, y2)]

    @staticmethod
    def path(pts, r=9):
        d = [f"M{pts[0][0]:.1f},{pts[0][1]:.1f}"]
        for i in range(1, len(pts) - 1):
            (px, py), (cx, cy), (nx, ny) = pts[i - 1], pts[i], pts[i + 1]
            def toward(ax, ay, bx, by, dist):
                L = ((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5 or 1
                dd = min(dist, L / 2)
                return ax + (bx - ax) / L * dd, ay + (by - ay) / L * dd
            s = toward(cx, cy, px, py, r)
            t = toward(cx, cy, nx, ny, r)
            d.append(f"L{s[0]:.1f},{s[1]:.1f} Q{cx:.1f},{cy:.1f} {t[0]:.1f},{t[1]:.1f}")
        d.append(f"L{pts[-1][0]:.1f},{pts[-1][1]:.1f}")
        return " ".join(d)

    def render(self, aria):
        maxx = max(n["x"] + n["w"] for n in self.nodes.values()) + ML
        maxy = max(n["y"] + n["h"] for n in self.nodes.values()) + 36
        out = [f'<svg class="flow" viewBox="0 0 {maxx:.0f} {maxy:.0f}" width="{maxx:.0f}" height="{maxy:.0f}" '
               f'role="img" aria-label="{esc(aria)}" xmlns="http://www.w3.org/2000/svg">']
        out.append("<defs>")
        for k in ("push", "sheet", "apple", "mode", "outside"):
            out.append(f'<marker id="{self.p}-{k}" class="m-{k}" viewBox="0 0 10 10" refX="9" refY="5" '
                       f'markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z"/></marker>')
        out.append("</defs>")
        # column headers
        cols = sorted({n["x"] for n in self.nodes.values()})
        # frames
        for keys, label in self.frames:
            ns = [self.nodes[k] for k in keys]
            fx = min(n["x"] for n in ns) - 14
            fy = min(n["y"] for n in ns) - 34
            fw = max(n["x"] + n["w"] for n in ns) + 14 - fx
            fh = max(n["y"] + n["h"] for n in ns) + 14 - fy
            out.append(f'<rect class="frame" x="{fx}" y="{fy}" width="{fw}" height="{fh}" rx="14"/>')
            out.append(f'<text class="framelabel" x="{fx + 14}" y="{fy + 21}">{esc(label)}</text>')
        # edges under nodes
        for e in self.edges:
            pts = self.route(e)
            out.append(f'<path class="edge e-{e["kind"]}" d="{self.path(pts)}" marker-end="url(#{self.p}-{e["kind"]})"/>')
        for n in self.nodes.values():
            out.append(self.render_node(n))
        # labels over everything
        for e in self.edges:
            if not e["label"]:
                continue
            pts = self.route(e)
            lines = e["label"].split("\n")
            if e["lpos"]:
                lx, ly, anchor = e["lpos"]
            elif e["at"] == "src":
                lx, ly, anchor = pts[0][0] + 10, pts[0][1] - 6, "start"
            else:
                lx, ly, anchor = pts[-1][0] - 12, pts[-1][1] - 6, "end"
            for i, line in enumerate(reversed(lines)):
                out.append(f'<text class="elabel l-{e["kind"]}" x="{lx:.1f}" y="{ly - i * 13:.1f}" text-anchor="{anchor}">{esc(line)}</text>')
        out.append("</svg>")
        return "\n".join(out)

    def render_node(self, n):
        x, y, w, h, kind = n["x"], n["y"], n["w"], n["h"], n["kind"]
        shot = f"shots/{self.p}-{n['key']}.jpg"
        attrs = f' data-title="{esc(n["title"].strip(" ›"))}"'
        if SHOTS and os.path.exists(os.path.join(SHOTS, os.path.basename(shot))):
            attrs += f' data-shot="{shot}" tabindex="0"'
        elif (self.p, n["key"]) in WHY:
            attrs += f' data-why="{esc(WHY[(self.p, n["key"])])}" tabindex="0"'
        g = [f'<g class="node n-{kind}"{attrs}>']
        if kind == "mode":
            g.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{h / 2}"/>')
            g.append(f'<text class="mtitle" x="{x + w / 2}" y="{y + h / 2 + 4.5}" text-anchor="middle">{esc(n["title"])}</text>')
            g.append("</g>")
            return "".join(g)
        g.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="8"/>')
        tag = n["tag"] or {"sheet": "SHEET", "apple": "APPLE", "outside": "OUTSIDE APP", "popover": "POPOVER"}.get(kind)
        if tag:
            g.append(f'<text class="ntag" x="{x + w - 10}" y="{y + 15}" text-anchor="end">{esc(tag)}</text>')
        ty = y + 21
        g.append(f'<text class="ntitle" x="{x + 12}" y="{ty}">{esc(n["title"])}</text>')
        if n["typ"]:
            g.append(f'<text class="ntype" x="{x + 12}" y="{ty + 16}">{esc(n["typ"])}</text>')
        if n["note"]:
            for i, line in enumerate(n["note"].split("\n")):
                g.append(f'<text class="nnote" x="{x + 12}" y="{ty + 31 + i * 13}">{esc(line)}</text>')
        g.append("</g>")
        return "".join(g)


# ======================= KID MODE =======================
k = Diagram("k")
k.node("shield", 0, 3, "Block page", "ThymeShield", "over a blocked app;\nOK closes it", kind="outside", h=72)
k.node("welcome", 0, 7, "Welcome", "RoleSelectionView", "first launch only", kind="root", tag="START")
k.node("home", 1, 7, "ScreenThyme", "KidHomeView", "the kid's home", kind="root", tag="HOME")

k.node("dtItems", 2, 0, "‹Downtime name›", "SelectedItemsView", "Downtime for some apps on")
k.node("allowed", 2, 1, "Always Allowed", "SelectedItemsView", "when the list isn't empty")
k.node("blocked", 2, 2, "Blocked", "SelectedItemsView", "when the list isn't empty")
k.node("ask", 2, 3, "Ask for more time", "AskForTimeView", "when something is blocked", kind="sheet")
k.node("auth", 2, 4, "Screen Time access", "Apple's approval prompt", "until data access is on", kind="apple")
k.node("scan", 2, 5, "Apple's app picker", "FamilyActivityPicker", "Select All Apps & Categories", kind="apple")
k.node("self", 2, 6, "Apple's app picker", "FamilyActivityPicker", "Select ScreenThyme only", kind="apple")
k.node("camera", 2, 7, "Match with camera", "CameraPairingView", "a parent's phone reads codes")
k.node("pairing", 2, 8, "Match by screenshot", "TokenPairingView", "after data access")
k.node("report", 2, 9.5, "Report a problem", "BugReportView", "also the bug, top right of\nevery screen (a sheet)", h=72)
k.node("debug", 2, 11.75, "Debug", "KidDebugView")
k.node("apps", 2, 13, "Apps", "KidAppsView", "used in the last 30 days")
k.node("timeline", 2, 14.25, "Timeline", "KidTimelineView", "the day as parents see it")
k.node("categories", 2, 15.1, "Categories", "CategoryTimeView", "the day by Apple's category")
k.node("test", 2, 16, "Test mode", "TestModeView", "only with test mode on")

k.node("appDetails", 3, 1, "‹app›", "AppDetailsView", "groups, limits, use, requests")
k.node("choose", 3, 3, "Apple's app picker", "FamilyActivityPicker", "Choose the app", kind="apple")
k.node("selfApprove", 3, 4, "Approve it yourself", "SelfApproveView", "a waiting request, no parent\nto answer; alerts parents", kind="sheet", h=72)
k.node("photos", 3, 8, "Photos picker", "PhotosPicker", "screenshots", kind="apple")
k.node("perms", 3, 9.25, "Permissions", "PermissionsView", "this phone's answers")
k.node("day", 3, 10.25, "‹date›", "UsageCalendar", "the day as a calendar")
k.node("s4", 3, 11.25, "Data access (S4)", "DataAccessView")
k.node("apple", 3, 12.25, "Apple's numbers", "AppleReportView", "ThymeReport extension")
k.node("raw", 3, 13.25, "Raw usage", "RawUsageView")
k.node("places", 3, 14.25, "Places", "PlacesTestView", "the location test")
k.node("share", 3, 15.25, "Share sheet", "ShareLink", "after Export day as trace", kind="apple")
k.node("replay", 3, 16.5, "Replay", "ReplayView")
k.node("toParent", 3, 17.5, "Parent mode  ›", kind="mode")

k.node("popover", 4, 10.25, "Block details", "UsageCalendar popover", kind="popover")
k.node("auth2", 4, 11.25, "Screen Time access", "Apple's approval prompt", kind="apple")

k.edge("welcome", "home", "Set up as kid's phone", kind="mode")
k.edge("shield", "ask", "Ask for more time\n(iOS 26.5+ opens the app)", kind="outside", sp=-30 + 0, dp=-11, at="src",
       pts=None)
k.edge("home", "dtItems", "‹Downtime› row")
k.edge("home", "allowed", "Always Allowed")
k.edge("home", "blocked", "Blocked")
k.edge("home", "ask", "Ask for more time", kind="sheet", dp=11)
k.edge("home", "auth", "Allow … access", kind="apple")
k.edge("home", "scan", "Scan apps", kind="apple")
k.edge("home", "self", "Choose ScreenThyme", kind="apple")
k.edge("home", "camera", "Match with a\nparent's camera")
k.edge("home", "pairing", "Match apps by\nscreenshot")
k.edge("home", "report", "Report a problem")
k.edge("home", "debug", "Debug")
k.edge("home", "apps", "Apps")
k.edge("home", "timeline", "Day timeline")
k.edge("home", "categories", "Time by category")
k.edge("apps", "appDetails", "an app", bend="dst")
for src in ("dtItems", "allowed", "blocked"):
    k.edge(src, "appDetails", "an app" if src == "allowed" else "", dp=k.cy(src) - k.cy("appDetails"))
k.edge("home", "test", "Test mode")
k.edge("ask", "choose", "Choose the app", kind="apple")
k.edge("ask", "selfApprove", "Approve it myself…", kind="sheet")
k.edge("pairing", "photos", "Import screenshots", kind="apple")
k.edge("report", "photos", "Add screenshots", kind="apple")
k.edge("debug", "perms", "Permissions")
k.edge("debug", "day", "Day timeline")
k.edge("debug", "s4", "Data access test")
k.edge("debug", "apple", "Apple's report")
k.edge("debug", "raw", "Raw usage")
k.edge("debug", "places", "Places (location test)")
k.edge("debug", "share", "Share ‹file›", kind="apple")
k.edge("test", "replay", "Replay tool")
k.edge("test", "toParent", "Role: Parent", kind="mode")
k.edge("day", "popover", "tap a block", kind="sheet")
k.edge("s4", "auth2", "Request\nauthorization again", kind="apple")
# Debug's own link to Match by screenshot: straight up the column, labelled in the gap under Report a problem
dx = k.nodes["debug"]["x"] + 30
rp = k.nodes["report"]
k.edge("debug", "pairing", "Match scanned apps\nby screenshot", pts=[(dx, k.nodes["debug"]["y"]), (dx, k.nodes["pairing"]["y"] + H)],
       lpos=(dx + 10, (rp["y"] + rp["h"] + k.nodes["debug"]["y"]) / 2 + 10, "start"))

# the block page's edge: a straight line at the ask sheet's upper port
sh, ask = k.nodes["shield"], k.nodes["ask"]
yy = k.cy("ask") - 11
k.edges[1]["pts"] = [(sh["x"] + W, yy), (ask["x"], yy)]

# ======================= PARENT MODE =======================
p = Diagram("p")
p.node("welcome", 0, 2, "Welcome", "RoleSelectionView", "first launch only", kind="root", tag="START")
p.node("kids", 1, 2, "Kids", "ParentHomeView", "a card for each kid", kind="root", tag="TAB 1")
p.node("alerts", 1, 3.25, "Alerts", "AlertsView", "requests: Approve, Change, Decline", kind="root", tag="TAB 2")
p.node("places", 1, 4.5, "Places", "PlacesView", "map of visits; places, spots", kind="root", tag="TAB 3")
p.node("settings", 1, 6, "Settings", "ParentSettingsView", "family, you, kids, nearby", kind="root", tag="TAB 4")
p.frame(["kids", "alerts", "places", "settings"], "Tab bar")
p.node("changeTime", 2, 3.25, "Change the time", "ChangeTimeSheet", "Cancel / Approve", kind="sheet")
p.node("placeEditor", 2, 4.5, "Name this place", "PlaceEditor", "name, fence, visits; Remove", kind="sheet")

p.node("kidDay", 2, 2, "‹kid›", "KidDayView", "one day: totals, apps, sites")
p.node("sharing", 2, 7, "Share the family", "UICloudSharingController", "family owner only", kind="apple")
p.node("notif", 2, 8, "Notifications prompt", "Apple's permission alert", kind="apple")
p.node("test", 2, 9, "Test mode", "TestModeView", "only with test mode on")
p.node("issues", 2, 10, "Bug reports", "IssueTrackerView", "GitHub repository and token")
p.node("report", 2, 11, "Report a problem", "BugReportView", "the bug, top right of\nevery screen", kind="sheet", h=72)
p.node("perms", 2, 12.25, "Permissions", "PermissionsView", "this phone's, each kid's")

p.node("timeline", 3, 0, "Timeline", "KidTimelineView", "zoom, Options menu")
p.node("categories", 3, 1, "Categories", "CategoryTimeView", "the day by Apple's category")
p.node("history", 3, 2, "Change history", "PolicyHistoryView", "saves, changes back, answers")
p.node("locationDay", 3, 3.1, "‹place›", "LocationDayView", "apps used there, times there")
p.node("scanner", 3, 4.25, "Match ‹kid›'s apps", "PairingScannerView", "camera reads the kid's codes")
p.node("kidSettings", 3, 6, "‹kid›", "KidSettingsView", "rules and health")
p.node("rawLocation", 3, 7.5, "Raw location", "RawLocationView", "visits, fences; also a day's Where")
p.node("replay", 3, 9, "Replay", "ReplayView")
p.node("toKid", 3, 10, "Kid mode  ›", kind="mode")

p.node("popover", 4, 0, "Block details", "UsageCalendar popover", kind="popover")
p.node("policy", 4, 3.5, "Screen Time", "PolicyView", "edits a draft; Save asks how long")
p.node("apps", 4, 5, "‹kid›'s apps", "TrackedItemsView", "every app and site seen")
p.node("raw", 4, 6, "Raw usage", "RawUsageView")
p.node("matches", 4, 7, "App matches", "TokenMatchesView", "also Website, Category matches")
p.node("battery", 4, 8, "Battery use", "EnergyHistoryView")
p.node("rule", 4, 9, "‹rule name›", "RuleEditor", "Cancel / Save", kind="sheet")

p.node("downtime", 5, 1, "Downtime", "DowntimeEditor", "Cancel / Done", kind="sheet")
p.node("limit", 5, 2, "App Limit", "LimitEditor", "Cancel / Done", kind="sheet")
p.node("group", 5, 3, "Group", "GroupEditor", "Cancel / Done", kind="sheet")
p.node("allowed", 5, 4, "Always Allowed", "SelectedItemsView", "read-only list, Edit;\nUncounted is the same,\nchoosing from Always Allowed", h=72)
p.node("blocked", 5, 5, "Blocked", "SelectedItemsView", "read-only list, Edit")
p.node("content", 5, 6, "Content & Privacy", "RestrictionsView")
p.node("save", 5, 7, "Save changes", "SavePolicySheet", "Permanent or Temporary", kind="sheet")
p.node("what", 5, 9, "What", "navigationLink Picker", "daily-limit rules only")

p.node("select", 6, 0, "‹list name›", "ItemSelectionView",
       "Search and tick categories,\napps, websites and groups.\n\nTitled after what it edits:\nDowntime, Limit, the group's\nname, Always Allowed,\nUncounted or Blocked.",
       rows=(1, 5))
p.node("domains", 6, 6, "‹website list›", "DomainListView", "Always allow, Never allow\nor Allowed websites", h=72)
p.node("appDetails", 6, 7.5, "‹app›", "AppDetailsView", "groups, limits, use, requests;\nEdit Screen Time › PolicyView", h=72)

p.edge("welcome", "kids", "Set up as parent", kind="mode")
p.edge("kids", "kidDay", "tap a kid's card")
p.edge("settings", "sharing", "Invite parent or kid", kind="apple")
p.edge("settings", "notif", "Allow notifications", kind="apple")
p.edge("settings", "test", "Test mode")
p.edge("settings", "issues", "Bug reports")
p.edge("settings", "perms", "Permissions")
p.edge("settings", "kidSettings", "Kids › ‹kid›", sp=12, dp=12, lpos=None)
p.edge("kidDay", "timeline", "Day timeline")
p.edge("kidDay", "categories", "Time by category")
p.edge("kidDay", "history", "Change history")
p.edge("kidDay", "scanner", "Match ‹n› new apps\nwith camera")
p.edge("kidDay", "kidSettings", "Rules and health", dp=-12)
p.edge("kidDay", "locationDay", "Where › a place")
p.edge("alerts", "changeTime", "Change", kind="sheet")
p.edge("places", "placeEditor", "a spot or place", kind="sheet")
p.edge("test", "replay", "Replay tool")
p.edge("test", "toKid", "Role: Kid", kind="mode")
p.edge("timeline", "popover", "tap a block", kind="sheet")
p.edge("kidSettings", "policy", "Screen Time: …")
p.edge("kidSettings", "apps", "Apps seen")
p.edge("kidSettings", "raw", "Raw usage")
p.edge("kidSettings", "matches", "‹Kind› matches")
p.edge("kidSettings", "battery", "Earlier days")
p.edge("kidSettings", "rule", "a rule, or Add rule ▾", kind="sheet")
p.edge("policy", "downtime", "a window, Add Downtime", kind="sheet")
p.edge("policy", "limit", "a limit, Add limit", kind="sheet")
p.edge("policy", "group", "a group, Add group", kind="sheet")
p.edge("policy", "allowed", "Always Allowed,\nUncounted")
p.edge("policy", "blocked", "Blocked")
p.edge("policy", "content", "Content & Privacy")
p.edge("policy", "save", "Save", kind="sheet")
p.edge("rule", "what", "What")
for src, lab in (("downtime", "Included · Some apps"), ("limit", "Included · not all apps"), ("group", "Included"),
                 ("allowed", "Edit"), ("blocked", "Edit")):
    p.edge(src, "select", lab, dp=p.cy(src) - p.cy("select"))
p.edge("content", "domains", "a website list", dp=p.cy("content") - p.cy("domains"))
for src, lab in (("allowed", ""), ("blocked", "an app"), ("apps", "an app or site")):
    p.edge(src, "appDetails", lab, bend="dst", dp=-14 if src == "apps" else 0)
# The day's Apps and Websites rows: up over the columns, then down the right edge into the details' side
kd, ad = p.nodes["kidDay"], p.nodes["appDetails"]
top, rx = MT - 30, ad["x"] + W + 24
p.edge("kidDay", "appDetails", "an app or site in the day's lists",
       pts=[(kd["x"] + 40, kd["y"]), (kd["x"] + 40, top), (rx, top), (rx, p.cy("appDetails")), (ad["x"] + W, p.cy("appDetails"))],
       lpos=(kd["x"] + 52, top - 6, "start"))
# Rules and health's camera link: straight up the column
sx = p.nodes["kidSettings"]["x"] + 30
p.edge("kidSettings", "scanner", "Match apps\nwith camera",
       pts=[(sx, p.nodes["kidSettings"]["y"]), (sx, p.nodes["scanner"]["y"] + H)],
       lpos=(sx + 10, (p.nodes["kidSettings"]["y"] + p.nodes["scanner"]["y"] + H) / 2 + 6, "start"))
# Rules and health's Raw location: straight down the column
ks, rl = p.nodes["kidSettings"], p.nodes["rawLocation"]
p.edge("kidSettings", "rawLocation", "Raw location", pts=[(sx, ks["y"] + ks["h"]), (sx, rl["y"])],
       lpos=(sx + 10, (ks["y"] + ks["h"] + rl["y"]) / 2 + 6, "start"))
# Screen Time's own link back to Change history: up from its top, left into history's right side
pol, his = p.nodes["policy"], p.nodes["history"]
bx = pol["x"] + 30
hy = p.cy("history")
p.edge("policy", "history", "Change history",
       pts=[(bx, pol["y"]), (bx, hy), (his["x"] + W, hy)], lpos=(his["x"] + W + 14, hy - 6, "start"))

# Boxes with no Simulator screenshot, and why (shown on hover instead)
LIMITS = "Shows only while a parent's limits are in force on the kid's phone, which the Simulator can't do."
WHY.update({
    ("p", "changeTime"): "Opens from a kid's request for more time, which test mode doesn't make.",
    ("k", "shield"): "Apple draws the block page over a blocked app, on a kid's phone with limits in force. The Simulator can't enforce limits.",
    ("k", "dtItems"): LIMITS, ("k", "allowed"): LIMITS, ("k", "blocked"): LIMITS,
    ("k", "auth"): "Apple's Screen Time approval prompt. It needs a real phone and a parent's approval.",
    ("k", "auth2"): "Apple's Screen Time approval prompt. It needs a real phone and a parent's approval.",
    ("k", "scan"): "The same Apple picker as Choose the app, headed Select All Apps & Categories. Its button appears only after data access, which the Simulator can't grant.",
    ("k", "self"): "The same Apple picker as Choose the app, headed Select ScreenThyme only. Its button appears only after data access, which the Simulator can't grant.",
    ("k", "photos"): "Apple's photo picker, for screenshots to match apps by or to add to a bug report.",
    ("k", "popover"): "The kid's Debug timeline is empty in the Simulator (no Screen Time data), so there's no block to tap.",
    ("k", "apple"): "Apple's report extension draws nothing in the Simulator.",
    ("k", "camera"): "Its link appears only after data access, which the Simulator can't grant.",
    ("k", "appDetails"): "The kid's Apps list is empty in the Simulator (no Screen Time data), so there's no app to open. The parent's ‹app› box shows the same screen.",
    ("p", "scanner"): "Its links appear once a kid's phone has scanned its apps, and it needs a real camera.",
    ("p", "sharing"): "Apple's iCloud sharing sheet. It needs an iCloud family, which the Simulator doesn't have.",
    ("p", "matches"): "Appears once apps have been scanned and matched on the kid's phone.",
    ("p", "battery"): "Appears once the kid's phone has sent its battery numbers.",
})

kid_svg = k.render("Kid mode screen flow: Welcome leads to the ScreenThyme home screen, which links to the kid's Screen Time lists, "
                   "Ask for more time, Apple's pickers, matching by camera or screenshot, Report a problem, Debug, the kid's apps and their details, the day timeline, time by category, and Test mode; the block page outside the app also opens Ask for more time.")
parent_svg = p.render("Parent mode screen flow: Welcome leads to a tab bar with Kids, Alerts, Places and Settings; Places names spots on its map; "
                      "a kid's day leads to the timeline, time by category, change history, a place's use, camera matching, an app's details and rules and health, "
                      "which leads to the Screen Time editor and its sheets and item picker, and raw location.")

commit = subprocess.run(["git", "-C", HERE, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
source = f"Traced from the SwiftUI sources at {commit} · {datetime.date.today():%-d %b %Y}"
page = open(os.path.join(HERE, "page.html")).read()
page = page.replace("{{KID}}", kid_svg).replace("{{PARENT}}", parent_svg).replace("{{SOURCE}}", source)
open(os.path.join(SITE, "index.html"), "w").write(page)
print(f"wrote {os.path.join(SITE, 'index.html')}: {len(os.listdir(SHOTS)) if os.path.isdir(SHOTS) else 0} screenshots")
