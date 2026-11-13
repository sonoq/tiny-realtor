#!/usr/bin/env python3
"""Tiny Realtor - art-direction mockup D: "Bold tabletop / toy city".

usage: python3 tabletop.py [block_saved.json] [out_dir]

Everything is drawn on ONE low-res pixel grid (300x300 for the window) with a small fixed
palette, no anti-aliasing, then upscaled x2 with nearest-neighbour.
Look: chunky toy pieces on a board - every shape has a 1px ink outline, flat 3-tone
shading (top / lit wall / mid / dark wall), owned pieces are painted in the player colour
and stand on a coloured base plinth with a flag, the office radius is a dashed boundary
tape on the ground, unowned plots inside the radius carry price tags.
"""
import json, math, os, sys, hashlib, heapq
import numpy as np
from PIL import Image, ImageDraw
from shapely.geometry import Polygon, LineString, Point, box as sbox
from shapely.ops import unary_union

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pixfont import BIG, SMALL, draw_text, text_width, bold_width

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "realestate", "data", "block_saved.json")
OUT = sys.argv[2] if len(sys.argv) > 2 else HERE


def hx(s):
    return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5))


def h01(*parts):
    return int(hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:8], 16) / 2 ** 32


# ------------------------------------------------------------------ palette (fixed, small)
INK = hx("#1d1733")
INK2 = hx("#3b3366")
WHITE = hx("#fffaf0")
BOARD_A, BOARD_B = hx("#f7e6c4"), hx("#ecd5a8")
ZONE_A, ZONE_B = hx("#ffdcc0"), hx("#f8c9a6")
ROAD, ROAD_MARK = hx("#4d5488"), hx("#fff3d6")
GRASS, GRASS2 = hx("#7ad152"), hx("#67c045")
DIRT, DIRT2 = hx("#d99b5b"), hx("#bf7f45")
GLASS, GLINT, LIT = hx("#2c3a73"), hx("#9fe3ff"), hx("#ffe68a")
WATER = hx("#5fd0ff")
SCAF = hx("#ff9a3c")

# wall ramps: (lit face, mid face, dark face, deep)
CREAM = [hx(c) for c in ("#fff3d9", "#f2d9a8", "#d6b27b", "#b38c5a")]
BLUEW = [hx(c) for c in ("#e1f0ff", "#bcd6f2", "#93b3dc", "#7290bd")]
PINKW = [hx(c) for c in ("#ffe6dc", "#f7c7b5", "#dea08c", "#bd7f6e")]
RED = [hx(c) for c in ("#ff6262", "#eb3b4f", "#bf2445", "#8e1a3d")]
GOLD = [hx(c) for c in ("#ffd84d", "#f8b62a", "#db8c17", "#a8641a")]
LEAF = [hx(c) for c in ("#8ee060", "#5cc84a", "#3fa23f", "#2f7a35")]
SLATE = [hx(c) for c in ("#7b8ad0", "#5b6aa8", "#46528a", "#363f70")]
SKYC = [hx(c) for c in ("#a9d8ff", "#6cb6f5", "#4a8fd6", "#356fb0")]
TEALC = [hx(c) for c in ("#7fe8d6", "#3cc2b0", "#2a9a8c", "#1f766c")]
# roof tops: (rim, inner)
R_TEAL = (hx("#9fe8da"), hx("#6dd2c1"))
R_SKY = (hx("#bfe0ff"), hx("#91c4f4"))
R_SAND = (hx("#ffe4b0"), hx("#f7ca86"))
R_LILAC = (hx("#ddd0ff"), hx("#bba8f2"))
R_OWN = (hx("#fff7e6"), hx("#f0dcc0"))
R_GOLD = (hx("#fff1a8"), hx("#ffd84d"))

S = 2.0          # px per metre along the ground axes (2:1 iso)
FLOOR = 4        # px per storey (toy-stubby proportions)


def mixc(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


# ------------------------------------------------------------------ data
def load_block(path):
    B = json.load(open(path))
    th = math.atan2(1.0, 576.5)                 # straighten the grid (OSM residue of ~0.1 deg)
    c, s = math.cos(th), math.sin(th)

    def tr(p):
        x, y = p
        return (round(x * c - y * s), round(x * s + y * c))   # snap to 1 m lattice -> clean 2:1 lines

    plots = []
    for i, p in enumerate(B["plots"]):
        pts = []
        for q in p["poly"]:
            t = tr(q)
            if not pts or pts[-1] != t:
                pts.append(t)
        if len(pts) > 1 and pts[0] == pts[-1]:
            pts.pop()
        poly = Polygon(pts)
        if not poly.is_valid or poly.area < 4:
            poly = poly.buffer(0)
            if poly.geom_type != "Polygon":
                continue
        plots.append(dict(p, idx=i, geom=poly))
    roads = [dict(r, line=[tr(q) for q in r["line"]]) for r in B["roads"]]
    greens = [dict(g, geom=Polygon([tr(q) for q in g["poly"]]).buffer(0)) for g in B["greens"]]
    return B, plots, roads, greens


# ------------------------------------------------------------------ projection
class Proj:
    def __init__(self, ox, oy):
        self.ox, self.oy = ox, oy

    def __call__(self, x, y, z=0.0):
        return (int(math.floor((x + y) * S + self.ox + 0.5)), int(math.floor((x - y) * S / 2 - z + self.oy + 0.5)))

    def inv(self, X, Y):
        a = (X - self.ox) / S
        b = (Y - self.oy) * 2 / S
        return (a + b) / 2, (a - b) / 2


def poly_pts(g):
    return list(g.exterior.coords)[:-1]


def inset(g, d):
    r = g.buffer(-d, join_style=2, mitre_limit=3)
    if r.is_empty:
        return None
    if r.geom_type != "Polygon":
        r = max(r.geoms, key=lambda q: q.area)
    return Polygon([(round(x * 2) / 2, round(y * 2) / 2) for x, y in poly_pts(r)])


# ------------------------------------------------------------------ primitive drawing
def visible_faces(pts, ccw):
    out = []
    n_ = len(pts)
    for k in range(n_):
        a, b = pts[k], pts[(k + 1) % n_]
        dx, dy = b[0] - a[0], b[1] - a[1]
        L = math.hypot(dx, dy)
        if L < 1e-6:
            continue
        n = (dy / L, -dx / L) if ccw else (-dy / L, dx / L)
        if n[0] - n[1] <= 1e-6:
            continue
        ang = math.degrees(math.atan2(n[1], n[0]))
        tone = 0 if ang < -67.5 else (1 if ang < -22.5 else 2)
        out.append((a, b, tone, L, n))
    return out


def prism(dr, P, g, z0, z1, mat, top, win=None, shop=None, cornice=True, seed="", glint=True, outline=True):
    """Extruded footprint. mat = wall ramp, top = (rim, inner) or single colour."""
    pts = poly_pts(g)
    faces = visible_faces(pts, g.exterior.is_ccw)
    for a, b, tone, L, n in faces:
        q = [P(a[0], a[1], z0), P(b[0], b[1], z0), P(b[0], b[1], z1), P(a[0], a[1], z1)]
        col = mat[tone]
        dr.polygon(q, fill=col)
        if cornice and z1 - z0 >= 6:
            dr.line([P(a[0], a[1], z1 - 1), P(b[0], b[1], z1 - 1)], fill=mat[tone + 1])
        if shop:
            draw_shopfront(dr, P, a, b, L, z0, tone, mat, shop, seed)
        if win:
            draw_windows(dr, P, a, b, L, z0, z1, tone, mat, win, seed, glint)
        if outline:
            dr.polygon(q, outline=INK)
        if tone == 0 and z1 - z0 >= 8 and L >= 3:
            ea, eb = (a, b) if P(*a)[0] < P(*b)[0] else (b, a)
            hxp, hyp = P(ea[0], ea[1], z0)
            dr.line([(hxp + 1, hyp - 2), (hxp + 1, hyp - (z1 - z0) + 2)], fill=mixc(mat[0], WHITE, 0.55))
    top_pts = [P(x, y, z1) for x, y in pts]
    rim, inner = (top if isinstance(top[0], tuple) else (top, None))
    dr.polygon(top_pts, fill=rim)
    if inner is not None and g.area > 30:
        gi = inset(g, 1.0)
        if gi is not None:
            dr.polygon([P(x, y, z1) for x, y in poly_pts(gi)], fill=inner)
            # parapet inner shadow: 1px along the back edges of the inner roof
            ip = poly_pts(gi)
            for k in range(len(ip)):
                a, b = ip[k], ip[(k + 1) % len(ip)]
                dx, dy = b[0] - a[0], b[1] - a[1]
                L = math.hypot(dx, dy) or 1
                n = (dy / L, -dx / L) if gi.exterior.is_ccw else (-dy / L, dx / L)
                if n[0] - n[1] < -1e-6:     # back edge (faces away) -> parapet casts a dark line
                    dr.line([P(a[0], a[1], z1), P(b[0], b[1], z1)], fill=mixc(inner, INK, 0.25))
    if outline:
        dr.polygon(top_pts, outline=INK)
    return faces


def draw_windows(dr, P, a, b, L, z0, z1, tone, mat, win, seed, glint):
    style = win.get("style", "grid")
    start = win.get("start", 1)
    nfl = int((z1 - z0) // FLOOR)
    if style == "ribbon":
        if L < 2:
            return
        ta, tb = 0.7 / L, 1 - 0.7 / L
        for f in range(start, nfl):
            zf = z0 + f * FLOOR + 1
            pa = (a[0] + (b[0] - a[0]) * ta, a[1] + (b[1] - a[1]) * ta)
            pb = (a[0] + (b[0] - a[0]) * tb, a[1] + (b[1] - a[1]) * tb)
            dr.line([P(pa[0], pa[1], zf), P(pb[0], pb[1], zf)], fill=GLASS)
            dr.line([P(pa[0], pa[1], zf + 1), P(pb[0], pb[1], zf + 1)], fill=GLINT if tone == 0 else mixc(GLASS, GLINT, 0.45))
            # mullions every 2 m
            m = 2.0
            while m < L - 1:
                t = m / L
                dr.point(P(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, zf + 1), fill=mat[tone])
                m += 2.0
        return
    spacing = win.get("spacing", 3.0)
    if L < 2.4:
        return
    nw = max(1, int(L / spacing))
    for f in range(start, nfl):
        zf = z0 + f * FLOOR + 1
        for k in range(nw):
            t = (k + 0.5) / nw
            x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            sx, sy = P(x, y, zf)
            lit = h01(seed, f, k, round(a[0]), round(a[1])) < win.get("lit", 0.07)
            c = LIT if lit else GLASS
            dr.rectangle([sx, sy - 1, sx + 1, sy], fill=c)
            if glint and tone == 0 and not lit:
                dr.point((sx, sy - 1), fill=GLINT)
            if win.get("sill") and tone < 2:
                dr.point((sx, sy + 1), fill=mat[tone + 1])


def draw_shopfront(dr, P, a, b, L, z0, tone, mat, shop, seed):
    """Ground floor: shop windows + striped awning (or doors for residential)."""
    if L < 3:
        return
    kind = shop.get("kind", "shop")
    awn = shop.get("awning")
    nw = max(1, int(L / 3.0))
    for k in range(nw):
        t = (k + 0.5) / nw
        x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
        sx, sy = P(x, y, z0)
        if kind == "shop" or (kind == "res" and k % 3 == 1):
            dr.rectangle([sx, sy - 3, sx + 1, sy - 1], fill=GLASS if kind == "shop" else INK2)
            if kind == "shop":
                dr.point((sx, sy - 3), fill=GLINT if tone == 0 else mixc(GLASS, GLINT, .4))
        else:
            dr.rectangle([sx, sy - 2, sx + 1, sy - 1], fill=GLASS)
    if awn:
        m = 0.0
        k = 0
        while m < L - 0.01:
            t0, t1 = m / L, min(L, m + 1.0) / L
            p0 = (a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0)
            p1 = (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)
            c = awn[0] if k % 2 == 0 else awn[1]
            if tone == 2:
                c = mixc(c, INK, 0.18)
            for zz in (z0 + 4, z0 + 5):
                dr.line([P(p0[0], p0[1], zz), P(p1[0], p1[1], zz)], fill=c)
            m += 1.0
            k += 1
        dr.line([P(a[0], a[1], z0 + 3), P(b[0], b[1], z0 + 3)], fill=INK)


def gable_house(dr, P, rect, z0, zw, rh, mat, roof, seed, chimney=True, door=True):
    """Axis-aligned house with a pitched roof. rect=(x0,y0,x1,y1)."""
    x0, y0, x1, y1 = rect
    zr = zw + rh
    along_x = (x1 - x0) >= (y1 - y0)
    def poly(pts):
        return [P(*p) for p in pts]
    if along_x:
        ym = (y0 + y1) / 2
        back = poly([(x0, y1, zw), (x1, y1, zw), (x1, ym, zr), (x0, ym, zr)])
        front = poly([(x0, y0, zw), (x1, y0, zw), (x1, ym, zr), (x0, ym, zr)])
        wall_f = poly([(x0, y0, z0), (x1, y0, z0), (x1, y0, zw), (x0, y0, zw)])
        wall_r = poly([(x1, y0, z0), (x1, y1, z0), (x1, y1, zw), (x1, ym, zr), (x1, y0, zw)])
        dr.polygon(back, fill=roof[2], outline=INK)
        dr.polygon(wall_f, fill=mat[0]); dr.polygon(wall_r, fill=mat[2])
        _house_windows(dr, P, (x0, y0), (x1, y0), z0, zw, 0, mat, seed, door)
        _house_windows(dr, P, (x1, y0), (x1, y1), z0, zw, 2, mat, seed, False)
        dr.polygon(wall_f, outline=INK); dr.polygon(wall_r, outline=INK)
        dr.polygon(front, fill=roof[0])
        # tile rows
        for k in range(1, 4):
            t = k / 4
            yy, zz = y0 + (ym - y0) * t, zw + rh * t
            dr.line([P(x0, yy, zz), P(x1, yy, zz)], fill=roof[1])
        dr.polygon(front, outline=INK)
        if chimney:
            cx = x0 + (x1 - x0) * 0.72
            cg = Polygon([(cx, ym - 0.5), (cx + 1.5, ym - 0.5), (cx + 1.5, ym + 1), (cx, ym + 1)])
            prism(dr, P, cg, zr - 3, zr + 3, CREAM, CREAM[1], cornice=False)
    else:
        xm = (x0 + x1) / 2
        back = poly([(x0, y0, zw), (x0, y1, zw), (xm, y1, zr), (xm, y0, zr)])
        front = poly([(x1, y0, zw), (x1, y1, zw), (xm, y1, zr), (xm, y0, zr)])
        wall_f = poly([(x0, y0, z0), (x1, y0, z0), (x1, y0, zw), (xm, y0, zr), (x0, y0, zw)])
        wall_r = poly([(x1, y0, z0), (x1, y1, z0), (x1, y1, zw), (x1, y0, zw)])
        dr.polygon(back, fill=roof[2], outline=INK)
        dr.polygon(wall_f, fill=mat[0]); dr.polygon(wall_r, fill=mat[2])
        _house_windows(dr, P, (x0, y0), (x1, y0), z0, zw, 0, mat, seed, door)
        _house_windows(dr, P, (x1, y0), (x1, y1), z0, zw, 2, mat, seed, False)
        # round window in the gable
        gx, gy = P(xm, y0, zw + rh * 0.45)
        dr.rectangle([gx - 1, gy - 1, gx, gy], fill=GLASS)
        dr.polygon(wall_f, outline=INK); dr.polygon(wall_r, outline=INK)
        dr.polygon(front, fill=roof[0])
        for k in range(1, 4):
            t = k / 4
            xx, zz = x1 + (xm - x1) * t, zw + rh * t
            dr.line([P(xx, y0, zz), P(xx, y1, zz)], fill=roof[1])
        dr.polygon(front, outline=INK)
        if chimney:
            cy = y0 + (y1 - y0) * 0.7
            cg = Polygon([(xm - 0.5, cy), (xm + 1, cy), (xm + 1, cy + 1.5), (xm - 0.5, cy + 1.5)])
            prism(dr, P, cg, zr - 3, zr + 3, CREAM, CREAM[1], cornice=False)


def _house_windows(dr, P, a, b, z0, zw, tone, mat, seed, door):
    L = math.hypot(b[0] - a[0], b[1] - a[1])
    nfl = max(1, int((zw - z0) // FLOOR))
    nw = max(1, int(L / 3.2))
    for f in range(nfl):
        for k in range(nw):
            t = (k + 0.5) / nw
            x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
            sx, sy = P(x, y, z0 + f * FLOOR + 1)
            if door and f == 0 and k == nw // 2:
                dr.rectangle([sx, sy - 2, sx + 1, sy], fill=INK2)
                continue
            dr.rectangle([sx, sy - 1, sx + 1, sy], fill=GLASS)
            if tone == 0:
                dr.point((sx, sy - 1), fill=GLINT)
            dr.point((sx, sy + 1), fill=WHITE if tone == 0 else mat[3])


# ------------------------------------------------------------------ sprites
TREE_RND = ["..#####..", ".#hhggg#.", "#hhggggd#", "#hgggggd#", "#ggggddd#", ".#gdddd#.", "..##t##..",
            "...#t#...", "...###..."]
TREE_CONE = ["....#....", "...#h#...", "...#gd#..", "..#hgd#..", "..#hggd#.", ".#hgggd#.", ".#hggddd#",
             "#########", "...#t#...", "...###..."]
COIN9 = ["..#####..", ".#hhyyy#.", "#hhyyyyy#", "#hyyoyyd#", "#hyyoyyd#", "#yyyoydd#", "#yyyyddd#",
         ".#ydddd#.", "..#####.."]
COIN5 = [".###.", "#hyy#", "#yyd#", "#ydd#", ".###."]
HOUSE_ICON = ["....#....", "...#w#...", "..#www#..", ".#wwwww#.", "#wwwwwww#", ".#w###w#.", ".#w#r#w#.",
              ".#w#r#w#.", ".#######."]
SPR_COL = {"#": INK, "h": LEAF[0], "g": LEAF[1], "d": LEAF[2], "t": hx("#8a5530"),
           "y": GOLD[0], "o": GOLD[3], "w": WHITE, "r": RED[1]}


def blit(img, spr, x, y, cmap=None):
    px = img.load()
    W, H = img.size
    cm = dict(SPR_COL)
    if cmap:
        cm.update(cmap)
    for j, row in enumerate(spr):
        for i, ch in enumerate(row):
            if ch != "." and 0 <= x + i < W and 0 <= y + j < H:
                px[x + i, y + j] = cm[ch]


COIN_MAP = {"h": hx("#fff1a8"), "y": GOLD[0], "d": GOLD[2], "o": GOLD[3]}


# ------------------------------------------------------------------ scene objects
WALL_MATS = [CREAM, CREAM, BLUEW, PINKW, CREAM]
ROOFS = [R_TEAL, R_SKY, R_SAND, R_LILAC]
AWNINGS = [(TEALC[1], WHITE), (SKYC[1], WHITE), (GOLD[1], WHITE)]


def piece_for_plot(p, role):
    """Return a scene object for a plot given its role dict."""
    g = p["geom"]
    tier = role.get("tier", 3)
    owner = role.get("owner")
    seed = p["id"]
    o = dict(kind="piece", foot=g, seed=seed, role=role, plot=p, tier=tier)
    if role.get("office"):
        o.update(mat=GOLD, roof=R_OWN, plinth=GOLD, levels=4)
    elif owner == "me":
        o.update(mat=RED, roof=R_OWN, plinth=RED, levels=max(5, min(8, p["levels"])))
    else:
        o.update(mat=WALL_MATS[int(h01(seed, "w") * len(WALL_MATS))],
                 roof=ROOFS[int(h01(seed, "r") * len(ROOFS))], plinth=None,
                 levels=max(4, min(9, p["levels"])))
    o["shop"] = {"kind": "shop" if p["cat"] in ("commercial", "hotel") else "res",
                 "awning": AWNINGS[int(h01(seed, "a") * 3)] if p["cat"] in ("commercial", "hotel") else None}
    return o


def obj_height(o):
    if o["kind"] != "piece":
        return o.get("h", 10)
    t = o["tier"]
    if o["role"].get("office"):
        return 4 * FLOOR + 14
    return {0: 6, 1: 14, 2: 18, 3: o["levels"] * FLOOR, 4: 14 * FLOOR, 5: 27 * FLOOR + 14}.get(t, o["levels"] * FLOOR)


def draw_piece(dr, img, P, o):
    g = o["foot"]
    seed = o["seed"]
    role = o["role"]
    tier = o["tier"]
    zb = 0
    if o.get("plinth"):
        pl = inset(g, 0.25) or g
        top = (o["plinth"][0], GRASS) if tier in (1, 2) else (o["plinth"][0], o["plinth"][0])
        prism(dr, P, pl, 0, 2, o["plinth"], top, cornice=False)
        zb = 2
    if role.get("office"):
        return draw_office(dr, img, P, o, zb)
    if tier == 0:
        return draw_lot(dr, img, P, o)
    if tier in (1, 2):
        return draw_home(dr, img, P, o, zb)
    if tier == 3:
        body = inset(g, 1.25 if o.get("plinth") else 0.5)
        ztop = zb + o["levels"] * FLOOR
        if role.get("upgrading"):
            return draw_construction(dr, img, P, o, body, zb)
        prism(dr, P, body, zb, ztop, o["mat"], o["roof"], win={"style": "grid", "lit": 0.06},
              shop=o["shop"], seed=seed)
        roof_props(dr, P, body, ztop, seed)
        if o.get("plinth"):
            flag_on(dr, P, body, ztop, seed)
        o["top_z"] = ztop
        return
    if tier == 4:
        body = inset(g, 2.0)
        ztop = zb + 14 * FLOOR
        prism(dr, P, body, zb, ztop, o["mat"], o["roof"], win={"style": "grid", "spacing": 2.5, "lit": 0.05},
              shop={"kind": "shop", "awning": (WHITE, o["mat"][1])}, seed=seed)
        c = body.centroid
        tank = Polygon([(c.x - 2, c.y - 1), (c.x + 1, c.y - 1), (c.x + 1, c.y + 2), (c.x - 2, c.y + 2)])
        prism(dr, P, tank, ztop, ztop + 4, CREAM, R_TEAL[0], cornice=False)
        flag_on(dr, P, body, ztop, seed)
        o["top_z"] = ztop
        return
    if tier == 5:
        secs = [(1.5, 0, 17), (3.5, 17, 24), (5.5, 24, 27)]
        ztop = zb
        for d, f0, f1 in secs:
            b = inset(g, d)
            if b is None:
                continue
            z0, z1 = zb + f0 * FLOOR, zb + f1 * FLOOR
            prism(dr, P, b, z0, z1, o["mat"], o["roof"], win={"style": "ribbon", "start": 1 if f0 == 0 else 0},
                  shop={"kind": "shop", "awning": None} if f0 == 0 else None, seed=seed)
            ztop = z1
            lastb = b
        # crown: antenna with beacon
        c = lastb.centroid
        ax, ay = P(c.x, c.y, ztop)
        dr.line([(ax, ay), (ax, ay - 14)], fill=INK)
        dr.line([(ax + 1, ay), (ax + 1, ay - 10)], fill=INK2)
        dr.rectangle([ax - 1, ay - 16, ax + 1, ay - 14], fill=INK)
        dr.point((ax, ay - 15), fill=hx("#ff4040"))
        o["top_z"] = ztop + 14
        return


def flag_on(dr, P, body, ztop, seed, col=None):
    col = col or RED
    pts = poly_pts(body)
    # back-most vertex (smallest screen Y) keeps the flag clear of the facade
    vx = min(pts, key=lambda q: (q[0] - q[1]))
    c = body.centroid
    fx, fy = vx[0] + (c.x - vx[0]) * 0.35, vx[1] + (c.y - vx[1]) * 0.35
    x, y = P(fx, fy, ztop)
    dr.line([(x, y), (x, y - 10)], fill=INK)
    dr.polygon([(x + 1, y - 10), (x + 6, y - 8), (x + 1, y - 6)], fill=col[0], outline=INK)
    dr.point((x + 2, y - 9), fill=WHITE)


TANK = [".###.", "#www#", "#hww#", "#hwd#", "#hwd#", ".###."]


def roof_props(dr, P, body, ztop, seed):
    """Eixample roof clutter as chunky toy bits: stair huts, water tanks, AC boxes, planters."""
    if body.area < 90:
        return
    core = body.buffer(-1.6)
    if core.is_empty:
        return
    x0, y0, x1, y1 = core.bounds
    cands = []
    for gx in np.arange(x0, x1 - 1.5, 4.0):
        for gy in np.arange(y0, y1 - 1.5, 4.0):
            cands.append((round(gx), round(gy)))
    cands.sort(key=lambda q: h01(seed, q))
    n = min(len(cands), 1 + int(body.area / 160) + int(h01(seed, "n") * 2))
    chosen = sorted(cands[:n], key=lambda q: q[0] - q[1])          # back to front
    img = dr._image
    for k, (px_, py_) in enumerate(chosen):
        kind = ["hut", "tank", "ac", "hut", "planter"][int(h01(seed, k, "kind") * 5)]
        if kind == "hut":
            bx = sbox(px_, py_, px_ + 3, py_ + 3)
            if core.contains(bx):
                prism(dr, P, bx, ztop, ztop + 4, CREAM, CREAM[1], cornice=False)
                sx, sy = P(px_ + 1.5, py_, ztop)
                dr.rectangle([sx, sy - 2, sx, sy - 1], fill=INK2)
        elif kind == "ac":
            bx = sbox(px_, py_, px_ + 2, py_ + 1.5)
            if core.contains(bx):
                prism(dr, P, bx, ztop, ztop + 2, BLUEW, BLUEW[0], cornice=False)
        elif kind == "planter":
            bx = sbox(px_, py_, px_ + 3, py_ + 1)
            if core.contains(bx):
                prism(dr, P, bx, ztop, ztop + 2, LEAF, LEAF[0], cornice=False)
        else:
            if core.contains(Point(px_ + 1, py_ + 1)):
                sx, sy = P(px_ + 1, py_ + 1, ztop)
                blit(img, TANK, sx - 2, sy - 5, {"w": WHITE, "h": CREAM[1], "d": CREAM[2]})


def draw_home(dr, img, P, o, zb):
    g = o["foot"]
    x0, y0, x1, y1 = g.bounds
    w, d = x1 - x0, y1 - y0
    seed = o["seed"]
    mat = o["mat"] if o.get("plinth") else CREAM
    if o["tier"] == 1:
        hx0, hy0 = x0 + w * 0.22, y0 + d * 0.30
        rect = (round(hx0), round(hy0), round(hx0 + min(10, w * .55)), round(hy0 + min(8, d * .45)))
        # back tree, house, front tree
        tree_at(img, P, x0 + w * .2, y1 - d * .15, zb, cone=False)
        gable_house(dr, P, rect, zb, zb + 2 * FLOOR, 7, mat, SLATE, seed)
        tree_at(img, P, x1 - w * .18, y0 + d * .2, zb, cone=True)
        if o.get("plinth"):
            flag_on(dr, P, Polygon([(rect[0], rect[1]), (rect[2], rect[1]), (rect[2], rect[3]), (rect[0], rect[3])]),
                    zb + 2 * FLOOR + 7, seed)
        o["top_z"] = zb + 2 * FLOOR + 7
    else:
        # estate: main house + side wing + pool + hedge + trees
        tree_at(img, P, x0 + w * .15, y1 - d * .12, zb, cone=True)
        tree_at(img, P, x0 + w * .45, y1 - d * .1, zb, cone=False)
        main = (round(x0 + w * .12), round(y0 + d * .42), round(x0 + w * .12 + min(14, w * .62)), round(y0 + d * .42 + min(9, d * .38)))
        wing = (main[2] - 1, main[1] + 1, min(round(x1 - 1.5), main[2] + 5), main[3] - 1)
        pool = Polygon([(x0 + w * .15, y0 + d * .12), (x0 + w * .55, y0 + d * .12), (x0 + w * .55, y0 + d * .30),
                        (x0 + w * .15, y0 + d * .30)])
        pp = [P(x, y, zb) for x, y in poly_pts(pool)]
        dr.polygon(pp, fill=WATER, outline=INK)
        a, b = P(pool.bounds[0] + 1, pool.bounds[3] - 0.5, zb), P(pool.bounds[2] - 1, pool.bounds[3] - 0.5, zb)
        dr.line([(a[0], a[1] + 1), (b[0], b[1] + 1)], fill=WHITE)
        gable_house(dr, P, main, zb, zb + 3 * FLOOR, 8, mat, SLATE, seed)
        if wing[2] - wing[0] >= 3:
            gable_house(dr, P, wing, zb, zb + 2 * FLOOR, 5, mat, SLATE, seed + "w", chimney=False, door=False)
        hedge = Polygon([(x1 - 3.0, y0 + 1.0), (x1 - 1.0, y0 + 1.0), (x1 - 1.0, y0 + d * .55), (x1 - 3.0, y0 + d * .55)])
        prism(dr, P, hedge, zb, zb + 3, LEAF, LEAF[0], cornice=False)
        tree_at(img, P, x1 - w * .12, y0 + d * .72, zb, cone=False)
        if o.get("plinth"):
            mp = Polygon([(main[0], main[1]), (main[2], main[1]), (main[2], main[3]), (main[0], main[3])])
            flag_on(dr, P, mp, zb + 3 * FLOOR + 8, seed)
        o["top_z"] = zb + 3 * FLOOR + 8


def tree_at(img, P, x, y, z=0, cone=False):
    sx, sy = P(x, y, z)
    spr = TREE_CONE if cone else TREE_RND
    blit(img, spr, sx - 4, sy - len(spr) + 1)


def draw_lot(dr, img, P, o):
    g = o["foot"]
    gi = inset(g, 0.5)
    pts = [P(x, y, 0) for x, y in poly_pts(gi)]
    # (dirt itself is painted in the ground pass; here: stakes + sign)
    for x, y in poly_pts(gi):
        sx, sy = P(x, y, 0)
        dr.line([(sx, sy), (sx, sy - 3)], fill=INK)
        dr.point((sx, sy - 3), fill=WHITE)
    c = g.centroid
    sx, sy = P(c.x, c.y, 0)
    dr.line([(sx - 6, sy), (sx - 6, sy - 6)], fill=INK)
    dr.line([(sx + 6, sy), (sx + 6, sy - 6)], fill=INK)
    dr.rectangle([sx - 11, sy - 15, sx + 11, sy - 6], fill=RED[1], outline=INK)
    dr.line([(sx - 10, sy - 14), (sx + 10, sy - 14)], fill=RED[0])
    draw_text(img, sx - 9, sy - 13, "VENTA", SMALL, WHITE)
    o["top_z"] = 16


BIG_HOUSE = ["......#......", ".....#w#.....", "....#www#.##.", "...#wwwww#w#.", "..#wwwwwww##.", ".#wwwwwwwww#.",
             "#############", ".#wwwwwwwww#.", ".#w##www##w#.", ".#w#y#w#r#w#.", ".#w###w#r#w#.", ".#wwwww#r#w#.",
             ".###########."]


def draw_office(dr, img, P, o, zb):
    g = o["foot"]
    body = inset(g, 1.25)
    ztop = zb + 5 * FLOOR
    faces = prism(dr, P, body, zb, ztop, GOLD, (WHITE, GRASS2), win={"style": "grid", "start": 1, "lit": 0.25, "sill": True},
                  shop={"kind": "shop", "awning": (RED[1], WHITE)}, seed=o["seed"])
    # chamfer = the face looking straight at the camera -> big storefront + sign
    ch = max(faces, key=lambda f: (f[4][0] - f[4][1]) + (0.001 * f[3]))
    a, b = ch[0], ch[1]
    # roof garden: a few trees on the back half of the roof
    c = body.centroid
    for k, (fx, fy) in enumerate([(-0.45, 0.55), (0.05, 0.75), (-0.75, 0.15)]):
        tree_at(img, P, c.x + fx * 9, c.y + fy * 9, ztop, cone=(k == 1))
    # sign board standing on the roof, parallel to the chamfer (= screen-aligned)
    pa, pb = P(a[0], a[1], ztop), P(b[0], b[1], ztop)
    x0, x1 = min(pa[0], pb[0]) - 2, max(pa[0], pb[0]) + 2
    yb = pa[1] - 1
    for lx in (x0 + 6, x1 - 6):
        dr.rectangle([lx - 1, yb - 4, lx, yb + 1], fill=INK2, outline=INK)
    top = yb - 18
    dr.rectangle([x0, top, x1, yb - 4], fill=RED[1], outline=INK)
    # marquee bulbs around the board
    for xx in range(x0 + 1, x1):
        on = (xx // 2) % 2 == 0
        dr.point((xx, top + 1), fill=LIT if on else WHITE)
        dr.point((xx, yb - 5), fill=LIT if not on else WHITE)
    for yy in range(top + 2, yb - 5):
        on = (yy // 2) % 2 == 0
        dr.point((x0 + 1, yy), fill=LIT if on else WHITE)
        dr.point((x1 - 1, yy), fill=LIT if not on else WHITE)
    dr.line([(x0 + 2, yb - 6), (x1 - 2, yb - 6)], fill=RED[2])
    label = "TINY REALTOR"
    tw = text_width(label, SMALL)
    draw_text(img, (x0 + x1) // 2 - tw // 2 + 1, top + 5, label, SMALL, WHITE, shadow=(0, 1, RED[3]))
    # big house emblem on top of the board
    blit(img, BIG_HOUSE, (x0 + x1) // 2 - 6, top - 12, {"y": LIT, "r": RED[1]})
    o["top_z"] = ztop + 30
    o["sign_box"] = (x0, top - 12, x1, yb)


def draw_construction(dr, img, P, o, body, zb):
    done, target = 5, 12
    zdone = zb + done * FLOOR
    prism(dr, P, body, zb, zdone, o["mat"], (RED[0], hx("#c9b79a")), win={"style": "grid", "lit": 0.05},
          shop=o["shop"], seed=o["seed"])
    zt = zb + target * FLOOR
    pts = poly_pts(body)
    vis = visible_faces(pts, body.exterior.is_ccw)
    vis_edges = {(a, b) for a, b, *_ in vis}
    n_ = len(pts)
    edges = [(pts[k], pts[(k + 1) % n_]) for k in range(n_)]
    # back edges + back poles first, then front
    for front in (False, True):
        for a, b in edges:
            if ((a, b) in vis_edges) != front:
                continue
            for z in range(zdone, zt + 1, FLOOR):
                dr.line([P(a[0], a[1], z), P(b[0], b[1], z)], fill=SCAF if front else mixc(SCAF, INK, .35))
            L = math.hypot(b[0] - a[0], b[1] - a[1])
            m = 0.0
            while m <= L + 0.01:
                t = m / L
                x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
                dr.line([P(x, y, zdone), P(x, y, zt)], fill=INK if front else INK2)
                m += 4.0
            if front:   # diagonal braces
                m = 0.0
                k = 0
                while m + 4 <= L + 0.01:
                    t0, t1 = m / L, (m + 4) / L
                    za, zb2 = zdone + (k % 3) * 2 * FLOOR, zdone + (k % 3) * 2 * FLOOR + 2 * FLOOR
                    if zb2 <= zt:
                        pa = (a[0] + (b[0] - a[0]) * t0, a[1] + (b[1] - a[1]) * t0)
                        pb = (a[0] + (b[0] - a[0]) * t1, a[1] + (b[1] - a[1]) * t1)
                        dr.line([P(pa[0], pa[1], za), P(pb[0], pb[1], zb2)], fill=SCAF)
                    m += 4.0
                    k += 1
    # tower crane at the back corner
    vx = min(pts, key=lambda q: (q[0] + q[1]))          # left-most corner on screen
    mx, my = P(vx[0] - 1.0, vx[1] - 1.0, 0)
    mtop = my - zt - 12
    for yy in range(my, mtop, -1):
        dr.point((mx - 1, yy), fill=INK); dr.point((mx + 2, yy), fill=INK)
        dr.point((mx, yy), fill=GOLD[0] if (yy // 2) % 2 else GOLD[2])
        dr.point((mx + 1, yy), fill=GOLD[2] if (yy // 2) % 2 else GOLD[0])
    # jib
    jdir = o["role"].get("jib", 1)
    jl, jr = (mx - 14, mx + 46) if jdir > 0 else (mx - 46, mx + 15)
    dr.rectangle([jl, mtop - 3, jr, mtop], fill=GOLD[0], outline=INK)
    for xx in range(jl + 2, jr - 1, 3):
        dr.line([(xx, mtop - 2), (xx + 1, mtop - 1)], fill=GOLD[2])
    cwx = jl if jdir > 0 else jr - 6
    dr.rectangle([cwx - 1, mtop - 1, cwx + 5, mtop + 4], fill=SLATE[2], outline=INK)     # counterweight
    dr.polygon([(mx - 1, mtop - 3), (mx + 2, mtop - 3), (mx + 1, mtop - 9), (mx, mtop - 9)], fill=GOLD[1], outline=INK)
    dr.line([(mx + 1, mtop - 9), (jr, mtop - 3)], fill=INK)
    dr.line([(mx, mtop - 9), (jl, mtop - 3)], fill=INK)
    hxp = mx + 34 if jdir > 0 else mx - 34
    dr.rectangle([mx - 2, mtop + 1, mx + 3, mtop + 5], fill=SKYC[1], outline=INK)       # cab
    dr.line([(hxp, mtop + 1), (hxp, mtop + 22)], fill=INK)
    dr.rectangle([hxp - 5, mtop + 23, hxp + 5, mtop + 25], fill=RED[1], outline=INK)    # hanging beam
    o["top_z"] = zt
    o["crane_top"] = (mx, mtop)


def draw_car(dr, P, o):
    x, y, along_x, mat = o["x"], o["y"], o["along_x"], o["mat"]
    L, W_ = 4.5, 2.0
    if along_x:
        body = Polygon([(x - L / 2, y - W_ / 2), (x + L / 2, y - W_ / 2), (x + L / 2, y + W_ / 2), (x - L / 2, y + W_ / 2)])
        cab = Polygon([(x - 1.2, y - 0.75), (x + 0.8, y - 0.75), (x + 0.8, y + 0.75), (x - 1.2, y + 0.75)])
    else:
        body = Polygon([(x - W_ / 2, y - L / 2), (x + W_ / 2, y - L / 2), (x + W_ / 2, y + L / 2), (x - W_ / 2, y + L / 2)])
        cab = Polygon([(x - 0.75, y - 0.8), (x + 0.75, y - 0.8), (x + 0.75, y + 1.2), (x - 0.75, y + 1.2)])
    prism(dr, P, body, 0, 3, mat, mat[0], cornice=False)
    prism(dr, P, cab, 3, 5, [GLINT, GLASS, GLASS, INK], WHITE, cornice=False)


# ------------------------------------------------------------------ depth sort
def bbox_uv(o):
    x0, y0, x1, y1 = o["foot"].bounds
    return x0, x1, -y1, -y0


def depth_sort(objs):
    n = len(objs)
    bbs = [bbox_uv(o) for o in objs]
    after = [[] for _ in range(n)]
    indeg = [0] * n
    eps = 0.01
    for a in range(n):
        A = bbs[a]
        xa0, xa1 = A[0] - A[3], A[1] - A[2]          # screen X range ~ u - v = x + y
        for b in range(a + 1, n):
            Bb = bbs[b]
            xb0, xb1 = Bb[0] - Bb[3], Bb[1] - Bb[2]
            if xa1 <= xb0 or xb1 <= xa0:
                continue
            a_behind = A[1] <= Bb[0] + eps or A[3] <= Bb[2] + eps
            b_behind = Bb[1] <= A[0] + eps or Bb[3] <= A[2] + eps
            if a_behind and not b_behind:
                f, s_ = a, b
            elif b_behind and not a_behind:
                f, s_ = b, a
            else:
                ca = objs[a]["foot"].centroid
                cb = objs[b]["foot"].centroid
                f, s_ = (a, b) if (ca.x - ca.y) <= (cb.x - cb.y) else (b, a)
            after[f].append(s_)
            indeg[s_] += 1
    key = lambda i: (bbs[i][0] + bbs[i][2])
    ready = [(key(i), i) for i in range(n) if indeg[i] == 0]
    heapq.heapify(ready)
    out = []
    while ready:
        _, i = heapq.heappop(ready)
        out.append(i)
        for j in after[i]:
            indeg[j] -= 1
            if indeg[j] == 0:
                heapq.heappush(ready, (key(j), j))
    if len(out) < n:
        out += sorted(set(range(n)) - set(out), key=key)
    return [objs[i] for i in out]


# ------------------------------------------------------------------ UI widgets
def card(dr, x0, y0, x1, y1, fill, edge=None, shadow=True):
    """Chunky board-game card: ink outline, cut corners, hard drop shadow, light top bevel."""
    if shadow:
        dr.rectangle([x0 + 1, y1 + 1, x1 - 1, y1 + 2], fill=INK)
        dr.point((x1, y1 + 1), fill=INK)
        dr.point((x0, y1 + 1), fill=INK)
    dr.rectangle([x0 + 1, y0, x1 - 1, y1], fill=INK)
    dr.rectangle([x0, y0 + 1, x1, y1 - 1], fill=INK)
    dr.rectangle([x0 + 1, y0 + 1, x1 - 1, y1 - 1], fill=fill)
    if edge:
        dr.line([(x0 + 1, y1 - 1), (x1 - 1, y1 - 1)], fill=edge)
        dr.line([(x0 + 2, y0 + 1), (x1 - 2, y0 + 1)], fill=mixc(fill, WHITE, 0.45))


def price_tag(img, dr, x, y, text):
    """Price tag centred at x with its pointer tip at (x, y)."""
    tw = text_width(text, SMALL)
    w = tw + 5 + 6
    x0 = min(max(x - w // 2, 3), img.width - w - 4)     # keep tags fully inside the window
    y0 = y - 12
    card(dr, x0, y0, x0 + w, y0 + 9, WHITE, edge=hx("#e8dcc4"))
    dr.polygon([(x - 2, y0 + 10), (x + 2, y0 + 10), (x, y0 + 12)], fill=INK)
    blit(img, COIN5, x0 + 2, y0 + 2, COIN_MAP)
    draw_text(img, x0 + 8, y0 + 2, text, SMALL, INK)


def coin_pop(img, dr, x, y, text):
    blit(img, COIN5, x, y, COIN_MAP)
    draw_text(img, x + 7, y, text, SMALL, WHITE, outline=INK)


def progress_bubble(img, dr, x, y, frac, eta):
    w = 46
    x0 = x - w // 2
    card(dr, x0, y - 14, x0 + w, y - 3, WHITE, edge=hx("#e8dcc4"))
    dr.polygon([(x - 2, y - 2), (x + 2, y - 2), (x, y)], fill=INK)
    # up arrow
    ax, ay = x0 + 3, y - 12
    dr.polygon([(ax + 3, ay), (ax + 6, ay + 3), (ax + 4, ay + 3), (ax + 4, ay + 7), (ax + 2, ay + 7), (ax + 2, ay + 3),
                (ax, ay + 3)], fill=LEAF[1], outline=INK)
    bx0, bx1 = x0 + 11, x0 + 26
    dr.rectangle([bx0, y - 11, bx1, y - 6], fill=INK)
    dr.rectangle([bx0 + 1, y - 10, bx1 - 1, y - 7], fill=hx("#e8dcc4"))
    fx = bx0 + 1 + int((bx1 - bx0 - 2) * frac)
    dr.rectangle([bx0 + 1, y - 10, fx, y - 7], fill=LEAF[1])
    dr.line([(bx0 + 1, y - 10), (fx, y - 10)], fill=LEAF[0])
    draw_text(img, bx1 + 3, y - 11, eta, SMALL, INK)


# ------------------------------------------------------------------ the city window
def render_city():
    B, plots, roads, greens = load_block(SRC)
    byidx = {p["idx"]: p for p in plots}
    OFFICE = 166
    office_c = byidx[OFFICE]["geom"].centroid
    R = 56.0
    roles = {
        OFFICE: dict(office=True, owner="me"),
        182: dict(owner="me", tier=5),                    # skyscraper - outgrew its neighbours
        173: dict(owner="me", tier=4),                    # tower
        171: dict(owner="me", tier=2),                    # estate
        174: dict(owner="me", tier=3),
        94: dict(owner="me", tier=3),
        170: dict(owner="me", tier=3, upgrading=True, jib=1),   # mid-upgrade: scaffolding + crane
        172: dict(tier=0),                                # lot for sale, right next to the office
    }
    tags = {172: "8K", 105: "52K", 169: "46K"}
    W = H = 300
    cam_xy, cam_xmy = office_c.x + office_c.y + 4, office_c.x - office_c.y + 6   # office ~ screen centre
    P = Proj(150 - cam_xy * S, 150 - cam_xmy * S / 2)

    def on_screen(g, h):
        xs, ys = zip(*[P(x, y, 0) for x, y in poly_pts(g)])
        return max(xs) > -20 and min(xs) < W + 20 and min(ys) - h < H + 10 and max(ys) > -10

    objs = []
    for p in plots:
        role = roles.get(p["idx"], {})
        if p["cat"] == "empty" and not role:
            role = dict(tier=0)
        o = piece_for_plot(p, role)
        if not on_screen(p["geom"], obj_height(o)):
            continue
        objs.append(o)

    # ---- ground pass ---------------------------------------------------------
    lab = Image.new("L", (W, H), 0)
    ld = ImageDraw.Draw(lab)
    road_polys = [LineString(r["line"]).buffer(r["width"] / 2, cap_style=2, join_style=2) for r in roads]
    roads_u = unary_union(road_polys)
    for rp in road_polys:
        ld.polygon([P(x, y) for x, y in rp.exterior.coords], fill=1)
    for gr in greens:
        ld.polygon([P(x, y) for x, y in gr["geom"].exterior.coords], fill=2)
    for o in objs:
        if o["tier"] == 0 and not o.get("plinth"):
            gi = inset(o["foot"], 0.5)
            ld.polygon([P(x, y) for x, y in poly_pts(gi)], fill=3)
    L = np.array(lab)
    Xs, Ys = np.meshgrid(np.arange(W) + 0.0, np.arange(H) + 0.0)
    wx, wy = P.inv(Xs, Ys)
    chk = ((np.floor(wx / 4) + np.floor(wy / 4)) % 2).astype(bool)
    inside = np.hypot(wx - office_c.x, wy - office_c.y) < R
    rgb = np.zeros((H, W, 3), np.float32)
    def put(mask, col):
        rgb[mask] = col
    put((L == 0) & ~chk & ~inside, BOARD_A); put((L == 0) & chk & ~inside, BOARD_B)
    put((L == 0) & ~chk & inside, ZONE_A); put((L == 0) & chk & inside, ZONE_B)
    put(L == 1, ROAD)
    stripes = (np.floor(wx / 2) % 2).astype(bool)
    put((L == 2) & stripes, GRASS); put((L == 2) & ~stripes, GRASS2)
    speck = (np.floor(wx * 2) * 7 + np.floor(wy * 2) * 13) % 11 == 0
    put((L == 3), DIRT); put((L == 3) & speck, DIRT2)

    # shadows (cast toward +y = screen up-right, so they never hide the front of a piece)
    sm = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(sm)
    for o in objs:
        h = obj_height(o)
        if h <= 8:
            continue
        g = o["foot"]
        off = h * 0.30
        sh = unary_union([g, Polygon([(x, y + off) for x, y in poly_pts(g)])]).convex_hull
        sd.polygon([P(x, y) for x, y in sh.exterior.coords], fill=255)
    sh_mask = np.array(sm) > 0
    rgb[sh_mask] = rgb[sh_mask] * 0.72 + np.array(INK, np.float32) * 0.28

    img = Image.fromarray(rgb.round().astype(np.uint8), "RGB")
    dr = ImageDraw.Draw(img)

    # road markings: dashes, zebras
    inter = unary_union([a.intersection(b) for i, a in enumerate(road_polys) for b in road_polys[i + 1:]])
    inter_b = inter.buffer(5)
    for r in roads:
        line = LineString(r["line"])
        offs = [-r["width"] / 4, r["width"] / 4] if r["width"] >= 26 else [0.0]
        for off in offs:
            ln = line.offset_curve(off) if off else line
            d = 0.0
            while d < ln.length:
                p0, p1 = ln.interpolate(d), ln.interpolate(min(d + 3, ln.length))
                if not inter_b.contains(p0) and not inter_b.contains(p1):
                    dr.line([P(p0.x, p0.y), P(p1.x, p1.y)], fill=ROAD_MARK)
                d += 7.0
    vert = [r for r in roads if abs(r["line"][0][0] - r["line"][1][0]) < 3]
    horz = [r for r in roads if abs(r["line"][0][1] - r["line"][1][1]) < 3]
    for v in vert:
        xv, wv = v["line"][0][0], v["width"]
        for hz in horz:
            yh, wh = hz["line"][0][1], hz["width"]
            for side in (-1, 1):     # crossings on the vertical road
                ya = yh + side * (wh / 2 + 1)
                yb = yh + side * (wh / 2 + 4)
                xx = xv - wv / 2 + 1
                while xx < xv + wv / 2 - 1:
                    q = [P(xx, ya), P(xx + 1, ya), P(xx + 1, yb), P(xx, yb)]
                    dr.polygon(q, fill=ROAD_MARK)
                    xx += 2.0
                xa = xv + side * (wv / 2 + 1)
                xb = xv + side * (wv / 2 + 4)
                yy = yh - wh / 2 + 1
                while yy < yh + wh / 2 - 1:
                    q = [P(xa, yy), P(xb, yy), P(xb, yy + 1), P(xa, yy + 1)]
                    dr.polygon(q, fill=ROAD_MARK)
                    yy += 2.0
    # curbs: ink outline of the road network
    rgeoms = getattr(roads_u, "geoms", [roads_u])
    for rg in rgeoms:
        for ring in [rg.exterior] + list(rg.interiors):
            dr.line([P(x, y) for x, y in ring.coords], fill=INK)
    for gr in greens:
        dr.line([P(x, y) for x, y in gr["geom"].exterior.coords], fill=LEAF[2])

    # office radius: dashed boundary tape (ink band + red/white dashes)
    def ring_pts(rr, a0, a1, n):
        return [P(office_c.x + rr * math.cos(a0 + (a1 - a0) * k / n), office_c.y + rr * math.sin(a0 + (a1 - a0) * k / n))
                for k in range(n + 1)]
    nd = 72
    for k in range(nd * 3):          # ink band first (continuous)
        a0, a1 = 2 * math.pi * k / (nd * 3), 2 * math.pi * (k + 1) / (nd * 3)
        dr.polygon(ring_pts(R + 1.1, a0, a1, 2) + ring_pts(R - 1.1, a1, a0, 2), fill=INK)
    for k in range(nd):              # red / white tape dashes
        a0, a1 = 2 * math.pi * k / nd, 2 * math.pi * (k + 1) / nd
        dr.polygon(ring_pts(R + 0.4, a0, a1, 4) + ring_pts(R - 0.4, a1, a0, 4), fill=RED[1] if k % 2 == 0 else WHITE)

    # ---- trees along sidewalks, cars on roads -------------------------------
    builds = unary_union([p["geom"] for p in plots]).buffer(1.0)
    rx = [c[0] for r in roads for c in r["line"]]
    ry = [c[1] for r in roads for c in r["line"]]
    for r in roads:
        line = LineString(r["line"])
        for side in (-1, 1):
            off = line.offset_curve(side * (r["width"] / 2 + 2.5))
            d = 5.0
            while d < off.length:
                pt = off.interpolate(d)
                if (not inter.buffer(6).contains(pt)) and not roads_u.contains(pt) and not builds.contains(pt):
                    tg = Point(pt.x, pt.y).buffer(1.2, cap_style=3)
                    if on_screen(tg, 12):
                        objs.append(dict(kind="tree", foot=tg, x=pt.x, y=pt.y, cone=False, h=10))
                d += 10.0
    for gr in greens:
        gg = gr["geom"]
        x0, y0, x1, y1 = gg.bounds
        for k in range(6):
            x = x0 + 3 + h01(gr["kind"], x0, k, "x") * max(0.1, (x1 - x0 - 6))
            y = y0 + 3 + h01(gr["kind"], y0, k, "y") * max(0.1, (y1 - y0 - 6))
            tg = Point(x, y).buffer(1.2, cap_style=3)
            if gg.contains(tg) and on_screen(tg, 12):
                objs.append(dict(kind="tree", foot=tg, x=x, y=y, cone=h01(x, y) < .5, h=10))
    cars = [(16 + 7.5, -26, False, SKYC), (16 - 7.5, 48, False, TEALC), (-36, 1 - 4.5, True, GOLD),
            (46, 1 + 4.5, True, CREAM), (16 + 7.5, 70, False, PINKW), (-78, 1 + 4.5, True, SKYC),
            (16 - 7.5, -64, False, CREAM), (-8, 1 + 4.5, True, PINKW), (149 - 4.5, 40, False, GOLD)]
    for x, y, ax, mat in cars:
        fg = sbox(x - 2.3, y - 2.3, x + 2.3, y + 2.3)
        if on_screen(fg, 6):
            objs.append(dict(kind="car", foot=fg, x=x, y=y, along_x=ax, mat=mat, h=5))

    # ---- pieces in painter's order ------------------------------------------
    for o in depth_sort(objs):
        if o["kind"] == "piece":
            draw_piece(dr, img, P, o)
        elif o["kind"] == "tree":
            tree_at(img, P, o["x"], o["y"], 0, o["cone"])
        elif o["kind"] == "car":
            draw_car(dr, P, o)

    # ---- world overlays: price tags, coin pops, upgrade bubble --------------
    for o in objs:
        if o["kind"] != "piece":
            continue
        i = o["plot"]["idx"]
        c = o["foot"].centroid
        if i in tags and not (i == 169 and 170 in [q["plot"]["idx"] for q in objs if q["kind"] == "piece" and q["role"].get("upgrading")]):
            x, y = P(c.x, c.y, o.get("top_z", obj_height(o)))
            price_tag(img, dr, x, y - 3, tags[i])
        if o["role"].get("upgrading"):
            x, y = P(c.x, c.y, o.get("top_z", 40))
            progress_bubble(img, dr, x + 6, y - 3, 0.62, "2:41")
    pops = {173: "+210", 182: "+480", 94: "+88"}
    for o in objs:
        if o["kind"] == "piece" and o["plot"]["idx"] in pops:
            c = o["foot"].centroid
            x, y = P(c.x, c.y, o.get("top_z", 40))
            coin_pop(img, dr, x - 2, y - 12, pops[o["plot"]["idx"]])

    draw_hud(img)
    return img


def draw_hud(img):
    dr = ImageDraw.Draw(img)
    W, H = img.size
    # money card
    money = "1.284.300"
    mw = bold_width(money, BIG)
    card(dr, 4, 4, 4 + 16 + mw + 6, 22, WHITE, edge=hx("#e8dcc4"))
    blit(img, COIN9, 8, 9, COIN_MAP)
    draw_text(img, 20, 10, money, BIG, INK, bold=True)
    # income pill
    inc = "+7.560/MIN"
    iw = text_width(inc, BIG)
    x0 = 4 + 16 + mw + 6 + 5
    card(dr, x0, 7, x0 + iw + 7, 20, LEAF[1], edge=LEAF[2])
    draw_text(img, x0 + 4, 10, inc, BIG, WHITE, shadow=(0, 1, LEAF[3]))
    # owned counter (top right): house icon + count
    card(dr, W - 38, 4, W - 5, 22, WHITE, edge=hx("#e8dcc4"))
    blit(img, HOUSE_ICON, W - 34, 9, {"w": RED[0], "r": WHITE})
    draw_text(img, W - 22, 10, "7", BIG, INK, bold=True)
    draw_text(img, W - 14, 12, "/9", SMALL, INK2)
    # bottom buttons
    by0, by1 = 266, 284
    card(dr, 4, by0, 80, by1, LEAF[1], edge=LEAF[3])
    ax, ay = 9, by0 + 5
    dr.polygon([(ax + 3, ay), (ax + 7, ay + 4), (ax + 5, ay + 4), (ax + 5, ay + 8), (ax + 1, ay + 8), (ax + 1, ay + 4),
                (ax - 1, ay + 4)], fill=WHITE, outline=INK)
    draw_text(img, 21, by0 + 6, "MEJORAR", BIG, WHITE, shadow=(0, 1, LEAF[3]))
    card(dr, 85, by0, 172, by1, GOLD[0], edge=GOLD[2])
    draw_text(img, 90, by0 + 6, "COMPRAR", BIG, INK)
    blit(img, COIN5, 139, by0 + 7, COIN_MAP)
    draw_text(img, 146, by0 + 7, "8K", SMALL, INK)
    # small square button: re-centre on office
    card(dr, 177, by0, 195, by1, WHITE, edge=hx("#e8dcc4"))
    blit(img, HOUSE_ICON, 182, by0 + 5, {"w": GOLD[0], "r": RED[1]})
    # OSM credit
    credit = "© OPENSTREETMAP CONTRIBUTORS"
    cw = text_width(credit, SMALL)
    dr.rectangle([W - cw - 6, H - 9, W - 2, H - 2], fill=WHITE)
    draw_text(img, W - cw - 4, H - 8, credit, SMALL, INK2)
    # window frame
    dr.rectangle([0, 0, W - 1, H - 1], outline=INK)


# ------------------------------------------------------------------ tiers strip
def render_tiers():
    names = ["SOLAR", "CASA", "MANSION", "BLOQUE", "TORRE", "RASCACIELOS"]
    PW, PH = 110, 210
    W, H = PW * 6 + 8, PH
    img = Image.new("RGB", (W, H), INK)
    # tabletop: dotted felt
    px = img.load()
    felt, dot = hx("#2a2350"), hx("#332b60")
    for y in range(H):
        for x in range(W):
            px[x, y] = dot if (x % 6 == 0 and y % 6 == 0) or ((x + 3) % 6 == 0 and (y + 3) % 6 == 0) else felt
    dr = ImageDraw.Draw(img)
    foot = Polygon([(0, 0), (18, 0), (18, 20), (0, 20)])
    plot = dict(id="tierplot", cat="residential", levels=6, idx=-1, geom=foot)
    for t in range(6):
        cx = 4 + PW * t + PW // 2
        # world (8,10) -> panel centre bottom area
        gy = PH - 52
        P = Proj(cx - (9 + 10) * S, gy - (9 - 10) * S / 2)
        # board tile with thickness (tabletop slab)
        tile = Polygon([(-4, -4), (22, -4), (22, 24), (-4, 24)])
        tp = [P(x, y) for x, y in poly_pts(tile)]
        for dz in range(4, 0, -1):
            pass
        side_l = [P(-4, -4), P(22, -4), P(22, -4, -5), P(-4, -4, -5)]
        side_r = [P(22, -4), P(22, 24), P(22, 24, -5), P(22, -4, -5)]
        dr.polygon(side_l, fill=BOARD_B, outline=INK)
        dr.polygon(side_r, fill=hx("#c9ad7c"), outline=INK)
        dr.polygon(tp, fill=BOARD_A, outline=INK)
        # checker squares on the tile
        for i in range(-4, 22, 4):
            for j in range(-4, 24, 4):
                if ((i // 4) + (j // 4)) % 2:
                    dr.polygon([P(i, j), P(i + 4, j), P(i + 4, j + 4), P(i, j + 4)], fill=BOARD_B)
        dr.polygon(tp, outline=INK)
        if t == 0:
            gi = inset(foot, 0.5)
            dr.polygon([P(x, y) for x, y in poly_pts(gi)], fill=DIRT, outline=DIRT2)
            for k in range(25):
                x, y = 1 + h01(k, "dx") * 16, 1 + h01(k, "dy") * 18
                dr.point(P(x, y), fill=DIRT2)
        role = dict(owner="me" if t > 0 else None, tier=t)
        o = piece_for_plot(plot, role)
        o["levels"] = 6
        if t > 0:
            o["shop"] = {"kind": "res", "awning": None}
        draw_piece(dr, img, P, o)
        if t == 0:
            c = foot.centroid
            x, y = P(c.x, c.y, 16)
            price_tag(img, dr, x, y - 2, "8K")
        # label card
        lab = names[t]
        lw = text_width(lab, SMALL)
        ly = PH - 24
        card(dr, cx - 34, ly, cx + 34, ly + 18, WHITE, edge=hx("#e8dcc4"))
        # tier pips
        for k in range(6):
            col = (RED[1] if k <= t else hx("#e8dcc4"))
            dr.rectangle([cx - 20 + k * 7, ly + 3, cx - 20 + k * 7 + 4, ly + 6], fill=col, outline=INK)
        draw_text(img, cx - lw // 2, ly + 10, lab, SMALL, INK)
    return img


def main():
    os.makedirs(OUT, exist_ok=True)
    city = render_city()
    big = city.resize((600, 600), Image.NEAREST)
    big.save(os.path.join(OUT, "city_600.png"))
    tiers = render_tiers()
    tiers.resize((tiers.width * 3, tiers.height * 3), Image.NEAREST).save(os.path.join(OUT, "tiers.png"))
    # close-up: 150x150 low-res crop around the office -> x4 total (2x of the 600 view)
    cx, cy, cw = 50, 40, 150
    crop = city.crop((cx, cy, cx + cw, cy + cw))
    crop.resize((cw * 4, cw * 4), Image.NEAREST).save(os.path.join(OUT, "closeup_2x.png"))
    cols = np.unique(np.array(city).reshape(-1, 3), axis=0)
    print("ok; colours in city frame:", len(cols))


if __name__ == "__main__":
    main()
