"""Tiny Realtor - style mockup A: "sibling of Tiny Battlegrounds".

Everything is procedural maths: an OSM-shaped block (block_saved.json) is clipped to a square
diorama, extruded into isometric buildings with a pixel-space facade "shader", lit from the
upper left, outlined like sprites, then the HUD is drawn on the same low-res grid and the whole
frame is quantised to one fixed palette and upscaled x2 with nearest neighbour.

usage: python3 gen_battlegrounds.py            -> city_600.png, tiers.png, closeup_2x.png
"""
import json, math, hashlib, os
import numpy as np
from PIL import Image, ImageDraw, ImageFont
from shapely.geometry import Polygon, LineString, Point, box
from shapely.ops import unary_union

HERE = os.path.dirname(os.path.abspath(__file__))
SCR = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(SCR, "realestate", "data", "block_saved.json")
FONTS = "/home/user/DesktopBattleground/fonts"
F12 = ImageFont.truetype(os.path.join(FONTS, "tiny12_bold.ttf"), 12)
F16 = ImageFont.truetype(os.path.join(FONTS, "tiny12_bold.ttf"), 16)
FN = ImageFont.truetype(os.path.join(FONTS, "tiny_narrow_bold.ttf"), 12)
F10 = ImageFont.truetype(os.path.join(FONTS, "tiny10_bold.ttf"), 10)

# ------------------------------------------------------------------------------------------
# palette: UI slate + accents are lifted from Tiny Battlegrounds, the city ramps are new
# ------------------------------------------------------------------------------------------
HEX = {
    # UI / ink (Battlegrounds)
    "INK": "#0b0e14", "SL0": "#12151b", "SL1": "#1d232d", "SL2": "#2c3543", "SL3": "#45546e",
    "SL4": "#7d8fa6", "SL5": "#c3cdd8", "CREAM": "#f0e6d2",
    "GOLD": "#ffc94a", "GOLD_M": "#c99e3a", "GOLD_D": "#3d3012",
    "CYAN": "#3fe0ff", "CYAN_M": "#1fa3c4", "CYAN_D": "#16607e", "CYAN_DD": "#0f2f40",
    "MINT": "#62f08a", "GRN_M": "#2b693c", "GRN_D": "#09160c",
    "RED": "#ca473b", "RED_M": "#6f2720", "RED_D": "#2a0d0b",
    # ground
    "PAVE_L": "#efe2c2", "PAVE": "#dccaa3", "PAVE_D": "#c4ae88", "PAVE_S": "#9a8b84",
    "ASPH_L": "#5c6377", "ASPH": "#4a5063", "ASPH_S": "#363b4b",
    "GRASS_L": "#a8d468", "GRASS": "#74b04c", "GRASS_D": "#4b8743", "GRASS_DD": "#2f5c3c",
    "DIRT_L": "#d6a86c", "DIRT": "#b4814f", "DIRT_D": "#85593b", "TRUNK": "#5a3829",
    # facades  (hi, lit, mid, dark)
    "CRM0": "#fbf1da", "CRM1": "#eed8ae", "CRM2": "#c9a98a", "CRM3": "#987b73",
    "OCH0": "#f8d495", "OCH1": "#e5b26d", "OCH2": "#b98657", "OCH3": "#875f50",
    "SAL0": "#f6bc9c", "SAL1": "#e19676", "SAL2": "#b26b5e", "SAL3": "#7f4f52",
    "STN0": "#ece6dc", "STN1": "#d2cabf", "STN2": "#a69ea0", "STN3": "#767287",
    # roofs
    "TER0": "#eab38c", "TER1": "#d4906b", "TER2": "#ad6c58", "TER3": "#7a4a48",
    "TIL0": "#e57f57", "TIL1": "#c75f40", "TIL2": "#9b4636", "TIL3": "#6a3234",
    "TEAL0": "#9cf0f4", "TEAL1": "#4ec6dc", "TEAL2": "#2c8db0", "TEAL3": "#1d5b7e",
    # glass / concrete
    "GLS0": "#c4ecf4", "GLS1": "#7ab8d8", "GLS2": "#4b7aaa", "GLS3": "#2c4a72",
    "CON0": "#f4f2ec", "CON1": "#d8dadb", "CON2": "#a5abb8", "CON3": "#727b8f",
    "WOOD": "#8c5a3c", "SKIN": "#ecb48c",
}
C = {k: tuple(int(v[i:i + 2], 16) for i in (1, 3, 5)) for k, v in HEX.items()}
PAL_NAMES = list(HEX.keys())
PAL_ARR = np.array([C[k] for k in PAL_NAMES], dtype=np.int32)

def ramp(prefix): return [C[prefix + str(i)] for i in range(4)]
R_CRM, R_OCH, R_SAL, R_STN = ramp("CRM"), ramp("OCH"), ramp("SAL"), ramp("STN")
R_TER, R_TIL, R_TEAL, R_GLS, R_CON = ramp("TER"), ramp("TIL"), ramp("TEAL"), ramp("GLS"), ramp("CON")
FACADES = [R_CRM, R_OCH, R_SAL, R_STN, R_CRM, R_OCH]

def h01(*parts):
    return int(hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:8], 16) / 2 ** 32

# light comes from the upper left of the screen: +v walls lit, +u walls in shade
LIGHT = np.array([-1.0, 0.55, 1.25]); LIGHT /= np.linalg.norm(LIGHT)
VIEW = np.array([1.0, 1.0, 1.0])

def shade_idx(n):
    d = float(np.dot(n, LIGHT))
    if d > 0.6: return 0
    if d > 0.12: return 1
    if d > -0.42: return 2
    return 3

# ------------------------------------------------------------------------------------------
# camera: ground metres (x east, y north) -> screen px.  z is already in screen pixels.
# ------------------------------------------------------------------------------------------
class Cam:
    def __init__(self, s, cx, cy, ox, oy):
        self.s, self.cx, self.cy, self.ox, self.oy = s, cx, cy, ox, oy
    def uv(self, x, y): return x - self.cx, -(y - self.cy)
    def P(self, x, y, z=0.0):
        u, v = x - self.cx, -(y - self.cy)
        return ((u - v) * self.s + self.ox, (u + v) * self.s * 0.5 - z + self.oy)
    def Pi(self, x, y, z=0.0):
        X, Y = self.P(x, y, z); return (int(math.floor(X + 0.5)), int(math.floor(Y + 0.5)))
    def ground(self, X, Y):       # inverse at z=0 (arrays ok)
        a = (X - self.ox) / self.s; b = 2 * (Y - self.oy) / self.s
        u = (a + b) / 2; v = (b - a) / 2
        return u + self.cx, -v + self.cy

def ccw_uv(poly):
    pts = [(x, -y) for x, y in poly]
    a = sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(pts, pts[1:] + pts[:1]))
    return poly if a > 0 else poly[::-1]

def clean(poly):
    if isinstance(poly, Polygon): poly = list(poly.exterior.coords)[:-1]
    return ccw_uv([tuple(p) for p in poly])

# ------------------------------------------------------------------------------------------
# facade "shaders": f(i, r, n, h, k) -> colour.  i = pixel column along the wall,
# r = pixel row above the wall base, n/h = wall size in px, k = light index 1..3
# ------------------------------------------------------------------------------------------
def win_glass(k, top, lit):
    if lit: return C["GOLD"] if top else C["GOLD_M"]
    if k == 1: return C["SL4"] if top else C["SL2"]
    return C["SL3"] if (top and k == 2) else C["SL1"]

def style_apartment(rp, seed, ground=6, fpx=4, awn=None):
    awn = awn or [C["RED"], C["CYAN_M"], C["GRASS_D"], C["GOLD_M"]][int(h01(seed, "awn") * 4)]
    def f(i, r, n, h, k, wid):
        wall = rp[k]; dk = rp[min(3, k + 1)]
        if r >= h - 1: return rp[max(0, k - 1)]              # cornice catches the light
        if r == h - 2: return dk                              # shadow under the cornice
        if r < ground:                                        # shop fronts + awnings
            b = (i + 1) % 6
            if r == ground - 1: return dk
            if 1 <= b <= 4:
                if r == ground - 2: return awn if k == 1 else tuple(int(c * .78) for c in awn)
                if r == 0: return C["SL1"]
                return C["SL3"] if (r == ground - 3 and b == 1 and k == 1) else C["SL2"]
            return wall
        fr = (r - ground) % fpx; fl = (r - ground) // fpx
        b = (i + 1) % 4
        if b in (1, 2):
            if fr == 0: return C["INK"] if k > 1 else C["SL2"]   # balcony railing
            if fr in (1, 2):
                hh = h01(seed, wid, fl, i // 4)
                if hh < 0.22 and fr == 2: return C["GRASS_D"] if k == 1 else C["GRASS_DD"]  # persiana
                return win_glass(k, fr == 2 and b == 1, hh > 0.93)
        if fr == 0 and b in (0, 3): return dk                 # balcony slab shadow
        return wall
    return f

def style_office(rp, seed):
    def f(i, r, n, h, k, wid):
        wall = rp[k]; dk = rp[min(3, k + 1)]
        if r >= h - 1: return rp[0]
        if r == h - 2: return dk
        if r < 7:                                             # big cyan shop front
            if r == 6: return C["CREAM"] if (i // 2) % 2 == 0 else C["CYAN_M"]   # striped awning
            if r == 5: return C["CYAN_D"] if (i // 2) % 2 else C["CRM3"]
            b = i % 5
            if b == 0: return dk
            if r == 0: return C["CYAN_DD"]
            return C["CYAN"] if (r == 4 and b == 1) or (b + r) % 7 == 0 else C["CYAN_M"] if k == 1 else C["CYAN_D"]
        fr = (r - 7) % 5
        b = i % 4
        if b in (1, 2) and fr in (1, 2, 3):
            if fr == 3 and b == 2 and False: return wall
            return win_glass(k, fr == 3, h01(seed, i // 4, (r - 7) // 5) > 0.8)
        if fr == 0 and b in (1, 2): return rp[0] if k == 1 else rp[k - 1]  # stone sills
        return wall
    return f

def style_house(rp, seed, ground_door=True):
    def f(i, r, n, h, k, wid):
        wall = rp[k]; dk = rp[min(3, k + 1)]
        if r == 0: return dk
        fr = r % 5; fl = r // 5
        b = (i + 2) % 5
        if fl == 0 and ground_door and wid == 0 and abs(i - n // 2) <= 0 and 1 <= r <= 3:
            return C["WOOD"]
        if fr in (2, 3) and b in (2, 3): return win_glass(k, fr == 3 and b == 2, False)
        if fr in (2, 3) and b in (1, 4): return C["GRASS_D"] if k == 1 else C["GRASS_DD"]
        return wall
    return f

def style_tower(rp, seed, ground=5):
    def f(i, r, n, h, k, wid):
        con = rp[k]
        if r >= h - 2: return rp[max(0, k - 1)]
        if r < ground:
            if r == ground - 1: return con
            if i % 5 == 0: return rp[min(3, k + 1)]
            return C["SL1"] if r == 0 else (C["GLS1"] if k == 1 else C["GLS2"]) if r == 3 else (C["GLS2"] if k == 1 else C["GLS3"])
        fr = (r - ground) % 3
        if fr == 0: return con
        if i % 5 == 0: return rp[min(3, k + 1)]
        refl = (i + r) % 13 < 2
        g = R_GLS[k] if not refl else R_GLS[max(0, k - 1)]
        if fr == 2 and k == 1 and not refl: return R_GLS[1]
        return g if fr == 2 else R_GLS[min(3, k + 1)] if not refl else g
    return f

def style_sky(seed, ground=6, crown=None):
    def f(i, r, n, h, k, wid):
        if crown and r >= h - crown:
            return [C["GOLD"], C["GOLD"], C["GOLD_M"], C["GOLD_D"]][k] if r == h - 1 or r == h - crown else [C["GOLD_M"], C["GOLD_M"], C["GOLD_D"], C["INK"]][k]
        if r < ground:
            if r == ground - 1: return [C["GOLD"], C["GOLD"], C["GOLD_M"], C["GOLD_D"]][k]
            if i % 6 == 0: return C["CON2"] if k == 1 else C["CON3"]
            return C["SL1"] if r == 0 else (C["GLS1"] if (k == 1 and r == ground - 2) else C["GLS3"] if k == 3 else C["GLS2"])
        rr = r - ground
        g = R_GLS[k]
        refl = ((i * 2 + rr) % 29) < 4
        if refl: g = R_GLS[max(0, k - 1)]
        if i % 3 == 0 or rr % 3 == 0:
            return R_GLS[min(3, k + 1)] if not refl else R_GLS[k]
        return g
    return f

def style_plain(rp, door=False):
    def f(i, r, n, h, k, wid):
        if r >= h: return rp[max(0, k - 1)]
        if door and wid == 0 and i == n // 2 and r in (0, 1, 2): return C["SL2"]
        return rp[k]
    return f

def style_skeleton(seed, start_r):
    """unfinished floors: concrete frame you can see through, plus scaffolding"""
    def f(i, r, n, h, k, wid):
        if r >= h: return None
        col = i % 5 == 0 or i == n - 1
        slab = r % 4 == 0
        if slab: return R_CON[k]
        if col: return R_CON[min(3, k + 1)]
        return None
    return f

# ------------------------------------------------------------------------------------------
# primitives
# ------------------------------------------------------------------------------------------
class Layer:
    def __init__(self, W, H):
        self.img = Image.new("RGBA", (W, H), (0, 0, 0, 0)); self.px = self.img.load()
        self.dr = ImageDraw.Draw(self.img); self.W, self.H = W, H
    def put(self, X, Y, c):
        if c is not None and 0 <= X < self.W and 0 <= Y < self.H:
            self.px[X, Y] = c + (255,) if len(c) == 3 else c
    def poly(self, pts, c):
        self.dr.polygon([(int(math.floor(x + .5)), int(math.floor(y + .5))) for x, y in pts], fill=c + (255,))

def wall_pixels(L, cam, a, b, z0, z1, fn, k, wid):
    Xa, Ya = cam.P(a[0], a[1], z0); Xb, Yb = cam.P(b[0], b[1], z0)
    flip = Xb < Xa
    if flip: Xa, Ya, Xb, Yb = Xb, Yb, Xa, Ya
    xs, xe = int(math.floor(Xa + .5)), int(math.floor(Xb + .5))
    n = xe - xs
    if n <= 0: return
    h = int(round(z1 - z0))
    for i in range(n):
        t = (i + .5) / n
        yb = int(math.floor(Ya + (Yb - Ya) * t + .5))
        ii = n - 1 - i if flip else i
        for r in range(h + 1):
            L.put(xs + i, yb - r, fn(ii, r, n, h, k, wid))

def prism(L, cam, poly, z0, z1, wall_fn, roof_rp, roof_kind="flat", rim=True):
    """vertical walls (facade shader) + flat roof with a 1px parapet rim"""
    poly = clean(poly)
    walls = []
    for wi, (a, b) in enumerate(zip(poly, poly[1:] + poly[:1])):
        du, dv = b[0] - a[0], -(b[1] - a[1])
        nu, nv = dv, -du
        ln = math.hypot(nu, nv) or 1; nu, nv = nu / ln, nv / ln
        if nu + nv <= 1e-3: continue
        k = max(1, shade_idx(np.array([nu, nv, 0.0])))
        mid = ((a[0] + b[0]) / 2 - cam.cx) - ((a[1] + b[1]) / 2 - cam.cy)
        walls.append((mid, a, b, k, wi))
    walls.sort(key=lambda w: w[0])
    for j, (_, a, b, k, wi) in enumerate(walls):
        wall_pixels(L, cam, a, b, z0, z1, wall_fn, k, j if k == 1 else wi + 10)
    if roof_rp is None: return
    top = [cam.P(x, y, z1) for x, y in poly]
    L.poly(top, roof_rp[0] if not rim else roof_rp[0])
    if rim:
        inner = Polygon(poly).buffer(-0.9, join_style=2)
        if not inner.is_empty and inner.geom_type == "Polygon" and inner.area > 4:
            L.poly([cam.P(x, y, z1) for x, y in list(inner.exterior.coords)[:-1]], roof_rp[1])
            # the parapet's inner face on the far side is in shadow
            ip = clean(inner)
            for a, b in zip(ip, ip[1:] + ip[:1]):
                du, dv = b[0] - a[0], -(b[1] - a[1])
                if (dv + -du) < -1e-3:  # inner faces looking at the viewer (= far parapet)
                    pa, pb = cam.Pi(a[0], a[1], z1), cam.Pi(b[0], b[1], z1)
                    L.dr.line([(pa[0], pa[1] + 1), (pb[0], pb[1] + 1)], fill=roof_rp[2] + (255,))

def face3d(L, cam, pts3, rp, inside_pt, plain=None, bias=0):
    """generic planar face with back-face culling and lighting from its normal"""
    uvz = [np.array([x - cam.cx, -(y - cam.cy), z]) for x, y, z in pts3]
    n = np.cross(uvz[1] - uvz[0], uvz[2] - uvz[0])
    cen = sum(uvz) / len(uvz)
    ip = np.array([inside_pt[0] - cam.cx, -(inside_pt[1] - cam.cy), inside_pt[2]])
    if np.dot(n, cen - ip) < 0: n = -n
    if np.dot(n, VIEW) <= 1e-6: return
    n = n / np.linalg.norm(n)
    col = rp[min(3, shade_idx(n) + bias)] if plain is None else plain
    L.poly([cam.P(*p) for p in pts3], col)
    return n

def rect_frame(poly, shrink=1.0):
    """minimum rotated rectangle as A,B,C,D with A->B the long side"""
    r = Polygon(poly).minimum_rotated_rectangle
    if shrink != 1.0:
        c = r.centroid
        from shapely import affinity
        r = affinity.scale(r, shrink, shrink, origin=c)
    p = clean(r)
    if math.dist(p[0], p[1]) < math.dist(p[1], p[2]): p = p[1:] + p[:1]
    return p

def pitched(L, cam, rect, z0, z1, wall_rp, roof_rp, rh, hip=0.0, wall_fn=None, eave=0.6):
    A, B, Cc, D = rect
    prism(L, cam, rect, z0, z1, wall_fn or style_plain(wall_rp), None)
    mid = lambda p, q, t=.5: (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t)
    # eaves stick out a little
    cx = sum(p[0] for p in rect) / 4; cy = sum(p[1] for p in rect) / 4
    ex = lambda p: (p[0] + (p[0] - cx) * eave / 6, p[1] + (p[1] - cy) * eave / 6)
    A2, B2, C2, D2 = ex(A), ex(B), ex(Cc), ex(D)
    R1 = mid(A2, D2); R2 = mid(B2, C2)
    if hip:
        R1, R2 = mid(R1, R2, hip), mid(R1, R2, 1 - hip)
    zt = z1 + rh; inside = (cx, cy, z1 + rh * .3)
    faces = [[(*A2, z1), (*B2, z1), (*R2, zt), (*R1, zt)], [(*Cc[:2], z1) if False else (*C2, z1), (*D2, z1), (*R1, zt), (*R2, zt)],
             [(*B2, z1), (*C2, z1), (*R2, zt)], [(*D2, z1), (*A2, z1), (*R1, zt)]]
    faces.sort(key=lambda f: sum((p[0] - cam.cx) - (p[1] - cam.cy) for p in f) / len(f))
    for fpts in faces:
        is_gable = (not hip) and len(fpts) == 3
        if is_gable:
            # gable end = wall plane, painted with the facade ramp
            n = face3d(L, cam, fpts, wall_rp, inside)
        else:
            n = face3d(L, cam, fpts, roof_rp, inside, bias=1)
            if n is not None:   # tile courses: darker lines parallel to the eave
                idx = min(3, shade_idx(n) + 2)
                lerp = lambda p, q, t: (p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t, p[2] + (q[2] - p[2]) * t)
                if len(fpts) == 4: e0, e1, t0, t1 = fpts[0], fpts[1], fpts[3], fpts[2]
                else: e0, e1, t0, t1 = fpts[0], fpts[1], fpts[2], fpts[2]
                nc = max(2, int((zt - z1) / 2.5))
                for j in range(1, nc):
                    t = j / nc
                    a3, b3 = lerp(e0, t0, t), lerp(e1, t1, t)
                    L.dr.line([cam.Pi(*a3), cam.Pi(*b3)], fill=roof_rp[idx] + (255,))
                L.dr.line([cam.Pi(*e0), cam.Pi(*e1)], fill=roof_rp[3] + (255,))
    # ridge highlight
    a, b = cam.Pi(*R1, zt), cam.Pi(*R2, zt)
    L.dr.line([a, b], fill=roof_rp[0] + (255,))
    return R1, R2, zt

# ------------------------------------------------------------------------------------------
# sprites
# ------------------------------------------------------------------------------------------
def tree(L, X, Y, seed, big=False):
    r = 4 if big else 3
    L.put(X, Y, C["TRUNK"]); L.put(X, Y - 1, C["TRUNK"]); L.put(X, Y - 2, C["TRUNK"])
    cx, cy = X, Y - 2 - r
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            d2 = dx * dx + dy * dy
            if d2 > r * r + r * .8: continue
            c = C["GRASS_D"]
            if dx + dy <= -r * .5: c = C["GRASS"]
            if dx + dy <= -r * 1.2 and d2 < r * r: c = C["GRASS_L"]
            if dx + dy >= r * .9: c = C["GRASS_DD"]
            if h01(seed, dx, dy) < .12 and c == C["GRASS_D"]: c = C["GRASS"]
            L.put(cx + dx, cy + dy, c)

def flag(L, X, Y, h=7, col=None):
    for k in range(h): L.put(X, Y - k, C["SL1"])
    L.put(X, Y - h, C["GOLD"])
    c1, c2 = (C["CYAN"], C["CYAN_M"]) if col is None else col
    for dx in range(1, 5):
        for dy in range(0, 3 if dx < 4 else 2):
            L.put(X + dx, Y - h + 1 + dy + (1 if dx == 4 else 0) - (0), c1 if dy < 2 - (dx == 4) else c2)

def sale_sign(L, X, Y):
    for k in range(6): L.put(X, Y - k, C["WOOD"])
    L.put(X + 1, Y, C["TRUNK"])
    for dx in range(-4, 5):
        for dy in range(-12, -5):
            edge = dy in (-12, -6) or dx in (-4, 4)
            L.put(X + dx, Y + dy, C["RED_M"] if edge else C["RED"])
    for j, row in enumerate(["011", "110", "010", "011", "110"][:5]):
        pass
    glyph = ["010", "111", "100", "111", "001", "111", "010"][1:6]
    for j, row in enumerate(["111", "100", "111", "001", "111"]):
        for i, ch in enumerate(row):
            if ch == "1": L.put(X - 1 + i, Y - 11 + j, C["CREAM"])
    L.put(X, Y - 12, C["CREAM"]); L.put(X, Y - 6, C["CREAM"])

# ------------------------------------------------------------------------------------------
# buildings by tier.  Every builder returns a draw callback + extras.
# ------------------------------------------------------------------------------------------
TIER_NAMES = ["LOT", "HOUSE", "ESTATE", "APARTMENTS", "TOWER", "SKYSCRAPER"]

def build_tier(poly, tier, seed, owned, levels=7, facade=None, extra=None):
    """returns dict(kind, draw(L, cam), ground(G, cam), anchor(x,y), top_z)"""
    extra = extra or {}
    g = Polygon(poly)
    facade = facade or FACADES[int(h01(seed, "fac") * len(FACADES))]
    roof_rp = R_TEAL if owned else R_TER
    info = {"poly": poly, "tier": tier, "owned": owned, "seed": seed}
    c = g.centroid

    if tier == 0:
        def ground(G, cam):
            G.poly([cam.P(x, y) for x, y in clean(poly)], C["DIRT"])
            inner = g.buffer(-1.0, join_style=2)
            for x, y in clean(inner):
                pass
            pts = clean(poly)
            # fence posts along the edges facing the street
            for a, b in zip(pts, pts[1:] + pts[:1]):
                L_ = math.dist(a, b); m = int(L_ / 2.5)
                for j in range(m + 1):
                    t = j / max(1, m); x = a[0] + (b[0] - a[0]) * t; y = a[1] + (b[1] - a[1]) * t
                    X, Y = cam.Pi(x, y); G.put(X, Y, C["DIRT_D"])
            for j in range(14):   # dirt clods and grass tufts (flat, no outline)
                px_ = c.x + (h01(seed, j, "x") - .5) * 16; py_ = c.y + (h01(seed, j, "y") - .5) * 16
                if not g.buffer(-1.5).contains(Point(px_, py_)): continue
                tx, ty = cam.Pi(px_, py_)
                if j % 3 == 0:
                    G.put(tx, ty, C["GRASS"]); G.put(tx - 1, ty, C["GRASS_D"]); G.put(tx, ty - 1, C["GRASS_L"]); G.put(tx + 1, ty, C["GRASS_D"])
                else:
                    G.put(tx, ty, C["DIRT_L"]); G.put(tx + 1, ty, C["DIRT_D"])
        def draw(L, cam):
            X, Y = cam.Pi(c.x, c.y)
            q = clean(poly)
            fr = max(q, key=lambda p: p[0] + p[1])        # corner that faces the crossing
            sx_, sy_ = c.x + (fr[0] - c.x) * .5, c.y + (fr[1] - c.y) * .5
            sale_sign(L, *cam.Pi(sx_, sy_))
        info.update(kind="lot", draw=draw, ground=ground, top_z=10, center=(c.x, c.y))
        return info

    if tier in (1, 2):
        rect = rect_frame(g.buffer(-2.5 if tier == 1 else -1.5, join_style=2).exterior.coords[:-1],
                          0.6 if tier == 1 else 0.74)
        sh_ = (-2.2, 2.6) if tier == 2 else (-1.2, 1.6)          # push the house to the back of the plot
        rect = [(x + sh_[0], y + sh_[1]) for x, y in rect]
        floors = 2 if tier == 1 else 3
        hz = floors * 5 + 1
        rr = R_TEAL if owned else R_TIL
        pool = None
        if tier == 2:
            A, B, Cc, D = rect
            # pool in the leftover garden in front of the villa
            pool = None
        def ground(G, cam):
            G.poly([cam.P(x, y) for x, y in clean(poly)], C["GRASS"])
            pts = clean(g.buffer(-0.6, join_style=2))
            for a, b in zip(pts, pts[1:] + pts[:1]):   # low hedge border
                G.dr.line([cam.Pi(*a), cam.Pi(*b)], fill=C["GRASS_DD"] + (255,))
            if tier == 2:
                rb = Polygon(rect).buffer(0.1)
                cand = g.buffer(-1.6, join_style=2).difference(Polygon(rect).buffer(1.4, join_style=2))
                mnx, mny, mxx, mxy = g.bounds
                pool_box = box(mnx + 3.2, mny + 1.9, mnx + 12.5, mny + 5.0)
                if cand.contains(pool_box): cand = pool_box.buffer(0.7, join_style=2)
                if not cand.is_empty:
                    big = max(getattr(cand, "geoms", [cand]), key=lambda q: q.area)
                    pr = big.minimum_rotated_rectangle
                    from shapely import affinity
                    if pr.area > 60: pr = affinity.scale(pr, .8, .8)
                    G.poly([cam.P(x, y) for x, y in clean(pr)], C["CREAM"])
                    pr2 = pr.buffer(-0.7, join_style=2)
                    if not pr2.is_empty:
                        G.poly([cam.P(x, y) for x, y in clean(pr2)], C["CYAN_M"])
                        pr3 = pr2.buffer(-0.6, join_style=2)
                        if not pr3.is_empty: G.poly([cam.P(x, y) for x, y in clean(pr3)], C["CYAN"])
            # garden path from the door
            A, B, Cc, D = rect
        def draw(L, cam):
            R1, R2, zt = pitched(L, cam, rect, 0, hz, facade, rr, 6 if tier == 1 else 8,
                                 hip=0.0 if tier == 1 else 0.28, wall_fn=style_house(facade, seed))
            # chimney
            ch = (R1[0] + (R2[0] - R1[0]) * .7 + 0.8, R1[1] + (R2[1] - R1[1]) * .7 + 0.8)
            cp = [(ch[0] - .7, ch[1] - .7), (ch[0] + .7, ch[1] - .7), (ch[0] + .7, ch[1] + .7), (ch[0] - .7, ch[1] + .7)]
            prism(L, cam, cp, zt - 3, zt + 2, style_plain(R_STN), R_STN, rim=False)
            if owned:
                fx, fy = cam.Pi(*R1, zt); flag(L, fx, fy)
        info.update(kind="house", draw=draw, ground=ground, top_z=hz + 8, center=(c.x, c.y))
        trees = []
        for j in range(3):
            px_ = c.x + (h01(seed, j, "tx") - .5) * 16; py_ = c.y + (h01(seed, j, "ty") - .5) * 16
            pt = Point(px_, py_)
            if g.buffer(-1.5).contains(pt) and not Polygon(rect).buffer(2.5).contains(pt):
                trees.append((px_, py_))
        info["trees"] = trees[:2]
        return info

    if tier == 3:
        hz = 6 + (levels - 1) * 4 + 2
        def draw(L, cam):
            prism(L, cam, poly, 0, hz, style_apartment(facade, seed), roof_rp)
            roof_props(L, cam, g, hz, seed, owned)
        info.update(kind="apt", draw=draw, ground=None, top_z=hz, center=(c.x, c.y))
        return info

    if tier == 4:
        base = g.buffer(-1.2, join_style=2)
        b2 = base.buffer(-2.2, join_style=2)
        hz = 5 + 18 * 3 + 2
        hz2 = hz + 7
        def ground(G, cam):
            G.poly([cam.P(x, y) for x, y in clean(poly)], C["PAVE_L"])
        def draw(L, cam):
            prism(L, cam, base, 0, hz, style_tower(R_CON, seed), R_CON if not owned else R_TEAL)
            if not b2.is_empty:
                prism(L, cam, b2, hz, hz2, style_tower(R_CON, seed + "u", ground=0), R_TEAL if owned else R_CON)
                roof_props(L, cam, b2, hz2, seed, owned, modern=True)
        info.update(kind="tower", draw=draw, ground=ground, top_z=hz2, center=(c.x, c.y))
        return info

    if tier == 5:
        b0 = g.buffer(-1.0, join_style=2)
        b1 = b0.buffer(-1.6, join_style=2)
        b2 = b1.buffer(-1.8, join_style=2)
        z0, z1, z2 = 6 + 26 * 3 + 3, 6 + 26 * 3 + 3 + 21, 6 + 26 * 3 + 3 + 21 + 12
        def ground(G, cam):
            G.poly([cam.P(x, y) for x, y in clean(poly)], C["PAVE_L"])
        def draw(L, cam):
            prism(L, cam, b0, 0, z0, style_sky(seed, crown=3), R_TEAL if owned else R_CON)
            prism(L, cam, b1, z0, z1, style_sky(seed, ground=0, crown=3), R_TEAL if owned else R_CON)
            prism(L, cam, b2, z1, z2, style_sky(seed, ground=0, crown=4), R_TEAL if owned else R_GLS)
            cc = b2.centroid; X, Y = cam.Pi(cc.x, cc.y, z2)
            for k in range(14): L.put(X, Y - k, C["SL5"] if k % 4 else C["SL3"])
            L.put(X, Y - 14, C["RED"]); L.put(X, Y - 15, C["RED"])
            if owned:
                q = clean(b2); fx, fy = cam.Pi(q[0][0], q[0][1], z2); fx2, fy2 = cam.Pi(*max(q, key=lambda p: -(p[0] - cam.cx) + (p[1] - cam.cy)), z2)
                flag(L, fx2 + 1, fy2 + 1, h=6)
        info.update(kind="sky", draw=draw, ground=ground, top_z=z2 + 16, center=(c.x, c.y))
        return info

def roof_props(L, cam, g, hz, seed, owned, modern=False):
    gi = g.buffer(-1.6, join_style=2)
    if gi.is_empty: return
    if gi.geom_type != "Polygon": gi = max(gi.geoms, key=lambda q: q.area)
    props = []
    cx, cy = gi.centroid.x, gi.centroid.y
    n = 1 + int(h01(seed, "np") * 2) + (1 if gi.area > 250 else 0)
    for k in range(n * 3):
        if len(props) >= n: break
        w = (3.2 if k % 3 == 0 else 1.8) if not modern else (2.4 if k % 2 == 0 else 1.6)
        x = cx + (h01(seed, k, "px") - .5) * math.sqrt(gi.area) * .9
        y = cy + (h01(seed, k, "py") - .5) * math.sqrt(gi.area) * .9
        bx = box(x - w / 2, y - w / 2, x + w / 2, y + w / 2)
        if gi.contains(bx) and not any(bx.buffer(.6).intersects(p[0]) for p in props):
            props.append((bx, w))
    props.sort(key=lambda p: (p[0].centroid.x - cam.cx) - (p[0].centroid.y - cam.cy))
    for bx, w in props:
        if w > 3:
            prism(L, cam, bx, hz, hz + 4, style_plain(R_CRM, door=True), R_STN, rim=False)
        elif modern:
            prism(L, cam, bx, hz, hz + 2, style_plain(R_CON), R_CON, rim=False)
        else:
            prism(L, cam, bx, hz, hz + 3, style_plain(R_STN), R_STN, rim=False)
    if owned:
        q = clean(gi)
        far = min(q, key=lambda p: (p[0] - cam.cx) - (p[1] - cam.cy))
        fx, fy = cam.Pi(far[0], far[1], hz)
        flag(L, fx, fy)

# ------------------------------------------------------------------------------------------
# outline + composite
# ------------------------------------------------------------------------------------------
def composite(scene, L, outline=True):
    a = np.array(L.img)
    m = a[..., 3] > 0
    if outline:
        d = m.copy()
        d[1:, :] |= m[:-1, :]; d[:-1, :] |= m[1:, :]; d[:, 1:] |= m[:, :-1]; d[:, :-1] |= m[:, 1:]
        o = d & ~m
        scene[o] = C["INK"]
    scene[m] = a[..., :3][m]

def quantize(arr):
    flat = arr.reshape(-1, 3).astype(np.int32)
    uniq, inv = np.unique(flat, axis=0, return_inverse=True)
    d = ((uniq[:, None, :] - PAL_ARR[None, :, :]) ** 2).sum(-1)
    return PAL_ARR[d.argmin(1)][inv.reshape(-1)].reshape(arr.shape).astype(np.uint8)

SHADOW_OF = {}
def shadow_color(c):
    if c not in SHADOW_OF:
        t = np.array([c[0] * .62, c[1] * .64, c[2] * .78])
        SHADOW_OF[c] = tuple(PAL_ARR[((PAL_ARR - t) ** 2).sum(1).argmin()])
    return SHADOW_OF[c]
SHADOW_FIX = {C["PAVE"]: C["PAVE_S"], C["PAVE_D"]: C["PAVE_S"], C["PAVE_L"]: C["PAVE_D"],
              C["ASPH"]: C["ASPH_S"], C["ASPH_L"]: C["ASPH"], C["GRASS"]: C["GRASS_D"],
              C["GRASS_L"]: C["GRASS"], C["GRASS_D"]: C["GRASS_DD"], C["CREAM"]: C["SL4"],
              C["DIRT"]: C["DIRT_D"], C["DIRT_L"]: C["DIRT"]}

DIM_OF = {}
DIM_FIX = {C["GRASS_L"]: C["GRASS_D"], C["GRASS"]: C["GRASS_DD"], C["GRASS_D"]: C["GRASS_DD"],
           C["GRASS_DD"]: C["SL2"]}
def dim_color(c):
    if c in DIM_FIX: return DIM_FIX[c]
    if c not in DIM_OF:
        lum = (c[0] * .3 + c[1] * .55 + c[2] * .15)
        t = np.array([c[0] * .42 + lum * .16 + 18, c[1] * .42 + lum * .16 + 22, c[2] * .46 + lum * .18 + 32])
        cand = PAL_ARR[[i for i, k in enumerate(PAL_NAMES) if k not in ("GOLD", "CYAN", "MINT", "TEAL0", "GOLD_M")]]
        DIM_OF[c] = tuple(int(v) for v in cand[((cand - t) ** 2).sum(1).argmin()])
    return DIM_OF[c]

FADE_OF = {}
def fade_color(c):
    """buildings outside the radius: desaturated and cooled, but still readable"""
    if c in DIM_FIX: return DIM_FIX[c]
    if c not in FADE_OF:
        lum = (c[0] * .3 + c[1] * .55 + c[2] * .15)
        t = np.array([c[0] * .30 + lum * .42 + 6, c[1] * .30 + lum * .42 + 12, c[2] * .32 + lum * .46 + 30])
        cand = PAL_ARR[[i for i, k in enumerate(PAL_NAMES) if k not in ("GOLD", "CYAN", "MINT", "TEAL0", "TEAL1", "GOLD_M", "RED", "GLS0", "GLS1")]]
        FADE_OF[c] = tuple(int(v) for v in cand[((cand - t) ** 2).sum(1).argmin()])
    return FADE_OF[c]

def dim_layer(L):
    a = np.array(L.img)
    m = a[..., 3] > 0
    ys, xs = np.nonzero(m)
    for y, x in zip(ys, xs):
        a[y, x, :3] = fade_color(tuple(int(v) for v in a[y, x, :3]))
    L.img = Image.fromarray(a)

def apply_shadow(scene, mask, dim=False):
    ys, xs = np.nonzero(mask)
    for y, x in zip(ys, xs):
        c = tuple(int(v) for v in scene[y, x])
        scene[y, x] = dim_color(c) if dim else (SHADOW_FIX.get(c) or shadow_color(c))

def shadow_poly(poly, h, sv=(0.33, 0.20)):
    g = Polygon(poly)
    dx, dy = sv[0] * h, sv[1] * h
    from shapely import affinity
    top = affinity.translate(g, dx, dy)
    parts = [g, top]
    pts = list(g.exterior.coords)
    for a, b in zip(pts, pts[1:]):
        q = Polygon([a, b, (b[0] + dx, b[1] + dy), (a[0] + dx, a[1] + dy)])
        if q.is_valid and q.area > 0: parts.append(q)
    return unary_union(parts)

# ------------------------------------------------------------------------------------------
# depth sort (painter's order for footprints in iso, viewer at +u,+v)
# ------------------------------------------------------------------------------------------
def depth_sort(objs, cam):
    n = len(objs)
    bbs = []
    for o in objs:
        us = [x - cam.cx for x, y in o["foot"]]; vs = [-(y - cam.cy) for x, y in o["foot"]]
        bbs.append((min(us), max(us), min(vs), max(vs)))
    after = [[] for _ in range(n)]; indeg = [0] * n; eps = 0.05
    for a in range(n):
        A = bbs[a]
        for b in range(a + 1, n):
            Bb = bbs[b]
            # only pairs whose screen x ranges overlap matter
            if A[1] - A[2] < Bb[0] - Bb[3] or Bb[1] - Bb[2] < A[0] - A[3]: continue
            if A[1] <= Bb[0] + eps and not (Bb[3] <= A[2] + eps): f, s = a, b
            elif Bb[1] <= A[0] + eps and not (A[3] <= Bb[2] + eps): f, s = b, a
            elif A[3] <= Bb[2] + eps: f, s = a, b
            elif Bb[3] <= A[2] + eps: f, s = b, a
            else:
                ca, cb = sum(A), sum(Bb)
                f, s = (a, b) if ca <= cb else (b, a)
            after[f].append(s); indeg[s] += 1
    import heapq
    key = lambda i: bbs[i][1] + bbs[i][3]
    ready = [(key(i), i) for i in range(n) if indeg[i] == 0]; heapq.heapify(ready); out = []
    while ready:
        _, i = heapq.heappop(ready); out.append(i)
        for j in after[i]:
            indeg[j] -= 1
            if indeg[j] == 0: heapq.heappush(ready, (key(j), j))
    if len(out) < n: out += sorted(set(range(n)) - set(out), key=key)
    return [objs[i] for i in out]

# ------------------------------------------------------------------------------------------
# tiny 3x5 font for the credit and tags
# ------------------------------------------------------------------------------------------
MICRO = {
 "A": "010101111101101", "B": "110101110101110", "C": "011100100100011", "D": "110101101101110",
 "E": "111100110100111", "F": "111100110100100", "G": "011100101101011", "H": "101101111101101",
 "I": "111010010010111", "J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
 "M": "101111111101101", "N": "110101101101101", "O": "010101101101010", "P": "110101110100100",
 "Q": "010101101110011", "R": "110101110101101", "S": "011100010001110", "T": "111010010010010",
 "U": "101101101101111", "V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
 "Y": "101101010010010", "Z": "111001010100111", "0": "111101101101111", "1": "010110010010111",
 "2": "110001010100111", "3": "110001010001110", "4": "101101111001001", "5": "111100110001110",
 "6": "011100111101111", "7": "111001010010010", "8": "111101111101111", "9": "111101111001110",
 "$": "011110010011110", "+": "000010111010000", "/": "001001010100100", ".": "000000000000010",
 ":": "000010000010000", "%": "101001010100101", "-": "000000111000000", " ": "000000000000000",
 "©": "011110100101101001100101011110", "x": "000101010101000",
}
def gw(ch): return 6 if ch == "©" else 3
def micro_w(s): return sum(gw(ch) + 1 for ch in s) - 1
def micro(L, x, y, s, col, outline=None):
    if outline is not None:
        for ox, oy in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1)):
            micro(L, x + ox, y + oy, s, outline)
    cx = x
    for ch in s:
        g = MICRO.get(ch, MICRO[" "]); w = gw(ch)
        for j in range(5 * w):
            if g[j] == "1": L.put(cx + j % w, y + j // w, col)
        cx += w + 1

def text(L, x, y, s, font, col, outline=C["INK"], anchor="la", shadow=True):
    d = L.dr
    if anchor == "ra":
        x -= int(d.textlength(s, font=font))
    d.fontmode = "1"
    if outline is not None:
        for ox, oy in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (1, 1), (-1, 1), (1, -1), (0, 2), (1, 2), (-1, 2)):
            if not shadow and oy == 2: continue
            d.text((x + ox, y + oy), s, font=font, fill=outline + (255,))
    d.text((x, y), s, font=font, fill=col + (255,))

# ------------------------------------------------------------------------------------------
# Battlegrounds-style framed panels (1px border + hollow corner studs)
# ------------------------------------------------------------------------------------------
def frame(L, x0, y0, x1, y1, border, fill=None, studs=True):
    if fill is not None:
        L.dr.rectangle([x0 + 1, y0 + 1, x1 - 1, y1 - 1], fill=fill + (255,))
    L.dr.rectangle([x0 + 1, y0 + 1, x1 - 1, y1 - 1], outline=border + (255,))
    if studs:
        for sx, sy in ((x0 - 1, y0 - 1), (x1 - 1, y0 - 1), (x0 - 1, y1 - 1), (x1 - 1, y1 - 1)):
            L.dr.rectangle([sx, sy, sx + 2, sy + 2], fill=C["INK"] + (255,))
            L.dr.rectangle([sx, sy, sx + 2, sy + 2], outline=border + (255,))

ICONS = {
 "house": [".....11.....", "....1111....", "...111111...", "..11111111..", ".1111111111.", "111111111111",
           ".1111111111.", ".111111..11.", ".111111..11.", ".111111..11.", ".111111..11."],
 "coin":  ["....11....", "..111111..", ".11.11.11.", ".11.11....", "..11111...", "...11111..", "....11.11.",
           ".11.11.11.", "..111111..", "....11...."],
 "up":    ["....11....", "...1111...", "..111111..", ".11111111.", "1111111111", "...1111...", "...1111...",
           "...1111...", "...1111...", "...1111..."],
 "gear":  ["....111....", ".1..111..1.", "..1111111..", "..11...11..", "1111...1111", "1111...1111", "1111...1111",
           "..11...11..", "..1111111..", ".1..111..1.", "....111...."],
}
def icon(L, x, y, name, col):
    for j, row in enumerate(ICONS[name]):
        for i, ch in enumerate(row):
            if ch == "1": L.put(x + i, y + j, col)

def coin_icon(L, x, y):
    pts = ["..111..", ".12221.", "1223221", "1232221", "1223221", ".12221.", "..111.."]
    cm = {"1": C["GOLD_M"], "2": C["GOLD"], "3": C["CREAM"]}
    for j, row in enumerate(pts):
        for i, ch in enumerate(row):
            if ch in cm: L.put(x + i, y + j, cm[ch])

def checker(W, H, sq=38, ox=0, oy=0):
    a = np.zeros((H, W, 3), np.uint8)
    yy, xx = np.mgrid[0:H, 0:W]
    m = (((xx + ox) // sq + (yy + oy) // sq) % 2) == 0
    a[m] = C["SL0"]; a[~m] = C["INK"]
    return a

# ------------------------------------------------------------------------------------------
# the city scene
# ------------------------------------------------------------------------------------------
B = json.load(open(DATA))

# scene direction: real Eixample crossing (Passeig de Gracia x Diputacio), office on the chamfer
XC, YC = 16.0, -132.4          # Passeig de Gracia x Diputacio crossing
CX, CY, HALF = -11.5, -110.5, 62.0   # diorama centred on the office
OFFICE = "w900021449"
SCENE = {   # plot id -> (tier, owned)
    OFFICE: ("office", True),
    "w900021970": (3, False), "w900022255": (3, True), "w900021958": (3, True),
    "w900021991": ("build", True),          # apartment block mid-upgrade -> tower
    "w900024335": (5, True),                # the skyscraper that outgrew the block
    "w900008841": (4, True),                # a tower
    "w900007584": (0, False),               # corner lot for sale
}
RADIUS = 58.0

def render_city():
    W = H = 300
    s = 1.19
    cam = Cam(s, CX, CY, 150, 163)
    region = box(CX - HALF, CY - HALF, CX + HALF, CY + HALF)
    scene = checker(W, H)
    # ---- island shadow + slab --------------------------------------------------------
    corners = [(CX - HALF, CY - HALF), (CX + HALF, CY - HALF), (CX + HALF, CY + HALF), (CX - HALF, CY + HALF)]
    G = Layer(W, H)
    dep = 12
    # ground layer -----------------------------------------------------------------------
    G.poly([cam.P(x, y) for x, y in corners], C["PAVE"])
    # blocks: hull of all plots per block quadrant, sidewalks = hull grown by 4.5 m
    quads = {}
    for p in B["plots"]:
        g = Polygon(p["poly"]); c = g.centroid
        if abs(c.x - XC) > 140 or abs(c.y - YC) > 140: continue
        q = (c.x > XC, c.y > YC)
        if abs(c.x - XC) > 132 or abs(c.y - YC) > 132: continue
        quads.setdefault(q, []).append(g)
    blocks = {q: unary_union(gs).convex_hull for q, gs in quads.items()}
    walks = unary_union([b.buffer(4.6, join_style=2) for b in blocks.values()])
    road = region.difference(walks)
    for gg in getattr(road, "geoms", [road]):
        G.poly([cam.P(x, y) for x, y in gg.exterior.coords], C["ASPH"])
        for hole in gg.interiors: G.poly([cam.P(x, y) for x, y in hole.coords], C["PAVE"])
    for q, b in blocks.items():           # courtyards are gardens
        bb = b.buffer(-0.01).intersection(region)
        for gg in getattr(bb, "geoms", [bb]):
            if gg.geom_type == "Polygon": G.poly([cam.P(x, y) for x, y in gg.exterior.coords], C["GRASS"])
    for gr in B["greens"]:
        gg = Polygon(gr["poly"]).intersection(region)
        if not gg.is_empty and gg.geom_type == "Polygon":
            G.poly([cam.P(x, y) for x, y in gg.exterior.coords], C["GRASS"])
    # texture pass (per pixel, in ground coordinates)
    ga = np.array(G.img)
    yy, xx = np.mgrid[0:H, 0:W]
    gx, gy = cam.ground(xx + .5, yy + .5)
    u = gx - CX; v = -(gy - CY)
    rgb = ga[..., :3]; al = ga[..., 3] > 0
    def is_(col): return al & np.all(rgb == C[col], axis=-1)
    pave = is_("PAVE"); asph = is_("ASPH"); grass = is_("GRASS")
    # panot tiles: soft diagonal lattice every 3 m
    tile = ((np.floor(u / 3) + np.floor(v / 3)) % 2 == 0) & (((u % 3) < .55) | ((v % 3) < .55))
    rgb[pave & tile] = C["PAVE_D"]
    hsh = (np.sin(xx * 12.9898 + yy * 78.233) * 43758.5453) % 1
    rgb[asph & (hsh < .05)] = C["ASPH_L"]
    rgb[asph & (hsh > .97)] = C["ASPH_S"]
    rgb[grass & (hsh < .07)] = C["GRASS_L"]
    rgb[grass & (hsh > .92)] = C["GRASS_D"]
    # curbs: sidewalk pixel right above asphalt -> bright kerb, asphalt below it -> shadow
    pv = pave | (np.all(rgb == C["PAVE_D"], axis=-1) & al)
    kerb = np.zeros_like(pv); kerb[:-1] = pv[:-1] & asph[1:]
    sh = np.zeros_like(pv); sh[1:] = asph[1:] & pv[:-1]
    rgb[kerb] = C["CREAM"]; rgb[sh] = C["ASPH_S"]
    ga[..., :3] = rgb
    G.img = Image.fromarray(ga).copy(); G.px = G.img.load(); G.dr = ImageDraw.Draw(G.img)
    # lane dashes and zebra crossings
    for r in B["roads"]:
        line = LineString(r["line"]).intersection(region)
        if line.is_empty: continue
        horiz = abs(r["line"][0][1] - r["line"][1][1]) < 5
        L_ = line.length; d = 0
        while d < L_:
            p0 = line.interpolate(d); p1 = line.interpolate(min(d + 3, L_))
            near = abs(p0.x - XC) < 22 and abs(p0.y - YC) < 22
            if not near and walks.distance(p0) > 2:
                G.dr.line([cam.Pi(p0.x, p0.y), cam.Pi(p1.x, p1.y)], fill=C["CREAM"] + (255,))
            d += 7
    for (ax, w_other, w_self) in (("x", 18, 30), ("y", 30, 18)):
        for sgn in (-1, 1):
            off = (w_other / 2 + 7.5) * sgn
            k = -w_self / 2 + 1.2
            while k < w_self / 2 - 1.2:
                if ax == "x":   # crossing over Passeig (road along y): stripes along y
                    q = [(XC + k, YC + off - 1.6), (XC + k + 1.1, YC + off - 1.6), (XC + k + 1.1, YC + off + 1.6), (XC + k, YC + off + 1.6)]
                else:
                    q = [(XC + off - 1.6, YC + k), (XC + off + 1.6, YC + k), (XC + off + 1.6, YC + k + 1.1), (XC + off - 1.6, YC + k + 1.1)]
                G.poly([cam.P(x, y) for x, y in q], C["CREAM"])
                k += 2.4
    # ---- objects ------------------------------------------------------------------------
    objs = []
    for p in B["plots"]:
        g = Polygon(p["poly"])
        if not g.intersects(region): continue
        gc = g.intersection(region)
        if gc.is_empty or gc.area < 20: continue
        if gc.geom_type != "Polygon": gc = max(gc.geoms, key=lambda q: q.area)
        gc = gc.simplify(0.05)
        poly = clean(gc)
        pid = p["id"]
        tier, owned = SCENE.get(pid, (3, False))
        lv = max(4, min(9, p["levels"] if p["levels"] > 1 else 2))
        if g.centroid.x > XC and g.centroid.y < YC: lv = 4      # keep the crossing in view
        if pid == "w900008427": lv = 3
        if p["levels"] <= 1:   # one storey courtyard sheds become the block's inner garden
            gg = Polygon(poly)
            for j in range(14):
                tx = gg.centroid.x + (h01(pid, j, "gx") - .5) * 40; ty = gg.centroid.y + (h01(pid, j, "gy") - .5) * 40
                if gg.buffer(-2.5).contains(Point(tx, ty)):
                    objs.append(tree_obj(tx, ty, pid + str(j)))
            continue
        if tier == "office":
            info = office(poly, pid)
        elif tier == "build":
            info = construction(poly, pid, lv)
        else:
            info = build_tier(poly, tier, pid, owned, levels=lv)
        info.update(foot=poly, pid=pid, h=info.get("top_z", 30))
        objs.append(info)
        for t in info.get("trees", []):
            objs.append(tree_obj(*t, pid))
    # street trees along sidewalks (plane trees), skipping the chamfers
    for q, b in blocks.items():
        ring = b.buffer(2.3, join_style=2).exterior
        L_ = ring.length; d = 3.0
        while d < L_:
            pt = ring.interpolate(d)
            if region.buffer(-2).contains(pt) and not (abs(pt.x - XC) < 24 and abs(pt.y - YC) < 24):
                objs.append(tree_obj(pt.x, pt.y, f"st{q}{d:.0f}"))
            d += 8.5
    # Passeig de Gracia style street lamps and a few people, only on the lit side of the radius
    oc0 = Polygon([p for p in B["plots"] if p["id"] == OFFICE][0]["poly"]).centroid
    for q, b in blocks.items():
        ring = b.buffer(3.4, join_style=2).exterior
        L_ = ring.length; d = 7.0
        while d < L_:
            pt = ring.interpolate(d)
            if region.buffer(-2).contains(pt) and pt.distance(oc0) < RADIUS - 4:
                objs.append(lamp_obj(pt.x, pt.y))
            d += 17
    peds = 0
    for j in range(80):
        if peds >= 16: break
        x = CX + (h01("ped", j, "x") - .5) * 110; y = CY + (h01("ped", j, "y") - .5) * 110
        pt = Point(x, y)
        if walks.contains(pt) and not unary_union(list(blocks.values())).buffer(0.8).contains(pt) and pt.distance(oc0) < RADIUS:
            objs.append(ped_obj(x, y, j)); peds += 1
    # cars
    cars = [(XC - 5, YC + 30, "y", -1, C["RED"]), (XC + 5, YC - 24, "y", 1, C["CREAM"]),
            (XC - 10.5, YC + 50, "y", -1, "taxi"), (XC + 10.5, YC + 12, "y", 1, C["CYAN_M"]),
            (XC - 38, YC + 3.8, "x", 1, "taxi"), (XC - 62, YC - 3.8, "x", 1, C["GOLD"]),
            (XC + 26, YC + 3.8, "x", 1, C["SL5"]), (XC - 4.5, YC - 33, "y", 1, "taxi")]
    for cx_, cy_, ax, dirn, col in cars:
        if region.buffer(-3).contains(Point(cx_, cy_)):
            objs.append(car_obj(cx_, cy_, ax, col))
    # ---- shadows on the ground ----------------------------------------------------------
    sm = Image.new("L", (W, H), 0); sd = ImageDraw.Draw(sm)
    for o in objs:
        hh = o.get("h", 0)
        if o["kind"] in ("lot", "lamp", "ped"): continue
        hh = min(hh, 40) if o["kind"] != "tree" else 5
        sp = shadow_poly(o["foot"] if o["kind"] != "tree" else [(o["pt"][0] - 1.4, o["pt"][1] - 1.4), (o["pt"][0] + 1.4, o["pt"][1] - 1.4), (o["pt"][0] + 1.4, o["pt"][1] + 1.4), (o["pt"][0] - 1.4, o["pt"][1] + 1.4)], hh)
        for gg in getattr(sp, "geoms", [sp]):
            sd.polygon([cam.Pi(x, y) for x, y in gg.exterior.coords], fill=255)
    gm = np.array(G.img)
    gmask = gm[..., 3] > 0
    slab_mask = np.array(sm) > 0
    # ground-level plot decorations (lots, gardens, plazas) go under the shadows
    for o in objs:
        if o.get("ground"): o["ground"](G, cam)
    # radius ring
    oc = Polygon([pp for pp in [p for p in B["plots"] if p["id"] == OFFICE][0]["poly"]]).centroid
    ring_px = []
    for k in range(1440):
        a = k / 1440 * 2 * math.pi
        x, y = oc.x + RADIUS * math.cos(a), oc.y + RADIUS * math.sin(a)
        if not region.contains(Point(x, y)): continue
        X, Y = cam.Pi(x, y)
        ring_px.append((X, Y, k))
    seen = set()
    for X, Y, k in ring_px:
        if (X, Y) in seen: continue
        seen.add((X, Y))
        if (k // 20) % 3 != 2:
            G.put(X, Y, C["GOLD"]); G.put(X, Y - 1, C["GOLD"]); G.put(X, Y + 1, C["GOLD_D"])
    gm = np.array(G.img)
    base = scene.copy()
    m = gm[..., 3] > 0
    base[m] = gm[..., :3][m]
    outside = np.hypot(gx - oc.x, gy - oc.y) > RADIUS
    ring = np.all(base == C["GOLD"], axis=-1) | np.all(base == C["GOLD_D"], axis=-1)
    apply_shadow(base, outside & m & ~ring, dim=True)
    apply_shadow(base, slab_mask & m & ~ring)
    scene = base
    # slab sides (earth cut) --------------------------------------------------------------
    S = Layer(W, H)
    x0, x1, y0, y1 = CX - HALF, CX + HALF, CY - HALF, CY + HALF
    def side_fn(i, r, n, h, k, wid):
        rr = h - r + 1
        if rr <= 0: return None
        lit = k == 1
        if rr == 1: return C["PAVE_L"] if lit else C["PAVE_D"]
        if rr == 2: return C["PAVE_D"] if lit else C["PAVE_S"]
        if r == 0: return C["INK"]
        if r == 1: return C["DIRT_D"] if lit else C["TRUNK"]
        st = h01("stone", i // 3, (r + (i // 3) % 2) // 3)
        if st < .16 and 3 < rr < h - 2:   # cobbles in the cut
            return C["DIRT_L"] if lit else C["DIRT"]
        if rr == 3: return C["DIRT_D"] if lit else C["TRUNK"]
        return C["DIRT"] if lit else C["DIRT_D"]
    for a, b in (((x0, y0), (x1, y0)), ((x1, y0), (x1, y1))):
        du, dv = b[0] - a[0], -(b[1] - a[1])
        nu, nv = dv, -du
        k = 1 if (a[1] == b[1]) else 3
        wall_pixels(S, cam, a, b, -dep, 0, side_fn, k, 0)
    composite(scene, S, outline=False)
    # outline of the whole island top (ink rim on the back edges)
    # ---- objects in painter order -------------------------------------------------------
    overlays = []
    for o in depth_sort(objs, cam):
        L = Layer(W, H)
        o["draw"](L, cam)
        fx = sum(p[0] for p in o["foot"]) / len(o["foot"]); fy = sum(p[1] for p in o["foot"]) / len(o["foot"])
        if math.hypot(fx - oc.x, fy - oc.y) > RADIUS + 2:
            dim_layer(L)
        composite(scene, L, outline=not o.get("no_outline"))
    # ---- world UI ------------------------------------------------------------------------
    U = Layer(W, H)
    for o in objs:
        if o.get("kind") == "lot":
            X, Y = cam.Pi(*o["center"], 0)
            tag = "$48K"
            w = micro_w(tag) + 6
            frame(U, X - w // 2, Y - 25, X - w // 2 + w, Y - 15, C["GOLD"], C["SL1"])
            micro(U, X - w // 2 + 3, Y - 22, tag, C["GOLD"])
            U.put(X, Y - 14, C["GOLD"]); U.put(X, Y - 13, C["GOLD_M"])
        if o.get("kind") == "build":
            X, Y = cam.Pi(*o["center"], o["top_z"] - 22)
            X += 16
            bw = 22
            frame(U, X - bw // 2 - 2, Y - 3, X + bw // 2 + 2, Y + 4, C["SL4"], C["INK"], studs=False)
            U.dr.rectangle([X - bw // 2, Y - 1, X + bw // 2, Y + 2], fill=C["SL1"] + (255,))
            U.dr.rectangle([X - bw // 2, Y - 1, X - bw // 2 + int(bw * .62), Y + 2], fill=C["MINT"] + (255,))
            U.dr.line([X - bw // 2, Y - 1, X - bw // 2 + int(bw * .62), Y - 1], fill=C["CREAM"] + (255,))
            icon_up = ["..1..", ".111.", "11111", "..1..", "..1.."]
        if o.get("pid") in ("w900024335", "w900021958"):
            X, Y = cam.Pi(*o["center"], o["h"] + 9) if o["pid"] != "w900024335" else cam.Pi(*o["center"], 60)
            txt = "+$410" if o["pid"] == "w900024335" else "+$85"
            micro(U, X - micro_w(txt) // 2, Y, txt, C["GOLD"], outline=C["INK"])
    composite(scene, U, outline=False)
    return scene, cam

def lamp_obj(x, y):
    def draw(L, cam):
        X, Y = cam.Pi(x, y)
        for k in range(8): L.put(X, Y - k, C["SL1"])
        L.put(X - 1, Y - 8, C["SL1"]); L.put(X + 1, Y - 8, C["SL1"])
        L.put(X - 1, Y - 9, C["GOLD"]); L.put(X + 1, Y - 9, C["GOLD"]); L.put(X, Y - 9, C["SL1"]); L.put(X, Y - 10, C["SL1"])
        L.put(X - 1, Y, C["SL1"]); L.put(X + 1, Y, C["SL1"])
    return {"kind": "lamp", "foot": [(x - .3, y - .3), (x + .3, y - .3), (x + .3, y + .3), (x - .3, y + .3)],
            "draw": draw, "h": 0, "no_outline": True}

def ped_obj(x, y, j):
    shirt = [C["RED"], C["CYAN_M"], C["GOLD"], C["CREAM"], C["GRASS_D"], C["SL4"]][j % 6]
    def draw(L, cam):
        X, Y = cam.Pi(x, y)
        L.put(X, Y, C["SL1"]); L.put(X, Y - 1, shirt); L.put(X, Y - 2, shirt); L.put(X, Y - 3, C["SKIN"])
        L.put(X + 1, Y, C["INK"])
    return {"kind": "ped", "foot": [(x - .3, y - .3), (x + .3, y - .3), (x + .3, y + .3), (x - .3, y + .3)],
            "draw": draw, "h": 0, "no_outline": True}

def tree_obj(x, y, seed):
    def draw(L, cam):
        X, Y = cam.Pi(x, y); tree(L, X, Y, seed)
    return {"kind": "tree", "foot": [(x - .8, y - .8), (x + .8, y - .8), (x + .8, y + .8), (x - .8, y + .8)],
            "draw": draw, "pt": (x, y), "h": 5}

def car_obj(x, y, ax, col):
    taxi = col == "taxi"
    body = C["SL1"] if taxi else col
    if ax == "y": foot = [(x - 1, y - 2.2), (x + 1, y - 2.2), (x + 1, y + 2.2), (x - 1, y + 2.2)]
    else: foot = [(x - 2.2, y - 1), (x + 2.2, y - 1), (x + 2.2, y + 1), (x - 2.2, y + 1)]
    cab = Polygon(foot).buffer(-0.45, join_style=2)
    def draw(L, cam):
        rp = [tuple(min(255, int(c * 1.15)) for c in body), body, tuple(int(c * .75) for c in body), tuple(int(c * .55) for c in body)]
        prism(L, cam, foot, 0, 2, style_plain(rp), rp, rim=False)
        top_rp = [C["GOLD"]] * 4 if taxi else rp
        def cab_fn(i, r, n, h, k, wid):
            return C["SL4"] if k == 1 else C["SL2"]
        prism(L, cam, cab, 2, 3, cab_fn, top_rp, rim=False)
    return {"kind": "car", "foot": foot, "draw": draw, "h": 3}

def office(poly, seed):
    g = Polygon(poly); c = g.centroid
    hz = 7 + 5 * 5 + 2
    def draw(L, cam):
        prism(L, cam, poly, 0, hz, style_office(R_STN, seed), R_TEAL)
        # corner cupola on the chamfer
        q = clean(poly)
        near = max(q, key=lambda p: (p[0] - cam.cx) - (p[1] - cam.cy))
        # billboard: a Battlegrounds panel standing on the roof, facing the street
        X, Y = cam.Pi(c.x, c.y, hz)
        bw, bh = 43, 13
        bx0, by0 = X - bw // 2, Y - bh - 7
        for lx in (bx0 + 5, bx0 + bw - 6):
            for k in range(8): L.put(lx, by0 + bh + k - 1, C["SL1"])
        frame(L, bx0, by0, bx0 + bw, by0 + bh, C["GOLD"], C["SL1"])
        icon_house = ["..1..", ".111.", "11111", ".1.1.", ".111."]
        for j, row in enumerate(icon_house):
            for i, ch in enumerate(row):
                if ch == "1": L.put(bx0 + 4 + i, by0 + 4 + j, C["CYAN"])
        micro(L, bx0 + 11, by0 + 4, "REALTOR", C["GOLD"])
        lft = min(q, key=lambda p: p[0] + p[1])
        fx, fy = cam.Pi(lft[0] + 1.5, lft[1] + 0.5, hz)
        flag(L, fx, fy, h=9)
    return {"kind": "office", "draw": draw, "top_z": hz + 20, "center": (c.x, c.y), "ground": None}

def construction(poly, seed, lv):
    g = Polygon(poly); c = g.centroid
    hz = 6 + 4 * 4 + 2                       # floors already standing
    top = hz + 5 * 4                         # skeleton of the floors being added
    fac = FACADES[int(h01(seed, "fac") * len(FACADES))]
    def draw(L, cam):
        prism(L, cam, poly, 0, hz, style_apartment(fac, seed), R_CON, rim=False)
        prism(L, cam, g.buffer(-1.0, join_style=2), hz, top, style_skeleton(seed, 0), None)
        # scaffolding on the visible faces: poles + planks
        q = clean(poly)
        for a, b in zip(q, q[1:] + q[:1]):
            du, dv = b[0] - a[0], -(b[1] - a[1])
            if dv - du <= 0: continue
            def scf(i, r, n, h, k, wid):
                if r > h: return None
                if i % 6 == 0: return C["GOLD_M"] if k == 1 else C["WOOD"]
                if r % 6 == 0: return C["GOLD"] if k == 1 else C["GOLD_M"]
                return None
            nu, nv = dv, -du; ln = math.hypot(nu, nv); nu, nv = nu / ln, nv / ln
            a2 = (a[0] + nu * 0.9, a[1] - nv * 0.9); b2 = (b[0] + nu * 0.9, b[1] - nv * 0.9)
            k = max(1, shade_idx(np.array([nu, nv, 0])))
            wall_pixels(L, cam, a2, b2, 0, top - 2, scf, k, 0)
        # tower crane standing in the courtyard side
        far = min(q, key=lambda p: (p[0] - cam.cx) - (p[1] - cam.cy))
        mx, my = (c.x * .5 + far[0] * .5), (c.y * .5 + far[1] * .5)
        X, Y = cam.Pi(mx, my, hz)
        ch = top + 26 - hz
        for k in range(ch):
            L.put(X, Y - k, C["GOLD"] if k % 3 else C["GOLD_M"])
            L.put(X + 1, Y - k, C["GOLD_M"] if k % 3 else C["WOOD"])
            if k % 3 == 1: L.put(X + (k // 3) % 2, Y - k, C["INK"])
        jy = Y - ch
        for dx in range(-12, 26):
            L.put(X + dx, jy, C["GOLD"]); L.put(X + dx, jy + 1, C["GOLD_M"] if dx % 3 else C["INK"])
        for dx in range(-12, -6):
            for dy in range(2, 5): L.put(X + dx, jy + dy, C["STN2"] if dy < 4 else C["STN3"])
        L.put(X, jy - 1, C["GOLD"]); L.put(X + 1, jy - 1, C["GOLD"]); L.put(X, jy - 2, C["GOLD_M"])
        L.dr.rectangle([X - 2, jy + 2, X + 2, jy + 4], fill=C["CYAN_M"] + (255,))
        L.put(X - 1, jy + 3, C["CYAN"])
        hx = X + 18
        for k in range(2, 18): L.put(hx, jy + k, C["SL2"])
        L.put(hx, jy + 18, C["GOLD"]); L.put(hx - 1, jy + 18, C["GOLD_M"]); L.put(hx - 1, jy + 19, C["GOLD_M"])
        # a beam hanging from the hook
        for dx in range(-3, 4): L.put(hx + dx, jy + 20, C["CON2"])
        flag(L, *cam.Pi(far[0], far[1], hz), h=6)
    return {"kind": "build", "draw": draw, "top_z": top + 26, "center": (c.x, c.y), "ground": None}

# ------------------------------------------------------------------------------------------
# HUD
# ------------------------------------------------------------------------------------------
def hud(scene):
    W, H = scene.shape[1], scene.shape[0]
    U = Layer(W, H)
    # icon buttons, top-left (exactly the Battlegrounds strip, smaller)
    btns = [("house", C["GOLD"], C["GOLD_M"], C["GOLD_D"], True), ("coin", C["MINT"], C["GRN_M"], C["GRN_D"], False),
            ("up", C["CYAN"], C["CYAN_D"], C["CYAN_DD"], False), ("gear", C["SL4"], C["SL4"], C["SL1"], False)]
    x = 6
    for name, hi, mid, dark, active in btns:
        frame(U, x, 6, x + 24, 30, hi if active else mid, dark)
        iw, ih = len(ICONS[name][0]), len(ICONS[name])
        icon(U, x + 12 - iw // 2 + 1, 18 - ih // 2 + 1, name, hi if active else mid)
        x += 28
    # money (top right)
    money = "1.284.300"
    tw = int(U.dr.textlength(money, font=F12))
    text(U, 294, 6, money, F12, C["GOLD"], anchor="ra")
    coin_icon(U, 294 - tw - 11, 9)
    text(U, 294, 21, "+7.560/MIN", F12, C["MINT"], anchor="ra")
    # district title like WAVE n
    text(U, 7, 38, "EIXAMPLE", F16, C["CREAM"])
    text(U, 7, 56, "6 / 23 OWNED", F12, C["SL4"])
    # bottom: office level bar
    text(U, 7, 262, "LV 3 OFFICE", F12, C["GOLD"])
    text(U, 293, 262, "[62%] 31K / 50K", F12, C["SL4"], anchor="ra")
    frame(U, 6, 277, 294, 286, C["SL3"], C["SL1"])
    U.dr.rectangle([9, 280, 9 + int((291 - 9) * .62), 283], fill=C["GOLD"] + (255,))
    U.dr.line([9, 280, 9 + int((291 - 9) * .62), 280], fill=C["CREAM"] + (255,))
    cr = "© OPENSTREETMAP CONTRIBUTORS"
    micro(U, 294 - micro_w(cr), 291, cr, C["SL4"])
    composite(scene, U, outline=False)
    return scene

def save_x2(arr, path):
    im = Image.fromarray(quantize(arr))
    im.resize((im.width * 2, im.height * 2), Image.NEAREST).save(path)
    return im

# ------------------------------------------------------------------------------------------
# tier strip
# ------------------------------------------------------------------------------------------
def render_tiers():
    tw, th = 76, 206
    W, H = tw * 6 + 8, th + 8
    scene = checker(W, H)
    plot = [(0, 0), (19, 0), (19, 24), (0, 24)]
    for t in range(6):
        ox = 4 + t * tw
        cam = Cam(1.08, 9.5, 12, ox + tw // 2, 158)
        G = Layer(W, H)
        pad = 4.5
        sq = [(-pad, -pad), (19 + pad, -pad), (19 + pad, 24 + pad), (-pad, 24 + pad)]
        G.poly([cam.P(x, y) for x, y in sq], C["PAVE"])
        info = build_tier(plot, t, "tierplot", owned=(t > 0), levels=7, facade=R_OCH)
        if info.get("ground"): info["ground"](G, cam)
        gm = np.array(G.img); m = gm[..., 3] > 0
        sm = Image.new("L", (W, H), 0); sd = ImageDraw.Draw(sm)
        if t > 0:
            sp = shadow_poly(plot if t >= 3 else rect_frame(plot, .6), min(info["top_z"], 40))
            sd.polygon([cam.Pi(x, y) for x, y in sp.exterior.coords], fill=255)
        scene[m] = gm[..., :3][m]
        apply_shadow(scene, (np.array(sm) > 0) & m)
        S = Layer(W, H)
        def side_fn(i, r, n, h, k, wid):
            rr = h - r + 1
            if rr <= 0: return None
            if rr == 1: return C["PAVE_D"] if k == 1 else C["PAVE_S"]
            if r == 0: return C["INK"]
            return C["DIRT"] if k == 1 else C["DIRT_D"]
        x0, x1, y0, y1 = -pad, 19 + pad, -pad, 24 + pad
        wall_pixels(S, cam, (x0, y0), (x1, y0), -5, 0, side_fn, 1, 0)
        wall_pixels(S, cam, (x1, y0), (x1, y1), -5, 0, side_fn, 3, 0)
        composite(scene, S, outline=False)
        L = Layer(W, H); info["draw"](L, cam); composite(scene, L)
        for tx, ty in info.get("trees", []):
            L = Layer(W, H); X, Y = cam.Pi(tx, ty); tree(L, X, Y, "t" + str(tx)); composite(scene, L)
        U = Layer(W, H)
        frame(U, ox + 2, 180, ox + tw - 3, 208, C["GOLD"] if t == 5 else C["SL3"], C["SL1"])
        name = TIER_NAMES[t]
        nw = int(U.dr.textlength(name, font=FN))
        text(U, ox + tw // 2 - nw // 2, 182, name, FN, C["CREAM"] if t < 5 else C["GOLD"], shadow=False)
        for k in range(5):
            px_ = ox + tw // 2 - 14 + k * 6
            U.dr.rectangle([px_, 199, px_ + 3, 202], outline=C["SL4"] + (255,), fill=(C["GOLD"] if k < t else C["SL1"]) + (255,))
        if t < 5:   # gold chevron to the next tier
            cxp = ox + tw - 1; cyp = 194
            for j in range(4):
                U.put(cxp - 1 + j, cyp - 3 + j, C["GOLD"]); U.put(cxp - 1 + j, cyp + 3 - j, C["GOLD"])
        composite(scene, U, outline=False)
    U = Layer(W, H)
    text(U, 8, 8, "UPGRADE PATH", F16, C["CREAM"])
    text(U, 8, 26, "SAME PLOT, SIX TIERS", F12, C["SL4"])
    coin_icon(U, W - 70, 11)
    text(U, W - 8, 8, "TIER 0-5", F12, C["GOLD"], anchor="ra")
    composite(scene, U, outline=False)
    return scene

if __name__ == "__main__":
    city, cam = render_city()
    city = hud(city)
    im = save_x2(city, os.path.join(HERE, "city_600.png"))
    big = Image.open(os.path.join(HERE, "city_600.png"))
    # close-up: office, construction and the skyscraper at 2x again (= 4 screen px per art px)
    cx, cy = 300, 300
    crop = big.crop((cx - 150, cy - 150, cx + 150, cy + 150))
    crop.resize((600, 600), Image.NEAREST).save(os.path.join(HERE, "closeup_2x.png"))
    tiers = render_tiers()
    save_x2(tiers, os.path.join(HERE, "tiers.png"))
    print("ok")
