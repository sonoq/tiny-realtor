"""Tiny Realtor - style mockup C: "Night city / neon money".

usage: python3 neon_city.py [block_saved.json] [out_dir]

Everything is procedural: OSM footprints are snapped to a 2 m grid so every edge is a clean
2:1 pixel line, extruded, and rasterised face by face into a per-pixel depth buffer (no
painter's-order glitches). Ground light (street lamps, shop windows, neon) is accumulated in a
light map and turned into colour with ordered (Bayer) dithering over short palette ramps, so
glow stays pixel-art. Everything is drawn at 1x and upscaled with nearest-neighbour.
"""
import json, math, sys, os, hashlib
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "..", "..", "realestate", "data", "block_saved.json")
OUT = sys.argv[2] if len(sys.argv) > 2 else HERE
B = json.load(open(DATA))


def h01(*parts):
    return int(hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:8], 16) / 2 ** 32


def hexc(s):
    return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5))


def ramp(*cols):
    return [hexc(c) for c in cols]


# ---------------------------------------------------------------------------------------------
# PALETTE (everything on screen comes from these ramps; final pass snaps to this set)
# ---------------------------------------------------------------------------------------------
# one master palette; every ramp below is built from these names
C = {
    # night indigo (shadow -> moonlight)
    "n0": "#08081a", "n1": "#0e0f22", "n2": "#15172e", "n3": "#1f1f42", "n4": "#2c2c56",
    "n5": "#3d3d6e", "n6": "#565a8c", "n7": "#7c84b4", "n8": "#b4bce0",
    # plum + teal facades
    "p1": "#1d1430", "p2": "#2b1d42", "p3": "#3e2a54", "p4": "#5a3a5e",
    "t1": "#0f1d30", "t2": "#162a42", "t3": "#213c54", "t4": "#3a5262",
    # warm street light on the ground
    "w0": "#282440", "w1": "#3a3050", "w2": "#5c4658", "w3": "#8a6660", "w4": "#c08a6a",
    # vegetation, earth
    "g0": "#0a181d", "g1": "#0f2326", "g2": "#18352f", "g3": "#285036", "g4": "#43703c",
    "d1": "#261c2c", "d2": "#3a2a36", "d3": "#5a3e40",
    # windows
    "warm": "#ff9e48", "yel": "#ffd27a", "hot": "#fff0c4", "tv": "#6fd8ff", "ice": "#c8f0ff",
    # player gold neon
    "G0": "#3b2a2a", "G1": "#6e4a26", "G2": "#b47c22", "G3": "#ffd447", "G4": "#fff2b0",
    # office magenta neon
    "M0": "#36163a", "M1": "#6a1e62", "M2": "#b02c80", "M3": "#ff4fb0", "M4": "#ffc2e6",
    # cyan neon / pools
    "C1": "#145468", "C2": "#1f9ab0", "C3": "#5ff0ff", "C4": "#d8ffff",
    # tiles, red lights, white
    "r1": "#5a2c3c", "r2": "#7a3a40", "R1": "#8a1e2a", "R2": "#ff3b3b", "W": "#ffffff",
}


def R(*names):
    return [hexc(C[n]) for n in names]


GROUND = {  # material -> ramp, index = light level
    "side":  R("n3", "n4", "w1", "w2", "w3"),
    "asph":  R("n1", "n2", "w0", "w1", "w2"),
    "curb":  R("n4", "n5", "w1", "w2", "w3"),
    "mark":  R("n4", "n5", "w2", "w3", "w4"),
    "grass": R("g0", "g1", "g2", "g3", "g4"),
    "dirt":  R("d1", "d2", "d3", "w3", "w4"),
    "court": R("n2", "n3", "w0", "w1", "w2"),
    "pool":  R("C1", "C2", "C3", "C4", "C4"),
    "deck":  R("d2", "d3", "w2", "w3", "w4"),
}
GBASE = {"side": 1, "asph": 1, "curb": 1, "mark": 1, "grass": 1, "dirt": 1, "court": 1, "pool": 1, "deck": 1}
MAT_IDS = list(GROUND.keys())

NEON = {
    "gold":    R("G0", "G1", "G2", "G3", "G4"),
    "magenta": R("M0", "M1", "M2", "M3", "M4"),
    "cyan":    R("t1", "C1", "C2", "C3", "C4"),
}
WALL = {  # facade families, index = light level (0 deepest); top steps are warm street bounce
    "indigo": R("n1", "n2", "n3", "n4", "w1", "w2"),
    "plum":   R("n1", "p1", "p2", "p3", "p4", "w2"),
    "teal":   R("n1", "t1", "t2", "t3", "t4", "w2"),
    "stone":  R("n1", "d1", "d2", "d3", "w2", "w3"),
}
ROOF = R("n2", "n3", "n4", "n5", "n6", "n7")
WIN = {
    "dark": hexc(C["n0"]), "dim": hexc(C["n4"]), "warm": hexc(C["warm"]), "yellow": hexc(C["yel"]),
    "hot": hexc(C["hot"]), "tv": hexc(C["tv"]), "office": hexc(C["ice"]),
}
RED = hexc(C["R2"]); RED_D = hexc(C["R1"]); WHITE = hexc(C["W"])
TREE = R("n1", "g0", "g1", "g2", "g3", "g4")
TRUNK = hexc(C["n1"])
STEEL = R("n4", "n5", "n6", "n8")
TILE = R("p2", "r1", "r1", "r2")
INK = hexc(C["n0"])
PALETTE = sorted({hexc(v) for v in C.values()})

BAYER = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) + 0.5) / 16.0


def bayer(x, y):
    return BAYER[y & 3, x & 3]


# ---------------------------------------------------------------------------------------------
# PIXEL FONTS (hand-made, so the HUD lives on the same pixel grid as the city)
# ---------------------------------------------------------------------------------------------
F5 = {
    "0": ".XXX.|X...X|X..XX|X.X.X|XX..X|X...X|.XXX.", "1": "..X..|.XX..|..X..|..X..|..X..|..X..|.XXX.",
    "2": ".XXX.|X...X|....X|...X.|..X..|.X...|XXXXX", "3": "XXXXX|...X.|..X..|...X.|....X|X...X|.XXX.",
    "4": "...X.|..XX.|.X.X.|X..X.|XXXXX|...X.|...X.", "5": "XXXXX|X....|XXXX.|....X|....X|X...X|.XXX.",
    "6": "..XX.|.X...|X....|XXXX.|X...X|X...X|.XXX.", "7": "XXXXX|....X|...X.|..X..|.X...|.X...|.X...",
    "8": ".XXX.|X...X|X...X|.XXX.|X...X|X...X|.XXX.", "9": ".XXX.|X...X|X...X|.XXXX|....X|...X.|.XX..",
    "A": ".XXX.|X...X|X...X|XXXXX|X...X|X...X|X...X", "B": "XXXX.|X...X|X...X|XXXX.|X...X|X...X|XXXX.",
    "C": ".XXX.|X...X|X....|X....|X....|X...X|.XXX.", "D": "XXX..|X..X.|X...X|X...X|X...X|X..X.|XXX..",
    "E": "XXXXX|X....|X....|XXXX.|X....|X....|XXXXX", "F": "XXXXX|X....|X....|XXXX.|X....|X....|X....",
    "G": ".XXX.|X...X|X....|X.XXX|X...X|X...X|.XXXX", "H": "X...X|X...X|X...X|XXXXX|X...X|X...X|X...X",
    "I": "XXX|.X.|.X.|.X.|.X.|.X.|XXX", "J": "..XXX|...X.|...X.|...X.|...X.|X..X.|.XX..",
    "K": "X...X|X..X.|X.X..|XX...|X.X..|X..X.|X...X", "L": "X....|X....|X....|X....|X....|X....|XXXXX",
    "M": "X...X|XX.XX|X.X.X|X.X.X|X...X|X...X|X...X", "N": "X...X|X...X|XX..X|X.X.X|X..XX|X...X|X...X",
    "O": ".XXX.|X...X|X...X|X...X|X...X|X...X|.XXX.", "P": "XXXX.|X...X|X...X|XXXX.|X....|X....|X....",
    "Q": ".XXX.|X...X|X...X|X...X|X.X.X|X..X.|.XX.X", "R": "XXXX.|X...X|X...X|XXXX.|X.X..|X..X.|X...X",
    "S": ".XXXX|X....|X....|.XXX.|....X|....X|XXXX.", "T": "XXXXX|..X..|..X..|..X..|..X..|..X..|..X..",
    "U": "X...X|X...X|X...X|X...X|X...X|X...X|.XXX.", "V": "X...X|X...X|X...X|X...X|X...X|.X.X.|..X..",
    "W": "X...X|X...X|X...X|X.X.X|X.X.X|X.X.X|.X.X.", "X": "X...X|X...X|.X.X.|..X..|.X.X.|X...X|X...X",
    "Y": "X...X|X...X|.X.X.|..X..|..X..|..X..|..X..", "Z": "XXXXX|....X|...X.|..X..|.X...|X....|XXXXX",
    ".": "..|..|..|..|..|XX|XX", ",": "..|..|..|..|XX|.X|X.", "+": ".....|..X..|..X..|XXXXX|..X..|..X..|.....",
    "-": "....|....|....|XXXX|....|....|....", "/": "....X|....X|...X.|..X..|.X...|X....|X....",
    ":": "..|XX|XX|..|XX|XX|..", "€": "..XXX|.X...|XXXX.|.X...|XXXX.|.X...|..XXX",
    "%": "XX..X|XX..X|...X.|..X..|.X...|X..XX|X..XX", " ": "...|...|...|...|...|...|...",
}
F3 = {
    "A": ".X.|X.X|XXX|X.X|X.X", "B": "XX.|X.X|XX.|X.X|XX.", "C": ".XX|X..|X..|X..|.XX", "D": "XX.|X.X|X.X|X.X|XX.",
    "E": "XXX|X..|XX.|X..|XXX", "F": "XXX|X..|XX.|X..|X..", "G": ".XX|X..|X.X|X.X|.XX", "H": "X.X|X.X|XXX|X.X|X.X",
    "I": "XXX|.X.|.X.|.X.|XXX", "J": "..X|..X|..X|X.X|.X.", "K": "X.X|X.X|XX.|X.X|X.X", "L": "X..|X..|X..|X..|XXX",
    "M": "X...X|XX.XX|X.X.X|X...X|X...X", "N": "X..X|XX.X|X.XX|X..X|X..X", "O": ".X.|X.X|X.X|X.X|.X.",
    "P": "XX.|X.X|XX.|X..|X..", "Q": ".X.|X.X|X.X|XX.|.XX", "R": "XX.|X.X|XX.|X.X|X.X", "S": ".XX|X..|.X.|..X|XX.",
    "T": "XXX|.X.|.X.|.X.|.X.", "U": "X.X|X.X|X.X|X.X|XXX", "V": "X.X|X.X|X.X|X.X|.X.", "W": "X...X|X...X|X.X.X|XX.XX|X...X",
    "X": "X.X|X.X|.X.|X.X|X.X", "Y": "X.X|X.X|.X.|.X.|.X.", "Z": "XXX|..X|.X.|X..|XXX",
    "0": "XXX|X.X|X.X|X.X|XXX", "1": ".X.|XX.|.X.|.X.|XXX", "2": "XX.|..X|.X.|X..|XXX", "3": "XX.|..X|.X.|..X|XX.",
    "4": "X.X|X.X|XXX|..X|..X", "5": "XXX|X..|XX.|..X|XX.", "6": ".XX|X..|XXX|X.X|XXX", "7": "XXX|..X|.X.|.X.|.X.",
    "8": "XXX|X.X|XXX|X.X|XXX", "9": "XXX|X.X|XXX|..X|XX.", ".": ".|.|.|.|X", ",": "..|..|..|.X|X.",
    "+": "...|.X.|XXX|.X.|...", "-": "...|...|XXX|...|...", "/": "..X|..X|.X.|X..|X..", ":": ".|X|.|X|.",
    "%": "X.X|..X|.X.|X..|X.X", "€": "..XXX|.X...|XXXX.|.X...|..XXX", " ": "..|..|..|..|..",
    "©": ".XXX.|X.XXX|X.X.X|X.XXX|.XXX.", ">": "X..|.X.|..X|.X.|X..", "!": "X|X|X|.|X", "^": ".X.|X.X|...|...|...",
}


def text_w(s, font):
    return sum(len(font[c].split("|")[0]) + 1 for c in s) - 1


def draw_text(img, x, y, s, font, col, shadow=None, outline=None):
    px = img.load()
    if outline is not None:
        xx = x
        for c in s:
            rows = font[c].split("|")
            for j, row in enumerate(rows):
                for i, ch in enumerate(row):
                    if ch == "X":
                        for dx in (-1, 0, 1):
                            for dy in (-1, 0, 1):
                                put(px, img, xx + i + dx, y + j + dy, outline)
            xx += len(rows[0]) + 1
    for c in s:
        rows = font[c].split("|")
        for j, row in enumerate(rows):
            for i, ch in enumerate(row):
                if ch == "X":
                    if shadow is not None:
                        put(px, img, x + i + 1, y + j + 1, shadow)
                    put(px, img, x + i, y + j, col)
        x += len(rows[0]) + 1
    return x


def put(px, img, x, y, c):
    if 0 <= x < img.width and 0 <= y < img.height:
        px[x, y] = c


# ---------------------------------------------------------------------------------------------
# PROJECTION + Z-BUFFER CANVAS
# world: x east, y north (metres). u = x, v = -y. viewer sits at +u,+v,+z.
# screen X = u - v, Y = (u + v)/2 - z, depth D = u + v + z  (bigger = closer)
# ---------------------------------------------------------------------------------------------
def sn(a):
    return 2 * round(a / 2)


class Canvas:
    def __init__(self, W, H, ox, oy):
        self.W, self.H, self.ox, self.oy = W, H, ox, oy
        self.col = np.zeros((H, W, 3), np.uint8)
        self.dep = np.full((H, W), -1e9)
        self.fid = np.full((H, W), -1, np.int32)
        self.z = np.zeros((H, W))
        self.faces = []          # face id -> dict(obj=..., kind=...)
        self.light = np.zeros((H, W))  # warm ground light (screen space, at ground level)

    def P(self, x, y, z=0.0):
        u, v = x, -y
        return (u - v + self.ox, (u + v) / 2 - z + self.oy)

    def D(self, x, y, z=0.0):
        return x - y + z

    def new_face(self, **meta):
        self.faces.append(meta)
        return len(self.faces) - 1

    def raster(self, pts):
        """pts: screen points -> (x0, y0, bool mask) clipped to canvas, or None."""
        xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
        x0, x1 = int(math.floor(min(xs))), int(math.ceil(max(xs)))
        y0, y1 = int(math.floor(min(ys))), int(math.ceil(max(ys)))
        if x1 < 0 or y1 < 0 or x0 >= self.W or y0 >= self.H:
            return None
        m = Image.new("1", (x1 - x0 + 1, y1 - y0 + 1), 0)
        ImageDraw.Draw(m).polygon([(round(p[0]) - x0, round(p[1]) - y0) for p in pts], fill=1)
        a = np.array(m, bool)
        cx0, cy0 = max(0, x0), max(0, y0)
        cx1, cy1 = min(self.W, x1 + 1), min(self.H, y1 + 1)
        a = a[cy0 - y0:cy1 - y0, cx0 - x0:cx1 - x0]
        return cx0, cy0, a

    def face(self, world, color, bias=0.0, obj=None, kind="face", zinfo=False):
        """Rasterise a planar world polygon. color: rgb tuple or fn(X, Y, z, base_light)->rgb arrays.
        Returns face id (or None)."""
        sp = [self.P(*p) for p in world]
        area = 0.5 * abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(sp, sp[1:] + sp[:1])))
        if area < 0.5:
            return None
        r = self.raster(sp)
        if r is None:
            return None
        x0, y0, m = r
        if not m.any():
            return None
        # affine depth & height from 3 well-spread vertices
        best = None
        n = len(sp)
        for i in range(n):
            for j in range(i + 1, n):
                for k in range(j + 1, n):
                    A = np.array([[sp[i][0], sp[i][1], 1], [sp[j][0], sp[j][1], 1], [sp[k][0], sp[k][1], 1]])
                    det = abs(np.linalg.det(A))
                    if best is None or det > best[0]:
                        best = (det, (i, j, k), A)
        _, (i, j, k), A = best
        dv = np.array([self.D(*world[q]) for q in (i, j, k)])
        zv = np.array([world[q][2] for q in (i, j, k)])
        cd = np.linalg.solve(A, dv); cz = np.linalg.solve(A, zv)
        H, W = m.shape
        YY, XX = np.mgrid[y0:y0 + H, x0:x0 + W]
        dep = cd[0] * XX + cd[1] * YY + cd[2] + bias
        win = m & (dep > self.dep[y0:y0 + H, x0:x0 + W])
        if not win.any():
            return None
        fid = self.new_face(obj=obj, kind=kind)
        zz = cz[0] * XX + cz[1] * YY + cz[2]
        self.z[y0:y0 + H, x0:x0 + W][win] = zz[win]
        if callable(color):
            gl = self.ground_light_at(XX, YY + zz)
            c = color(XX, YY, zz, gl)
            self.col[y0:y0 + H, x0:x0 + W][win] = c[win]
        else:
            self.col[y0:y0 + H, x0:x0 + W][win] = color
        self.dep[y0:y0 + H, x0:x0 + W][win] = dep[win]
        self.fid[y0:y0 + H, x0:x0 + W][win] = fid
        return fid

    def ground_light_at(self, X, Y):
        Xi = np.clip(np.round(X).astype(int), 0, self.W - 1)
        Yi = np.clip(np.round(Y).astype(int), 0, self.H - 1)
        return self.light[Yi, Xi]

    def pix(self, X, Y, c, depth, obj=None):
        """billboard pixel with explicit depth"""
        X, Y = int(round(X)), int(round(Y))
        if 0 <= X < self.W and 0 <= Y < self.H and depth > self.dep[Y, X]:
            self.col[Y, X] = c; self.dep[Y, X] = depth
            self.fid[Y, X] = self.new_face(obj=obj, kind="bb") if obj is not None else -2
            return True
        return False

    def on_face(self, X, Y, fid, c):
        X, Y = int(round(X)), int(round(Y))
        if fid is not None and 0 <= X < self.W and 0 <= Y < self.H and self.fid[Y, X] == fid:
            self.col[Y, X] = c
            return True
        return False


# ---------------------------------------------------------------------------------------------
# GEOMETRY HELPERS
# ---------------------------------------------------------------------------------------------
def clean_poly(poly):
    out = []
    for x, y in poly:
        p = (sn(x), sn(y))
        if not out or out[-1] != p:
            out.append(p)
    if len(out) > 1 and out[0] == out[-1]:
        out.pop()
    # drop collinear
    changed = True
    while changed and len(out) > 3:
        changed = False
        for i in range(len(out)):
            a, b, c = out[i - 1], out[i], out[(i + 1) % len(out)]
            if (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]) == 0:
                out.pop(i); changed = True; break
    return out


def area_uv(poly):  # signed area in (u, v)
    q = [(x, -y) for x, y in poly]
    return sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(q, q[1:] + q[:1])) / 2


def visible_walls(poly):
    """yield (a, b, side) for walls facing the viewer. side: 'L' (+v, moonlit), 'R' (+u), 'F' (front)"""
    ccw = area_uv(poly) > 0
    for a, b in zip(poly, poly[1:] + poly[:1]):
        du, dv = b[0] - a[0], -(b[1] - a[1])
        nu, nv = (dv, -du) if ccw else (-dv, du)
        if nu + nv <= 1e-6:
            continue
        L = math.hypot(nu, nv); nu, nv = nu / L, nv / L
        side = "F" if abs(nu - nv) < 0.3 else ("R" if nu > nv else "L")
        yield a, b, side


def bbox(poly):
    xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
    return min(xs), min(ys), max(xs), max(ys)


def rect(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def inset_rect(poly, fx, fy, ax=0.5, ay=0.5):
    x0, y0, x1, y1 = bbox(poly)
    w, h = (x1 - x0) * fx, (y1 - y0) * fy
    cx, cy = x0 + (x1 - x0) * ax, y0 + (y1 - y0) * ay
    return rect(sn(cx - w / 2), sn(cy - h / 2), sn(cx + w / 2), sn(cy + h / 2))


# ---------------------------------------------------------------------------------------------
# BUILDINGS
# ---------------------------------------------------------------------------------------------
SIDE_LVL = {"L": 2, "F": 2, "R": 1}


def wall_colour(fam, side, owned=False):
    rp = WALL[fam]; base = SIDE_LVL[side]

    def fn(X, Y, z, gl):
        # light from the street (light map under the wall) fades with height; plus dither
        lvl = base + gl * 3.2 * np.clip(1 - z / 9.0, 0, 1) + (BAYER[Y & 3, X & 3] - 0.5) * 0.9
        if owned:  # gold neon washes the lower facade
            lvl = lvl + 0.6 * np.clip(1 - z / 6.0, 0, 1)
        idx = np.clip(np.floor(lvl + 0.5), 0, len(rp) - 1).astype(int)
        arr = np.array(rp, np.uint8)
        return arr[idx]
    return fn


def roof_colour(lvl=1):
    def fn(X, Y, z, gl):
        idx = np.full(X.shape, lvl)
        return np.array(ROOF, np.uint8)[np.clip(idx, 0, len(ROOF) - 1)]
    return fn


def roof_rim(cv, fid, poly_screen_mask_owner=None, rim=ROOF[4], edge=ROOF[0]):
    """outline roof face pixels: front (lower) edge highlighted, back edges dark"""
    if fid is None:
        return
    m = cv.fid == fid
    if not m.any():
        return
    ys, xs = np.nonzero(m)
    y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
    sub = m[y0:y1 + 1, x0:x1 + 1]
    pad = np.pad(sub, 1)
    down = ~pad[2:, 1:-1]; up = ~pad[:-2, 1:-1]; left = ~pad[1:-1, :-2]; right = ~pad[1:-1, 2:]
    c = cv.col[y0:y1 + 1, x0:x1 + 1]
    front = sub & down
    back = sub & (up | left | right) & ~front
    c[back] = edge
    c[front] = rim


class Obj:
    def __init__(self, pid, owned=False, office=False):
        self.pid, self.owned, self.office = pid, owned, office


def window_pattern(style, seed, owned):
    def pick(f, k, side):
        r = h01(seed, f, k, side)
        if owned:
            if r < 0.70: return NEON["gold"][3]
            if r < 0.80: return NEON["gold"][4]
            if r < 0.88: return WIN["warm"]
            return WIN["dim"]
        if style == "office":
            band = h01(seed, f, "band")
            if band < 0.45:
                return WIN["office"] if r < 0.85 else WIN["tv"]
            return WIN["dim"] if r < 0.85 else WIN["tv"]
        if style == "hotel":
            return WIN["yellow"] if r < 0.55 else (WIN["warm"] if r < 0.7 else WIN["dim"])
        # residential
        if r < 0.30: return WIN["warm"]
        if r < 0.42: return WIN["yellow"]
        if r < 0.47: return WIN["tv"]
        if r < 0.49: return WIN["hot"]
        return WIN["dim"] if r < 0.80 else WIN["dark"]
    return pick


def draw_prism(cv, poly, z0, z1, fam, obj, roof_lvl=1, owned=False, bias=0.0):
    """walls + flat roof; returns dict side->list of (a, b, fid), roof fid"""
    walls = []
    for a, b, side in visible_walls(poly):
        w = [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)]
        fid = cv.face(w, wall_colour(fam, side, owned), obj=obj, kind="wall", bias=bias)
        walls.append((a, b, side, fid))
    rf = cv.face([(x, y, z1) for x, y in poly], roof_colour(roof_lvl), bias=0.3 + bias, obj=obj, kind="roof")
    roof_rim(cv, rf, rim=ROOF[3] if not owned else NEON["gold"][3], edge=ROOF[0])
    return walls, rf


def windows_on(cv, walls, z0, levels, seed, style, owned, ground_shop=True, gf=4.0, fh=3.0,
               spacing=3, width=1, cat="residential"):
    pick = window_pattern(style, seed, owned)
    for a, b, side, fid in walls:
        if fid is None:
            continue
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        if L < 2:
            continue
        ux, uy = (b[0] - a[0]) / L, (b[1] - a[1]) / L
        n = int((L - 1) // spacing)
        if n < 1:
            continue
        off = (L - (n - 1) * spacing) / 2
        for f in range(1, levels):
            zb = z0 + gf + (f - 1) * fh + 1.0
            for k in range(n):
                t = off + k * spacing
                c = pick(f, k, side)
                for wpx in range(width):
                    x, y = a[0] + ux * (t + wpx), a[1] + uy * (t + wpx)
                    for dz in (0, 1):
                        X, Y = cv.P(x, y, zb + dz)
                        cv.on_face(X, math.floor(Y + 0.5), fid, c)
        if ground_shop:   # ground floor: lit shop fronts with awnings
            shop = h01(seed, side, "shop")
            k = 0.0
            while k < L - 1:
                seg = 2 + int(h01(seed, side, k) * 5)
                lit = h01(seed, side, k, "lit") < (0.75 if cat in ("commercial", "hotel") else 0.45)
                if owned:
                    lit = True
                col = (NEON["gold"][4] if owned else (WIN["hot"] if shop < 0.5 else WIN["yellow"])) if lit else WIN["dim"]
                if lit and not owned and h01(seed, side, k, "c") < 0.25:
                    col = WIN["tv"]
                for t in np.arange(k + 0.5, min(L - 0.5, k + seg), 1.0):
                    x, y = a[0] + ux * t, a[1] + uy * t
                    for dz in (0.5, 1.5, 2.5):
                        X, Y = cv.P(x, y, z0 + dz)
                        cv.on_face(X, math.floor(Y + 0.5), fid, col)
                    if lit:  # awning line
                        aw = [NEON["magenta"][2], NEON["cyan"][2], RED_D, NEON["gold"][2]][int(shop * 4)]
                        if owned:
                            aw = NEON["gold"][3]
                        X, Y = cv.P(x, y, z0 + 3.5)
                        cv.on_face(X, math.floor(Y + 0.5), fid, aw)
                k += seg + 1


def roof_patch(cv, poly, z, colour, obj):
    return cv.face([(x, y, z) for x, y in poly], colour, bias=0.6, obj=obj, kind="roof")


def roof_props(cv, poly, z, seed, obj, owned=False, tall=False):
    """Eixample roofs: stairwell 'casetes', lit skylights, rooftop bars with string lights, solar"""
    x0, y0, x1, y1 = bbox(poly)
    w, h = x1 - x0, y1 - y0
    if w < 8 or h < 8:
        return
    kind = h01(seed, "rooftype")
    if kind < 0.22 and w >= 10 and h >= 10:          # rooftop terrace bar with string lights
        tx0, ty0 = sn(x0 + 2), sn(y0 + 2)
        tx1, ty1 = sn(min(x1 - 2, tx0 + 10)), sn(min(y1 - 2, ty0 + 10))
        fid = roof_patch(cv, rect(tx0, ty0, tx1, ty1), z, ROOF[0] if not owned else NEON["gold"][0], obj)
        if fid is not None:
            m = cv.fid == fid
            ys, xs = np.nonzero(m)
            for yy, xx in zip(ys, xs):
                if (xx + 2 * yy) % 4 == 0: cv.col[yy, xx] = hexc(C["d2"])
        for (ax, ay), (bx, by) in zip(rect(tx0, ty0, tx1, ty1), rect(tx0, ty0, tx1, ty1)[1:] + [(tx0, ty0)]):
            L = math.hypot(bx - ax, by - ay)
            for t in np.arange(0, L, 1.0):
                x, y = ax + (bx - ax) * t / L, ay + (by - ay) * t / L
                sag = 1.6 - 0.6 * abs(math.sin(t * math.pi / 3))
                X, Y = cv.P(x, y, z + sag)
                c = (NEON["gold"][4] if owned else [WIN["yellow"], WIN["warm"], NEON["magenta"][3], WIN["tv"]][int(t) % 4])
                if int(t) % 2 == 0:
                    cv.pix(X, math.floor(Y + .5), c, cv.D(x, y, z) + 0.7)
        cv.add_roof_glow = True
    elif kind < 0.40:                                   # solar panels
        sx0, sy0 = sn(x0 + 2), sn(y0 + 2)
        sx1, sy1 = sn(x1 - 3), sn(min(y1 - 2, sy0 + 8))
        if sx1 > sx0 + 2 and sy1 > sy0 + 2:
            fid = roof_patch(cv, rect(sx0, sy0, sx1, sy1), z, ROOF[3], obj)
            if fid is not None:
                m = cv.fid == fid
                ys, xs = np.nonzero(m)
                for yy, xx in zip(ys, xs):
                    if xx % 3 == 0 or yy % 2 == 0: cv.col[yy, xx] = ROOF[2]
    elif kind < 0.62:                                   # skylights glowing from inside
        for k in range(2):
            gx = sn(x0 + 3 + h01(seed, k, "sx") * (w - 8)); gy = sn(y0 + 3 + h01(seed, k, "sy") * (h - 8))
            if k == 0 or h01(seed, k, "s2") < 0.3:
                roof_patch(cv, rect(gx, gy, gx + 2, gy + 4), z, WIN["yellow"] if h01(seed, k) < .7 else WIN["warm"], obj)
    n = 1 + int(h01(seed, "np") * 1.6)
    for k in range(n):
        bw = 4 + 2 * int(h01(seed, k, "w") * 2)
        bh = 4 + 2 * int(h01(seed, k, "h") * 2)
        cx = sn(x1 - 2 - bw - h01(seed, k, "x") * (w * 0.4))
        cy = sn(y1 - 2 - bh - h01(seed, k, "y") * (h * 0.4))
        box = rect(cx, cy, cx + bw, cy + bh)
        walls, rf = draw_prism(cv, box, z, z + 3, "indigo", obj, roof_lvl=2, owned=False)
        for a, b, side, fid in walls:     # lit stairwell door
            if side == "L" and fid is not None and h01(seed, k, "door") < 0.6:
                X, Y = cv.P((a[0] + b[0]) / 2, (a[1] + b[1]) / 2, z + 0.5)
                cv.on_face(X, math.floor(Y + .5), fid, WIN["yellow"])
                cv.on_face(X, math.floor(Y + .5) - 1, fid, WIN["warm"])
    if tall or h01(seed, "ant") < 0.25:
        ax, ay = sn((x0 + x1) / 2 + 2), sn((y0 + y1) / 2)
        X, Y = cv.P(ax, ay, z)
        d = cv.D(ax, ay, z)
        hh = 6 if not tall else 9
        for i in range(hh):
            cv.pix(X, Y - i, STEEL[1], d + i)
        cv.pix(X, Y - hh, RED, d + hh)
        cv.blinkers.append((X, Y - hh))


def blade_sign(cv, a, b, side, seed, z0=5):
    """vertical neon blade sign sticking out of a facade"""
    L = math.hypot(b[0] - a[0], b[1] - a[1])
    t = 2 + h01(seed, "bt") * max(1, L - 4)
    x, y = a[0] + (b[0] - a[0]) * t / L, a[1] + (b[1] - a[1]) * t / L
    neon = [NEON["magenta"], NEON["cyan"], NEON["magenta"], [RED_D, RED_D, RED_D, RED, WHITE]][int(h01(seed, "bc") * 4)]
    hgt = 7 + int(h01(seed, "bh") * 5)
    X, Y = cv.P(x, y, z0); X, Y = round(X), round(Y)
    d = cv.D(x, y, z0) + 1.5
    for i in range(hgt):
        for j in range(2):
            c = neon[3] if (i % 3 != 2 or j == 0) else neon[2]
            if i in (0, hgt - 1): c = neon[2]
            cv.pix(X + j, Y - i, c, d + i)
    cv.signs.append((X, Y - hgt + 1, 2, hgt, neon))


def gable_roof(cv, poly, z, rise, obj, owned=False):
    x0, y0, x1, y1 = bbox(poly)
    lvl = 2
    if (x1 - x0) >= (y1 - y0):   # ridge along x
        ym = (y0 + y1) / 2
        faces = [[(x0, y0, z), (x1, y0, z), (x1, ym, z + rise), (x0, ym, z + rise)],
                 [(x0, y1, z), (x1, y1, z), (x1, ym, z + rise), (x0, ym, z + rise)]]
        gables = [[(x1, y0, z), (x1, y1, z), (x1, ym, z + rise)], [(x0, y0, z), (x0, y1, z), (x0, ym, z + rise)]]
    else:
        xm = (x0 + x1) / 2
        faces = [[(x0, y0, z), (x0, y1, z), (xm, y1, z + rise), (xm, y0, z + rise)],
                 [(x1, y0, z), (x1, y1, z), (xm, y1, z + rise), (xm, y0, z + rise)]]
        gables = [[(x0, y0, z), (x1, y0, z), (xm, y0, z + rise)], [(x0, y1, z), (x1, y1, z), (xm, y1, z + rise)]]
    tile = TILE
    for g in gables:
        cv.face(g, wall_colour("stone", "L", owned), obj=obj, kind="wall", bias=-0.05)
    for i, f in enumerate(faces):
        c = tile[2] if i == 0 else tile[1]
        fid = cv.face(f, c, obj=obj, kind="roof", bias=0.2)
        if fid is not None:   # tile rows
            m = cv.fid == fid
            ys, xs = np.nonzero(m)
            for yy, xx in zip(ys, xs):
                if yy % 2 == 0:
                    cv.col[yy, xx] = tile[3] if (i == 0) else tile[2]
            roof_rim(cv, fid, rim=NEON["gold"][3] if owned else tile[3], edge=tile[0])


# ---------------------------------------------------------------------------------------------
# TIERS  0 lot / 1 house / 2 estate / 3 apartment block / 4 tower / 5 skyscraper
# ---------------------------------------------------------------------------------------------
TIER_NAMES = ["SOLAR", "CASA", "VILLA", "BLOQUE", "TORRE", "RASCACIELOS"]
TIER_RENT = ["-", "+40", "+120", "+450", "+1.6K", "+6.2K"]


def tier_ground(poly, tier):
    """ground patches (poly, material) for a plot at a given tier"""
    if tier == 0:
        return [(poly, "dirt")]
    if tier in (1, 2):
        out = [(poly, "grass")]
        if tier == 2:
            out.append((inset_rect(poly, 0.40, 0.70, 0.78, 0.40), "deck"))
            out.append((inset_rect(poly, 0.28, 0.56, 0.78, 0.40), "pool"))
        return out
    return []


def tier_lights(cv, poly, tier):
    x0, y0, x1, y1 = bbox(poly)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    if tier == 2:
        p = inset_rect(poly, 0.28, 0.56, 0.78, 0.40)
        a, b, c, d = bbox(p)
        cv.add_neon("cyan", (a + c) / 2, (b + d) / 2, 7, 1.0)
    if tier == 0:
        cv.add_light(cx, cy, 5, 0.5)


def draw_tier(cv, poly, tier, seed, obj, owned, build_frac=1.0):
    x0, y0, x1, y1 = bbox(poly)
    if tier == 0:
        # fence posts + for sale sign
        for a, b, side in visible_walls(poly):
            L = math.hypot(b[0] - a[0], b[1] - a[1])
            for t in np.arange(0, L, 2.0):
                x = a[0] + (b[0] - a[0]) * t / L; y = a[1] + (b[1] - a[1]) * t / L
                X, Y = cv.P(x, y, 0); d = cv.D(x, y, 0)
                cv.pix(X, Y, STEEL[1], d); cv.pix(X, Y - 1, STEEL[2], d + 1)
        cx, cy = sn((x0 + x1) / 2), sn((y0 + y1) / 2)
        sale_sign(cv, cx, cy)
        return
    if tier == 1:
        hp = inset_rect(poly, 0.55, 0.5, 0.4, 0.55)
        walls, rf = draw_prism(cv, hp, 0, 6, "stone", obj, owned=owned)
        windows_on(cv, walls, 0, 2, seed, "res", owned, ground_shop=False, spacing=3)
        for a, b, side, fid in walls:   # door
            if side == "L" and fid is not None:
                mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                for dz in (0.5, 1.5, 2.5):
                    X, Y = cv.P(mx, my, dz); cv.on_face(X, math.floor(Y + .5), fid, NEON["gold"][4] if owned else WIN["yellow"])
        gable_roof(cv, hp, 6, 4, obj, owned)
        a, b, c, d = bbox(hp)
        chim = rect(sn(a + 2), sn(b + 2), sn(a + 2) + 2, sn(b + 2) + 2)
        draw_prism(cv, chim, 6, 10, "stone", obj)
        tree(cv, x1 - 3, y0 + 3, seed, big=True)
        tree(cv, x0 + 3, y1 - 3, seed + "b")
        return
    if tier == 2:
        hp = inset_rect(poly, 0.50, 0.50, 0.30, 0.70)
        walls, rf = draw_prism(cv, hp, 0, 8, "plum", obj, owned=owned, roof_lvl=3)
        windows_on(cv, walls, 0, 2, seed, "res", owned, ground_shop=True, gf=4, spacing=2, width=1)
        a, b, c, d = bbox(hp)
        up = rect(a, sn(b + (d - b) * 0.45), sn(a + (c - a) * 0.6), d)
        w2, r2 = draw_prism(cv, up, 8, 12, "plum", obj, owned=owned, roof_lvl=3)
        windows_on(cv, w2, 8, 2, seed + "u", "res", owned, ground_shop=False, gf=1, spacing=2, width=1)
        # hedge + garden lamps
        for t in range(int(x0) + 1, int(x1) - 8, 4):
            tree(cv, t, y0 + 1, seed + str(t), small=True)
        tree(cv, x1 - 3, y1 - 3, seed, big=True)
        return
    if tier == 3:
        levels = 7
        z1 = 4 + (levels - 1) * 3
        walls, rf = draw_prism(cv, poly, 0, z1, "indigo", obj, owned=owned)
        windows_on(cv, walls, 0, levels, seed, "res", owned, spacing=3)
        roof_props(cv, poly, z1, seed, obj, owned)
        return
    if tier == 4:
        tp = inset_rect(poly, 0.7, 0.7)
        pod = 8
        walls, rf = draw_prism(cv, poly, 0, pod, "teal", obj, owned=owned)
        windows_on(cv, walls, 0, 2, seed, "office", owned, spacing=2, gf=4)
        levels = 15
        z1 = pod + levels * 3
        walls, rf = draw_prism(cv, tp, pod, z1, "teal", obj, owned=owned, roof_lvl=3)
        windows_on(cv, walls, pod, levels + 1, seed, "office", owned, ground_shop=False, gf=0, spacing=2)
        crown(cv, tp, z1, obj, owned, 3)
        roof_props(cv, inset_rect(tp, .7, .7), z1 + 3, seed, obj, owned, tall=True)
        return
    if tier == 5:
        pod = 10
        walls, rf = draw_prism(cv, poly, 0, pod, "teal", obj, owned=owned)
        windows_on(cv, walls, 0, 3, seed, "office", owned, spacing=2, gf=4)
        t1 = inset_rect(poly, 0.72, 0.72)
        z1 = pod + 24 * 3
        walls, rf = draw_prism(cv, t1, pod, z1, "teal", obj, owned=owned, roof_lvl=3)
        windows_on(cv, walls, pod, 25, seed, "office", owned, ground_shop=False, gf=0, spacing=2, width=1)
        neon_band(cv, walls, pod + 36, owned)
        t2 = inset_rect(t1, 0.66, 0.66)
        z2 = z1 + 8 * 3
        walls, rf = draw_prism(cv, t2, z1, z2, "teal", obj, owned=owned, roof_lvl=3)
        windows_on(cv, walls, z1, 9, seed + "t", "office", owned, ground_shop=False, gf=0, spacing=2)
        crown(cv, t2, z2, obj, owned, 4)
        # spire
        x0, y0, x1, y1 = bbox(t2)
        cx, cy = sn((x0 + x1) / 2), sn((y0 + y1) / 2)
        X, Y = cv.P(cx, cy, z2 + 4); d = cv.D(cx, cy, z2 + 4)
        for i in range(16):
            cv.pix(X, Y - i, NEON["gold"][3] if owned and i % 4 == 0 else STEEL[2], d + i)
        cv.pix(X, Y - 16, RED, d + 16); cv.blinkers.append((X, Y - 16))
        return


def crown(cv, poly, z, obj, owned, h):
    """open neon crown on top of towers: parapet frame lit in the owner's colour"""
    neon = NEON["gold"] if owned else NEON["cyan"]
    for a, b, side in visible_walls(poly):
        w = [(a[0], a[1], z), (b[0], b[1], z), (b[0], b[1], z + h), (a[0], a[1], z + h)]
        fid = cv.face(w, WALL["teal"][1], obj=obj, kind="wall")
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        for t in np.arange(0, L + 0.01, 1.0):
            x = a[0] + (b[0] - a[0]) * t / L; y = a[1] + (b[1] - a[1]) * t / L
            for dz, c in ((h - 0.5, neon[3]), (0.5, neon[2])):
                X, Y = cv.P(x, y, z + dz)
                cv.on_face(X, math.floor(Y + .5), fid, c)
            if int(t) % 2 == 0:
                for dz in range(1, h):
                    X, Y = cv.P(x, y, z + dz)
                    cv.on_face(X, math.floor(Y + .5), fid, neon[1])
    rf = cv.face([(x, y, z + 1) for x, y in poly], ROOF[1], obj=obj, kind="roof", bias=-0.5)


def neon_band(cv, walls, z, owned):
    neon = NEON["gold"] if owned else NEON["magenta"]
    for a, b, side, fid in walls:
        if fid is None: continue
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        for t in np.arange(0, L + .01, 1.0):
            x = a[0] + (b[0] - a[0]) * t / L; y = a[1] + (b[1] - a[1]) * t / L
            X, Y = cv.P(x, y, z); cv.on_face(X, math.floor(Y + .5), fid, neon[3])
            X, Y = cv.P(x, y, z + 1); cv.on_face(X, math.floor(Y + .5), fid, neon[2])


# ---------------------------------------------------------------------------------------------
# STREET FURNITURE + SPRITES
# ---------------------------------------------------------------------------------------------
TREE_SHAPES = [
    ["..XXX..", ".XXXXX.", "XXXXXXX", "XXXXXXX", ".XXXXX.", "..XXX.."],
    ["..XX...", ".XXXXX.", "XXXXXXX", ".XXXXXX", ".XXXXX.", "...X..."],
]


def tree(cv, x, y, seed, big=False, small=False):
    X, Y = cv.P(x, y, 0); d = cv.D(x, y, 0)
    X, Y = round(X), round(Y)
    gl = cv.light[min(cv.H - 1, max(0, Y)), min(cv.W - 1, max(0, X))] if 0 <= X < cv.W and 0 <= Y < cv.H else 0
    if small:
        for i, row in enumerate([".XX.", "XXXX", ".XX."]):
            for j, ch in enumerate(row):
                if ch == "X":
                    c = TREE[2] if i == 0 else TREE[1]
                    cv.pix(X - 2 + j, Y - 3 + i, c, d + 3 - i)
        return
    shape = TREE_SHAPES[int(h01(seed, "ts") * 2)]
    th = 3 if not big else 4
    for i in range(th):
        cv.pix(X, Y - i, TRUNK, d + i)
    top = Y - th - len(shape) + 1
    lit = min(2, int(gl * 4))
    for i, row in enumerate(shape):
        for j, ch in enumerate(row):
            if ch != "X": continue
            px, py = X - 3 + j, top + i
            lvl = 1
            if i <= 1 or (i == 2 and j < 3): lvl = 2
            if i >= len(shape) - 2 or j >= 5: lvl = 0 if i >= len(shape) - 1 else 1
            if (px + py) % 3 == 0 and lvl == 1: lvl = 2
            lvl += lit if i >= 2 else max(0, lit - 1)
            cv.pix(px, py, TREE[min(5, lvl)], d + (Y - py))


def car(cv, x, y, d, seed):
    """tiny car: body + cabin boxes, headlights forward, tail lights back"""
    dx, dy = d
    L, Wd = 4, 2
    if dx:
        body = rect(x - L / 2, y - Wd / 2, x + L / 2, y + Wd / 2); cab = rect(x - 1, y - Wd / 2, x + 1, y + Wd / 2)
    else:
        body = rect(x - Wd / 2, y - L / 2, x + Wd / 2, y + L / 2); cab = rect(x - Wd / 2, y - 1, x + Wd / 2, y + 1)
    paint = [hexc(C["n6"]), hexc(C["r2"]), hexc(C["t4"]), hexc(C["n7"]), hexc(C["p4"])][seed % 5]
    obj = Obj(f"car{seed}")
    for a, b, side in visible_walls(body):
        cv.face([(a[0], a[1], 0.4), (b[0], b[1], 0.4), (b[0], b[1], 1.6), (a[0], a[1], 1.6)],
                paint if side != "R" else tuple(int(c * 0.7) for c in paint), obj=obj, kind="car")
    cv.face([(px, py, 1.6) for px, py in body], paint, obj=obj, kind="car", bias=0.2)
    cv.face([(px, py, 2.4) for px, py in cab], hexc(C["n2"]), obj=obj, kind="car", bias=0.3)
    for a, b, side in visible_walls(cab):
        cv.face([(a[0], a[1], 1.6), (b[0], b[1], 1.6), (b[0], b[1], 2.4), (a[0], a[1], 2.4)],
                hexc(C["n4"]), obj=obj, kind="car")
    fx, fy = x + dx * L / 2, y + dy * L / 2
    bx, by = x - dx * L / 2, y - dy * L / 2
    for (px, py), c in (((fx, fy), WIN["hot"]), ((bx, by), RED)):
        X, Y = cv.P(px, py, 1.0)
        cv.pix(X, math.floor(Y + .5), c, cv.D(px, py, 1.0) + 0.8)


def lamp(cv, x, y):
    X, Y = cv.P(x, y, 0); d = cv.D(x, y, 0)
    for i in range(7):
        cv.pix(X, Y - i, STEEL[0], d + i)
    cv.pix(X, Y - 7, WIN["hot"], d + 7); cv.pix(X + 1, Y - 7, WIN["hot"], d + 7)
    cv.pix(X - 1, Y - 7, STEEL[1], d + 7)
    cv.lamp_heads.append((X, Y - 7))


def sale_sign(cv, x, y):
    X, Y = cv.P(x, y, 0); d = cv.D(x, y, 0); X, Y = round(X), round(Y)
    for i in range(6):
        cv.pix(X, Y - i, STEEL[1], d + i)
        cv.pix(X + 9, Y - i, STEEL[1], d + i)
    cv.sale_tag = (X + 5, Y - 14)
    board = ["XXXXXXXXXX", "X........X", "X........X", "X........X", "X........X", "X........X", "XXXXXXXXXX"]
    for i, row in enumerate(board):
        for j, ch in enumerate(row):
            cv.pix(X + j, Y - 12 + i, RED if ch == "X" else WHITE, d + 12)
    # "SE VENDE" in 3x5 would be 30px; board shows a big red house glyph + sparkle
    glyph = ["...X....", "..XXX...", ".XXXXX..", "..X.X...", "..XXX..."]
    for i, row in enumerate(glyph):
        for j, ch in enumerate(row):
            if ch == "X": cv.pix(X + 1 + j, Y - 11 + i, RED, d + 13)


def billboard_text(cv, x, y, z, lines, font, neon, frame=True, pad=2):
    """screen-facing neon sign standing in the world at (x,y,z) (bottom-centre)"""
    X0, Y0 = cv.P(x, y, z); d = cv.D(x, y, z) + 30
    X0, Y0 = round(X0), round(Y0)
    tw = max(text_w(s, font) for s in lines)
    lh = len(font["A"].split("|")) + 1
    W = tw + pad * 2 + 2; H = lh * len(lines) - 1 + pad * 2 + 2
    left, top = X0 - W // 2, Y0 - H
    # legs
    for i in range(0, 3):
        cv.pix(left + 3, Y0 - i, STEEL[1], d); cv.pix(left + W - 4, Y0 - i, STEEL[1], d)
    for yy in range(top, top + H):
        for xx in range(left, left + W):
            edge = yy in (top, top + H - 1) or xx in (left, left + W - 1)
            c = neon[3] if (edge and frame) else INK
            if edge and frame and (xx + yy) % 2 == 0 and yy == top + H - 1: c = neon[2]
            cv.pix(xx, yy, c, d)
    img_layer = []
    for li, s in enumerate(lines):
        sx = left + 1 + pad + (tw - text_w(s, font)) // 2
        sy = top + 1 + pad + li * lh
        x = sx
        for ch in s:
            rows = font[ch].split("|")
            for j, row in enumerate(rows):
                for i, cc in enumerate(row):
                    if cc == "X":
                        cv.pix(x + i, sy + j, neon[4] if (j == 0 or i == 0) else neon[3], d + 1)
            x += len(rows[0]) + 1
    cv.signs.append((left, top, W, H, neon))
    return left, top, W, H


# ---------------------------------------------------------------------------------------------
# GROUND
# ---------------------------------------------------------------------------------------------
def add_light_fn(cv):
    H, W = cv.H, cv.W
    YY, XX = np.mgrid[0:H, 0:W]
    cv.neon = {k: np.zeros((H, W)) for k in NEON}

    def add_light(x, y, r, inten):
        X, Y = cv.P(x, y, 0)
        dd = np.sqrt(((XX - X) / 2.0) ** 2 + (YY - Y) ** 2) / (r / 1.0)
        cv.light += inten * np.clip(1 - dd, 0, 1) ** 1.6

    def add_neon(kind, x, y, r, inten, ring=False):
        X, Y = cv.P(x, y, 0)
        dd = np.sqrt(((XX - X) / 2.0) ** 2 + (YY - Y) ** 2) / r
        cv.neon[kind] += inten * np.clip(1 - dd, 0, 1) ** 1.3

    cv.add_light, cv.add_neon = add_light, add_neon


def paint_ground(cv, roads, greens, patches, ring=None):
    """material map -> colours via light levels + Bayer dithering"""
    W, H = cv.W, cv.H
    mat = Image.new("L", (W, H), MAT_IDS.index("side"))
    md = ImageDraw.Draw(mat)
    P = lambda x, y: (round(cv.P(x, y)[0]), round(cv.P(x, y)[1]))
    road_polys = []
    for r in roads:
        (ax, ay), (bx, by) = r["line"][0], r["line"][-1]
        hw = r["width"] / 2
        if abs(bx - ax) < abs(by - ay):   # north-south
            x = sn((ax + bx) / 2); p = rect(x - sn(hw), -1000, x + sn(hw), 1000)
        else:
            y = sn((ay + by) / 2); p = rect(-1000, y - sn(hw), 1000, y + sn(hw))
        road_polys.append((r, p))
    for r, p in road_polys:  # curb strip, then carriageway 2 m narrower each side (sidewalk inside)
        x0, y0, x1, y1 = bbox(p)
        if x1 - x0 < 100:
            md.polygon([P(*q) for q in rect(x0 + 4, y0, x1 - 4, y1)], fill=MAT_IDS.index("curb"))
            md.polygon([P(*q) for q in rect(x0 + 5, y0, x1 - 5, y1)], fill=MAT_IDS.index("asph"))
        else:
            md.polygon([P(*q) for q in rect(x0, y0 + 4, x1, y1 - 4)], fill=MAT_IDS.index("curb"))
            md.polygon([P(*q) for q in rect(x0, y0 + 5, x1, y1 - 5)], fill=MAT_IDS.index("asph"))
    # re-pave intersections asphalt and add lane marks + zebras
    ns = [p for r, p in road_polys if bbox(p)[2] - bbox(p)[0] < 100]
    ew = [p for r, p in road_polys if bbox(p)[2] - bbox(p)[0] >= 100]
    for a in ns:
        for b in ew:
            ax0, _, ax1, _ = bbox(a); _, by0, _, by1 = bbox(b)
            md.polygon([P(*q) for q in rect(ax0 + 5, by0 + 5, ax1 - 5, by1 - 5)], fill=MAT_IDS.index("asph"))
            for k in range(int(ax0 + 6), int(ax1 - 5), 2):      # zebras across E-W road sides
                if k % 4: continue
                for yy in (by0 + 1, by1 - 3):
                    md.polygon([P(*q) for q in rect(k, yy, k + 2, yy + 2)], fill=MAT_IDS.index("mark"))
            for k in range(int(by0 + 6), int(by1 - 5), 2):
                if k % 4: continue
                for xx in (ax0 + 1, ax1 - 3):
                    md.polygon([P(*q) for q in rect(xx, k, xx + 2, k + 2)], fill=MAT_IDS.index("mark"))
    for r, p in road_polys:  # dashed centre lines
        x0, y0, x1, y1 = bbox(p)
        if x1 - x0 < 100:
            cx = sn((x0 + x1) / 2)
            for k in range(-400, 400, 8):
                if any(bbox(b)[1] - 2 < k < bbox(b)[3] + 2 for b in ew): continue
                md.line([P(cx, k), P(cx, k + 3)], fill=MAT_IDS.index("mark"))
        else:
            cy = sn((y0 + y1) / 2)
            for k in range(-400, 400, 8):
                if any(bbox(a)[0] - 2 < k < bbox(a)[2] + 2 for a in ns): continue
                md.line([P(k, cy), P(k + 3, cy)], fill=MAT_IDS.index("mark"))
    for g in greens:
        md.polygon([P(*q) for q in clean_poly(g["poly"])], fill=MAT_IDS.index("grass" if g["kind"] == "garden" else "court"))
    for poly, m in patches:
        md.polygon([P(*q) for q in poly], fill=MAT_IDS.index(m))
    M = np.array(mat)
    cv.mat = M
    YY, XX = np.mgrid[0:H, 0:W]
    bay = BAYER[YY & 3, XX & 3]
    out = np.zeros((H, W, 3), np.uint8)
    for i, name in enumerate(MAT_IDS):
        sel = M == i
        if not sel.any(): continue
        rp = np.array(GROUND[name], np.uint8)
        extra = 1.2 if name == "pool" else 0
        lvl = GBASE[name] + extra + cv.light * 3.0 + (bay - 0.5)
        idx = np.clip(np.floor(lvl + 0.5), 0, len(rp) - 1).astype(int)
        out[sel] = rp[idx[sel]]
    # neon washes on the ground (dithered)
    for kind in ("cyan", "magenta", "gold"):
        n = cv.neon[kind]
        lvl = np.floor(np.clip(n, 0, 1.4) * 2.2 + bay - 0.45).astype(int)
        rp = np.array(NEON[kind], np.uint8)
        sel = (lvl >= 1) & (M != MAT_IDS.index("pool"))
        out[sel] = rp[np.clip(lvl[sel] - 1, 0, 2)]
    cv.col[:] = out


DARKER = {a: b for a, b in [("n8", "n7"), ("n7", "n6"), ("n6", "n5"), ("n5", "n4"), ("n4", "n3"), ("n3", "n2"),
                             ("n2", "n1"), ("n1", "n0"), ("p4", "p3"), ("p3", "p2"), ("p2", "p1"), ("p1", "n1"),
                             ("t4", "t3"), ("t3", "t2"), ("t2", "t1"), ("t1", "n1"), ("w4", "w3"), ("w3", "w2"),
                             ("w2", "w1"), ("w1", "w0"), ("w0", "n2"), ("g4", "g3"), ("g3", "g2"), ("g2", "g1"),
                             ("g1", "g0"), ("g0", "n0"), ("d3", "d2"), ("d2", "d1"), ("d1", "n1"), ("r2", "r1"),
                             ("r1", "p2")]}


def darken(col, sel):
    """one palette step darker for non-emissive colours (lights stay lit)"""
    orig = col.copy()
    for a, b in DARKER.items():
        ca, cb = np.array(hexc(C[a]), np.uint8), np.array(hexc(C[b]), np.uint8)
        m = sel & np.all(orig == ca, axis=-1)
        col[m] = cb


def ring_decal(cv, cx, cy, r):
    """office radius: a dashed magenta circle projected from above onto ground AND rooftops,
    and the city outside the radius sinks one palette step into the night"""
    H, W = cv.H, cv.W
    YY, XX = np.mgrid[0:H, 0:W]
    roofflag = np.array([f["kind"] in ("roof",) for f in cv.faces] + [False, True])  # [-2]=bb, [-1]=ground
    fid = cv.fid
    horiz = roofflag[np.where(fid < 0, len(roofflag) + fid, fid)]
    z = np.where(fid == -1, 0.0, cv.z)
    a = XX - cv.ox                      # u - v
    b = 2 * (YY - cv.oy + z)            # u + v
    u, v = (a + b) / 2, (b - a) / 2
    dist = np.hypot(u - cx, -v - cy)
    bay = BAYER[YY & 3, XX & 3]
    outside = (dist > r + 0.9) & (fid != -2)
    darken(cv.col, outside & ((dist > r + 8) | (bay < (dist - r) / 8)))
    m = NEON["magenta"]
    band = horiz & (dist < r - 0.9) & (dist > r - 7) & (bay < (1 - (r - dist) / 7) * 0.45)
    cv.col[band] = m[1]
    ring = horiz & (np.abs(dist - r) <= 0.9)
    ang = np.arctan2(-v - cy, u - cx)
    dash = (np.floor((ang + math.pi) / (2 * math.pi) * 90) % 3) != 0
    cv.col[ring & dash] = m[3]
    cv.col[ring & ~dash] = m[1]


# ---------------------------------------------------------------------------------------------
# POST: owned-building neon outline + dithered halo, sign halos, blinkers
# ---------------------------------------------------------------------------------------------
def shift(a, dx, dy, fill=False):
    out = np.full_like(a, fill)
    H, W = a.shape
    xs0, xs1 = max(0, dx), min(W, W + dx); ys0, ys1 = max(0, dy), min(H, H + dy)
    out[ys0:ys1, xs0:xs1] = a[ys0 - dy:ys1 - dy, xs0 - dx:xs1 - dx]
    return out


def owned_glow(cv, owned_objs, colour="gold"):
    fobj = np.array([f["obj"] for f in cv.faces] + [None], dtype=object)
    fid = cv.fid
    obj_at = fobj[np.where(fid < 0, len(fobj) - 1, fid)]
    neon = NEON[colour]
    H, W = fid.shape
    YY, XX = np.mgrid[0:H, 0:W]
    bay = BAYER[YY & 3, XX & 3]
    for o in owned_objs:
        m = obj_at == o
        if not m.any(): continue
        n4 = shift(m, 1, 0) | shift(m, -1, 0) | shift(m, 0, 1) | shift(m, 0, -1)
        edge_in = m & ~(shift(m, 1, 0, True) & shift(m, -1, 0, True) & shift(m, 0, 1, True) & shift(m, 0, -1, True))
        d1 = n4 & ~m
        d2 = (shift(d1, 1, 0) | shift(d1, -1, 0) | shift(d1, 0, 1) | shift(d1, 0, -1)) & ~m & ~d1
        d3 = (shift(d2, 1, 0) | shift(d2, -1, 0) | shift(d2, 0, 1) | shift(d2, 0, -1)) & ~m & ~d1 & ~d2
        # only glow over things that are behind (do not paint over closer objects)
        dep_o = np.where(m, cv.dep, -1e9)
        near = np.maximum.reduce([shift(dep_o, dx, dy, -1e9) for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))])
        behind1 = cv.dep <= near + 0.5
        cv.col[edge_in] = neon[3]
        cv.col[d1 & behind1 & (bay < 0.75)] = neon[2]
        cv.col[d1 & behind1 & (bay >= 0.75)] = neon[1]
        cv.col[d2 & (bay < 0.5)] = neon[1]
        cv.col[d3 & (bay < 0.2)] = neon[0]


def halo(cv, box, neon, r=3):
    left, top, W, H = box
    for yy in range(top - r, top + H + r):
        for xx in range(left - r, left + W + r):
            if left <= xx < left + W and top <= yy < top + H: continue
            if not (0 <= xx < cv.W and 0 <= yy < cv.H): continue
            dx = max(left - xx, 0, xx - (left + W - 1)); dy = max(top - yy, 0, yy - (top + H - 1))
            d = max(dx, dy)
            b = bayer(xx, yy)
            if d == 1 and b < 0.7: cv.col[yy, xx] = neon[2] if b < 0.3 else neon[1]
            elif d == 2 and b < 0.4: cv.col[yy, xx] = neon[1]
            elif d == 3 and b < 0.15: cv.col[yy, xx] = neon[0]


def point_glow(cv, X, Y, c_core, ramp_, r=2):
    if not (0 <= X < cv.W and 0 <= Y < cv.H) or tuple(cv.col[Y, X]) != tuple(c_core):
        return   # light source hidden behind something
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            xx, yy = X + dx, Y + dy
            if not (0 <= xx < cv.W and 0 <= yy < cv.H) or (dx == 0 and dy == 0): continue
            d = abs(dx) + abs(dy)
            b = bayer(xx, yy)
            if d == 1 and b < 0.6: cv.col[yy, xx] = ramp_[2]
            elif d == 2 and b < 0.3: cv.col[yy, xx] = ramp_[1]


def coin(img_px, X, Y, fade=0.0, W=300, H=300):
    shape = [".XX.", "XBXX", "XXXD", ".DD."]
    if fade == 0:
        for j, row in enumerate(shape):
            for i, ch in enumerate(row):
                if ch == ".": continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    if 0 <= X + i + dx < W and 0 <= Y + j + dy < H:
                        img_px[Y + j + dy, X + i + dx] = INK
    for j, row in enumerate(shape):
        for i, ch in enumerate(row):
            if ch == ".": continue
            if fade > 0 and bayer(X + i, Y + j) < fade: continue
            c = {"X": NEON["gold"][3], "B": NEON["gold"][4], "D": NEON["gold"][2]}[ch]
            if 0 <= X + i < W and 0 <= Y + j < H:
                img_px[Y + j, X + i] = c


def sparkle(px, X, Y, c, W=300, H=300):
    for dx, dy in ((0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)):
        if 0 <= X + dx < W and 0 <= Y + dy < H:
            px[Y + dy, X + dx] = c if (dx, dy) != (0, 0) else WHITE


def snap_palette(img):
    pal = np.array(PALETTE, np.int32)
    a = np.array(img.convert("RGB"), np.int32)
    d = ((a[:, :, None, :] - pal[None, None, :, :]) ** 2).sum(-1)
    return Image.fromarray(pal[d.argmin(-1)].astype(np.uint8))


# ---------------------------------------------------------------------------------------------
# SCENE
# ---------------------------------------------------------------------------------------------
def make_canvas(W, H, ox, oy):
    cv = Canvas(W, H, ox, oy)
    cv.blinkers, cv.lamp_heads, cv.signs = [], [], []
    add_light_fn(cv)
    return cv


def street_furniture(cv, roads, plots_polys, region):
    """lamps + trees along sidewalks (2 m inside the curb), cars with headlight trails"""
    rx0, ry0, rx1, ry1 = region
    lamps, trees = [], []
    for r in roads:
        (ax, ay), (bx, by) = r["line"][0], r["line"][-1]
        hw = sn(r["width"] / 2)
        ns = abs(bx - ax) < abs(by - ay)
        c = sn((ax + bx) / 2) if ns else sn((ay + by) / 2)
        for side in (-1, 1):
            off = c + side * (hw - 2)
            for k in range(-300, 300, 6):
                x, y = (off, k) if ns else (k, off)
                if not (rx0 < x < rx1 and ry0 < y < ry1): continue
                # skip intersections
                near_int = False
                for r2 in roads:
                    (cx_, cy_), (dx_, dy_) = r2["line"][0], r2["line"][-1]
                    ns2 = abs(dx_ - cx_) < abs(dy_ - cy_)
                    if ns2 == ns: continue
                    c2 = sn((cx_ + dx_) / 2) if ns2 else sn((cy_ + dy_) / 2)
                    hw2 = r2["width"] / 2
                    if abs((y if ns else x) - c2) < hw2 + 3: near_int = True
                if near_int: continue
                if k % 24 == 0:
                    lamps.append((x, y))
                elif k % 6 == 0 and h01(r["name"], side, k) < 0.8:
                    trees.append((x, y, f"{r['name']}{side}{k}"))
    return lamps, trees


def render_city():
    plots = B["plots"]
    W, H = 300, 300
    # view: centred on the Rambla/Passeig de Gracia x Consell de Cent/Arago block
    cx, cy = -30, 64
    X0, Y0 = cx + cy, (cx - cy) / 2           # screen of centre without offsets
    ox, oy = W / 2 - X0, H / 2 - Y0 + 22
    ox, oy = round(ox), round(oy)
    cv = make_canvas(W, H, ox, oy)

    def onscreen(poly, z=120):
        sp = [cv.P(x, y, 0) for x, y in poly] + [cv.P(x, y, z) for x, y in poly]
        return max(p[0] for p in sp) > -10 and min(p[0] for p in sp) < W + 10 and \
            max(p[1] for p in sp) > -10 and min(p[1] for p in sp) < H + 160
    vis = [p for p in plots if onscreen(p["poly"], 0)]

    # ---- game state for the mockup -----------------------------------------------------
    OFFICE = "w900037280"
    OWN = {   # plot id -> tier
        "w900036274": 5,   # skyscraper on the Arago corner
        "w900037546": 4,   # tower
        "w900037577": 3,   # apartment block (owned, Eixample-style)
        "w900038173": 3,
        "w900037221": 2,   # villa with pool, next to the office
        "w900037025": 3,   # hotel corner, owned
        "w900037021": 1,   # house
    }
    BUILDING = "w900036949"   # mid-upgrade (scaffolding + crane)
    FORSALE = "w900036211"    # empty corner lot with for-sale sign
    office_plot = next(p for p in plots if p["id"] == OFFICE)
    oc = np.mean(np.array(office_plot["poly"]), axis=0)
    RADIUS = 78

    # ---- lights (needed before ground + walls) ------------------------------------------
    region = (cx - 200, cy - 200, cx + 200, cy + 200)
    lamps, trees = street_furniture(cv, B["roads"], None, region)
    for x, y in lamps:
        cv.add_light(x, y, 11, 1.1)
    for p in vis:   # shop windows spill light on the sidewalk
        if p["cat"] in ("commercial", "hotel") or h01(p["id"], "spill") < 0.3:
            poly = clean_poly(p["poly"])
            for a, b, side in visible_walls(poly):
                mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                L = math.hypot(b[0] - a[0], b[1] - a[1])
                nx, ny = (1, 0) if side == "R" else (0, -1)
                if side == "F": nx, ny = 0.7, -0.7
                cv.add_light(mx + nx * 3, my + ny * 3, max(6, L * 0.45), 0.45)
    for pid, t in OWN.items():
        p = next(q for q in plots if q["id"] == pid)
        c = np.mean(np.array(p["poly"]), axis=0)
        x0, y0, x1, y1 = bbox(p["poly"])
        cv.add_neon("gold", c[0], c[1], max(x1 - x0, y1 - y0) * 0.75, 0.75)
        tier_lights(cv, clean_poly(p["poly"]), t)
    cv.add_neon("magenta", oc[0] + 12, oc[1], 16, 1.0)
    cv.add_neon("cyan", oc[0] + 10, oc[1] + 2, 9, 0.7)
    # car light trails on Passeig de Gracia (x = 16) and Consell de Cent (y = 0)
    trails = [((10, -200, 10, 260), "white"), ((22, 260, 22, -200), "red"),
              ((-200, -4, 200, -4), "red"), ((-200, 4, 200, 4), "white")]
    cars = [(10, 30, (0, 1)), (22, 96, (0, -1)), (10, 150, (0, 1)), (-40, -4, (1, 0)), (-90, 4, (-1, 0)),
            (-120, 130, (1, 0)), (-118, 60, (0, 1)), (-104, 40, (0, -1)), (60, 4, (-1, 0))]
    for x, y, (dx, dy) in cars:
        cv.add_light(x + dx * 5, y + dy * 5, 5, 0.6)

    # ---- ground -------------------------------------------------------------------------
    patches = []
    for pid, t in OWN.items():
        p = next(q for q in plots if q["id"] == pid)
        patches += tier_ground(clean_poly(p["poly"]), t)
    fs = next(q for q in plots if q["id"] == FORSALE)
    patches += tier_ground(clean_poly(fs["poly"]), 0)
    cv.add_light(*np.mean(np.array(fs["poly"]), axis=0), 6, 0.35)
    paint_ground(cv, B["roads"], B["greens"], patches)
    for (x0, y0, x1, y1), kind in trails:
        L = math.hypot(x1 - x0, y1 - y0)
        for t in np.arange(0, L, 0.5):
            x, y = x0 + (x1 - x0) * t / L, y0 + (y1 - y0) * t / L
            X, Y = cv.P(x, y); X, Y = int(round(X)), int(round(Y))
            if not (0 <= X < W and 0 <= Y < H): continue
            if cv.mat[Y, X] not in (MAT_IDS.index("asph"), MAT_IDS.index("mark")): continue
            ph = (t * 0.9 + h01(kind, x0, y0) * 50) % 23
            if ph < 15:
                c = (WIN["hot"] if ph < 4 else WIN["yellow"]) if kind == "white" else (RED if ph < 6 else RED_D)
                if ph > 10 and bayer(X, Y) < 0.5: continue
                cv.col[Y, X] = c

    # ---- objects ------------------------------------------------------------------------
    owned_objs = []
    for p in vis:
        poly = clean_poly(p["poly"])
        if len(poly) < 3: continue
        pid = p["id"]
        obj = Obj(pid)
        if pid == FORSALE:
            draw_tier(cv, poly, 0, pid, obj, False)
            continue
        if pid in OWN:
            obj.owned = True; owned_objs.append(obj)
            draw_tier(cv, poly, OWN[pid], pid, obj, True)
            continue
        if pid == OFFICE:
            draw_office(cv, poly, obj)
            continue
        if pid == BUILDING:
            draw_construction(cv, poly, obj, p)
            continue
        fam = ["indigo", "plum", "teal", "stone"][int(h01(pid, "fam") * 4)]
        if p["cat"] == "office": fam = "teal"
        if p["cat"] == "hotel": fam = "plum"
        levels = max(4, min(7, p["levels"]))
        z1 = 4 + (levels - 1) * 3
        walls, rf = draw_prism(cv, poly, 0, z1, fam, obj)
        style = {"office": "office", "hotel": "hotel"}.get(p["cat"], "res")
        windows_on(cv, walls, 0, levels, pid, style, False, cat=p["cat"],
                   spacing=2 if style == "office" else 3)
        roof_props(cv, poly, z1, pid, obj)
        if p["cat"] in ("commercial", "hotel") and h01(pid, "blade") < 0.7:
            for wa, wb, side, fid in walls:
                if side in ("L", "R") and math.hypot(wb[0] - wa[0], wb[1] - wa[1]) > 8:
                    blade_sign(cv, wa, wb, side, pid); break
    for x, y in lamps:
        lamp(cv, x, y)
    for i, (x, y, d) in enumerate(cars):
        car(cv, x, y, d, i)
    for x, y, s in trees:
        tree(cv, x, y, s)
    for g in B["greens"]:
        gp = clean_poly(g["poly"])
        x0, y0, x1, y1 = bbox(gp)
        for k in range(5):
            tx = sn(x0 + 3 + h01(g["poly"][0], k, "x") * (x1 - x0 - 6))
            ty = sn(y0 + 3 + h01(g["poly"][0], k, "y") * (y1 - y0 - 6))
            tree(cv, tx, ty, f"g{k}{x0}", big=True)

    # ---- post ---------------------------------------------------------------------------
    ring_decal(cv, oc[0], oc[1], RADIUS)
    YY, XX = np.mgrid[0:H, 0:W]
    vr = np.hypot((XX - W / 2) / (W / 2), (YY - H / 2) / (H / 2))
    darken(cv.col, (vr > 0.95) & (BAYER[YY & 3, XX & 3] < (vr - 0.95) * 2.5))
    owned_glow(cv, owned_objs, "gold")
    for left, top, w, h, neon in cv.signs:
        halo(cv, (left, top, w, h), neon)
    for X, Y in cv.blinkers:
        point_glow(cv, int(X), int(Y), RED, [RED_D, RED_D, RED], 2)
    for X, Y in cv.lamp_heads:
        point_glow(cv, int(X), int(Y), WIN["hot"], [WIN["warm"], WIN["warm"], WIN["yellow"]], 1)

    # rent particles above owned buildings
    px = cv.col
    for o in owned_objs:
        p = next(q for q in plots if q["id"] == o.pid)
        own = np.array([f["obj"] is o for f in cv.faces] + [False, False])
        m = own[np.where(cv.fid < 0, len(own) + cv.fid, cv.fid)]
        if not m.any(): continue
        ys, xs = np.nonzero(m)
        topY = ys.min(); midX = int(np.median(xs[ys < topY + 6]))
        k = int(h01(o.pid, "c") * 3)
        def hits_sign(x, y, w=8, h=20):
            return any(x + w > l - 3 and x - w < l + sw + 3 and y + 6 > t - 3 and y - h < t + sh + 3
                       for l, t, sw, sh, _ in cv.signs if sw > 4)
        if hits_sign(midX, topY - 8):
            continue
        for i in range(2):
            yy = topY - 8 - i * 11 - k * 2
            xx = midX - 2 + (3 if i % 2 else -2)
            coin(px, xx, yy, fade=0.0 if i == 0 else 0.45)
            for j in range(1, 4):   # rising trail
                if 0 <= yy + 4 + j * 2 < H: px[yy + 4 + j * 2, xx + 1 + (j % 2)] = NEON["gold"][2 if j < 2 else 1]
        if h01(o.pid, "plus") < 0.6:
            img = Image.fromarray(px)
            draw_text(img, midX + 4, topY - 14 - k * 2, "+" + str(10 + int(h01(o.pid, "v") * 80)), F3,
                      NEON["gold"][3], outline=INK)
            px[:] = np.array(img)
        sparkle(px, midX - 6, topY - 4 - k, NEON["gold"][3])
    img = Image.fromarray(cv.col)
    return img, cv


def draw_office(cv, poly, obj):
    """the player's real-estate office: glass HQ, magenta neon trims, rooftop sign"""
    levels = 6
    z1 = 7 + (levels - 2) * 3 + 1
    walls = []
    for a, b, side in visible_walls(poly):
        w = [(a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], z1), (a[0], a[1], z1)]
        fid = cv.face(w, wall_colour("plum", side), obj=obj, kind="wall")
        walls.append((a, b, side, fid))
    rf = cv.face([(x, y, z1) for x, y in poly], roof_colour(0), bias=0.3, obj=obj, kind="roof")
    roof_rim(cv, rf, rim=NEON["magenta"][3], edge=NEON["magenta"][1])
    for a, b, side, fid in walls:
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        for t in np.arange(0.5, L, 1.0):
            x = a[0] + (b[0] - a[0]) * t / L; y = a[1] + (b[1] - a[1]) * t / L
            mull = int(t) % 4 == 0
            for z in np.arange(0.5, 6.5, 1.0):        # double-height lit glass lobby
                X, Y = cv.P(x, y, z)
                c = WIN["office"] if z < 2.5 else (NEON["cyan"][3] if z < 4.5 else NEON["cyan"][2])
                if mull: c = WALL["plum"][2]
                cv.on_face(X, math.floor(Y + .5), fid, c)
            X, Y = cv.P(x, y, 6.5); cv.on_face(X, math.floor(Y + .5), fid, NEON["magenta"][3])
            for f in range(levels - 2):               # office floors: continuous ribbon windows
                for dz in (0, 1):
                    X, Y = cv.P(x, y, 8.5 + f * 3 + dz)
                    lit = h01("office", f, int(t) // 3) < 0.8
                    c = (WIN["office"] if dz == 0 else WIN["tv"]) if lit else WIN["dim"]
                    if int(t) % 3 == 0: c = WALL["plum"][1]
                    cv.on_face(X, math.floor(Y + .5), fid, c)
            for dz in (0.5, 1.5):
                X, Y = cv.P(x, y, z1 - dz)
                cv.on_face(X, math.floor(Y + .5), fid, NEON["magenta"][3] if dz < 1 else NEON["magenta"][1])
    x0, y0, x1, y1 = bbox(poly)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    k = min(x1 - x0, y1 - y0) / 2 - 3
    billboard_text(cv, cx - k, cy + k, z1, ["TINY", "REALTOR"], F3, NEON["magenta"])
    cv.office_pos = (cx, cy, z1)


def draw_construction(cv, poly, obj, p):
    levels_done = 4
    z_done = 4 + (levels_done - 1) * 3
    walls, rf = draw_prism(cv, poly, 0, z_done, "indigo", obj)
    windows_on(cv, walls, 0, levels_done, p["id"], "res", False, spacing=3)
    # scaffold cage for the next floors
    z_top = z_done + 5 * 3
    x0, y0, x1, y1 = bbox(poly)
    for a, b, side in visible_walls(poly):
        L = math.hypot(b[0] - a[0], b[1] - a[1])
        for t in np.arange(0, L + 0.01, 1.0):
            x = a[0] + (b[0] - a[0]) * t / L; y = a[1] + (b[1] - a[1]) * t / L
            for z in np.arange(z_done, z_top + 0.01, 1.0):
                vert = int(t) % 4 == 0
                horiz = int(z - z_done) % 3 == 0
                if vert or horiz:
                    X, Y = cv.P(x, y, z)
                    c = STEEL[2] if horiz else STEEL[1]
                    if horiz and int(t) % 7 == 3 and int(z) % 2 == 0: c = WIN["warm"]
                    cv.pix(X, math.floor(Y + .5), c, cv.D(x, y, z) + 0.5)
    # back edges of the cage too (thin)
    for (x, y) in [(x0, y0), (x0, y1), (x1, y0)]:
        for z in np.arange(z_done, z_top, 1.0):
            X, Y = cv.P(x, y, z); cv.pix(X, math.floor(Y + .5), STEEL[0], cv.D(x, y, z) - 1)
    # tower crane
    mx, my = sn(x0 + 2), sn(y1 - 2)
    hgt = z_top + 22
    X, Y = cv.P(mx, my, z_done); d = cv.D(mx, my, 0)
    X, Y = round(X), round(Y)
    for i in range(0, int(hgt - z_done)):
        cv.pix(X, Y - i, NEON["gold"][2] if i % 3 else STEEL[1], d + z_done + i)
        cv.pix(X + 1, Y - i, NEON["gold"][1] if (i % 3) else STEEL[0], d + z_done + i)
    jy = Y - int(hgt - z_done)
    for j in range(-10, 32):
        c = NEON["gold"][2] if j % 2 else STEEL[2]
        cv.pix(X + j, jy, c, d + hgt)
        if j > 0 and j % 4 == 0: cv.pix(X + j, jy + 1, STEEL[1], d + hgt)
    for j in range(-10, -5):
        cv.pix(X + j, jy + 1, STEEL[2], d + hgt); cv.pix(X + j, jy + 2, STEEL[2], d + hgt)
    for k in range(1, 14):   # hook cable + load
        cv.pix(X + 22, jy + k, STEEL[1], d + hgt)
    for dx in range(-1, 3):
        for dy in range(2):
            cv.pix(X + 21 + dx, jy + 14 + dy, NEON["gold"][2], d + hgt)
    cv.pix(X + 31, jy, RED, d + hgt + 1); cv.blinkers.append((X + 31, jy))
    cv.pix(X, jy - 1, RED, d + hgt + 1); cv.blinkers.append((X, jy - 1))
    tx, ty = cv.P((x0 + x1) / 2, (y0 + y1) / 2, z_top)
    cv.construction = (round(tx) - 14, round(ty) - 22)


# ---------------------------------------------------------------------------------------------
# HUD
# ---------------------------------------------------------------------------------------------
def panel(px, x0, y0, x1, y1, border, fill=INK, notch=True):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            edge = y in (y0, y1) or x in (x0, x1)
            if notch and (x, y) in ((x0, y0), (x1, y0), (x0, y1), (x1, y1)):
                continue
            px[y, x] = border if edge else fill


def neon_button(img, x, y, w, label, neon, icon=None):
    a = np.array(img)
    h = 13
    # glow halo
    for yy in range(y - 2, y + h + 2):
        for xx in range(x - 2, x + w + 2):
            if x <= xx < x + w and y <= yy < y + h: continue
            d = max(x - xx, 0, xx - (x + w - 1), y - yy, 0, yy - (y + h - 1))
            if d == 1 and bayer(xx, yy) < 0.5: a[yy, xx] = neon[1]
            if d == 2 and bayer(xx, yy) < 0.2: a[yy, xx] = neon[0]
    panel(a, x, y, x + w - 1, y + h - 1, neon[3], fill=INK)
    for xx in range(x + 1, x + w - 1):
        a[y + h - 2, xx] = neon[1]
    img2 = Image.fromarray(a)
    tw = text_w(label, F3)
    tx = x + (w - tw) // 2 + (4 if icon else 0)
    draw_text(img2, tx, y + 4, label, F3, neon[4])
    if icon == "up":
        ix, iy = tx - 7, y + 3
        for j, row in enumerate(["..X..", ".XXX.", "XXXXX", ".XXX.", ".XXX."]):
            for i, ch in enumerate(row):
                if ch == "X": img2.putpixel((ix + i, iy + j), neon[3])
    if icon == "key":
        ix, iy = tx - 7, y + 4
        for j, row in enumerate(["XX...", "XXXXX", "XX.X."]):
            for i, ch in enumerate(row):
                if ch == "X": img2.putpixel((ix + i, iy + j), neon[3])
    return img2


def hud(img, owned_n=7):
    a = np.array(img)
    W, H = img.size
    # top bar: dithered dark band
    for y in range(0, 24):
        for x in range(W):
            if y < 21 or bayer(x, y) < (24 - y) / 4:
                a[y, x] = INK if y < 21 or bayer(x, y) < 0.5 else hexc(C["n2"])
    for x in range(W):
        a[21, x] = NEON["gold"][1] if x % 2 else NEON["gold"][2]
    img = Image.fromarray(a)
    # coin icon
    px = np.array(img)
    big = ["..XXXX..", ".XBBXXX.", "XBXXXXXD", "XXX$$XXD", "XXX$$XXD", "XXXXXXXD", ".XXXXDD.", "..DDDD.."]
    for j, row in enumerate(big):
        for i, ch in enumerate(row):
            if ch == ".": continue
            c = {"X": NEON["gold"][3], "B": NEON["gold"][4], "D": NEON["gold"][2], "$": NEON["gold"][1]}[ch]
            px[4 + j, 5 + i] = c
    img = Image.fromarray(px)
    x = draw_text(img, 17, 3, "1.284.300", F5, NEON["gold"][3], shadow=NEON["gold"][0])
    draw_text(img, 17, 3, "1", F5, NEON["gold"][4])
    draw_text(img, x + 2, 3, "€", F5, NEON["gold"][2])
    draw_text(img, 17, 12, "+7.560 €/MIN", F3, NEON["cyan"][3])
    # right side: portfolio
    lbl = f"{owned_n} FINCAS"
    tw = text_w(lbl, F3)
    draw_text(img, W - 6 - tw, 4, lbl, F3, NEON["magenta"][3])
    lbl2 = "EIXAMPLE"
    draw_text(img, W - 6 - text_w(lbl2, F3), 12, lbl2, F3, STEEL[3])
    # bottom buttons
    img = neon_button(img, W - 118, H - 18, 54, "COMPRAR", NEON["gold"], icon="key")
    img = neon_button(img, W - 60, H - 18, 54, "MEJORAR", NEON["magenta"], icon="up")
    # credit
    a = np.array(img)
    for y in range(H - 9, H):
        for x in range(0, 120):
            if bayer(x, y) < 0.75: a[y, x] = INK
    img = Image.fromarray(a)
    draw_text(img, 3, H - 7, "© OPENSTREETMAP CONTRIBUTORS", F3, STEEL[2])
    return img


def sale_label(img, cv):
    X, Y = cv.sale_tag
    s1, s2 = "SE VENDE", "85.000 €"
    w = max(text_w(s1, F3), text_w(s2, F3)) + 6
    x0, y0 = X - w // 2, Y + 20
    a = np.array(img)
    panel(a, x0, y0, x0 + w - 1, y0 + 15, RED, fill=INK)
    for k in range(3):   # little pointer
        for dx in range(-2 + k, 3 - k):
            a[y0 - 1 - k, X + dx] = RED if k < 2 else RED_D
    img = Image.fromarray(a)
    draw_text(img, x0 + 3, y0 + 2, s1, F3, WHITE)
    draw_text(img, x0 + 3, y0 + 9, s2, F3, NEON["gold"][3])
    return img


def construction_label(img, cv):
    X, Y = cv.construction
    a = np.array(img)
    panel(a, X - 2, Y - 2, X + 29, Y + 8, NEON["magenta"][2], fill=INK)
    for i in range(26):
        for j in range(2):
            a[Y + 4 + j, X + 1 + i] = NEON["magenta"][3] if i < 16 else STEEL[0]
    img = Image.fromarray(a)
    draw_text(img, X + 1, Y - 1 + 0, "62%", F3, NEON["magenta"][4])
    draw_text(img, X + 16, Y - 1, "6>7", F3, STEEL[3])
    return img


# ---------------------------------------------------------------------------------------------
# TIERS STRIP
# ---------------------------------------------------------------------------------------------
def render_tiers():
    """same plot at every tier, each on a small floating diorama tile"""
    PW, PH = 84, 184
    W, H = PW * 6, PH
    strip = Image.new("RGB", (W, H), INK)
    plot = rect(0, 0, 22, 22)
    island = rect(-6, -6, 28, 28)
    for t in range(6):
        cv = make_canvas(PW, PH, PW // 2 - 11, PH - 52 + 11)
        for x, y in ((-3, -3), (25, 25), (-3, 25)):
            cv.add_light(x, y, 10, 1.0)
        if t > 0:
            cv.add_neon("gold", 11, 11, 20, 0.75)
        tier_lights(cv, plot, t)
        g = tier_ground(plot, t) if t <= 2 else [(plot, "court")]
        paint_ground(cv, [], [], [(rect(-1, -1, 23, 23), "curb")] + g)
        # cut the island out of the void + extrude its sides
        m = Image.new("1", (PW, PH), 0)
        ImageDraw.Draw(m).polygon([tuple(map(round, cv.P(x, y))) for x, y in island], fill=1)
        m = np.array(m, bool)
        YY, XX = np.mgrid[0:PH, 0:PW]
        bg = np.where((BAYER[YY & 3, XX & 3] < (YY / PH) * 0.5)[..., None], np.array(hexc(C["n1"]), np.uint8),
                      np.array(INK, np.uint8))
        cv.col[~m] = bg[~m]
        for a, b, side in visible_walls(island):
            cv.face([(a[0], a[1], -5), (b[0], b[1], -5), (b[0], b[1], 0), (a[0], a[1], 0)],
                    hexc(C["n2"]) if side == "L" else hexc(C["n1"]), obj=None, kind="slab")
            L = math.hypot(b[0] - a[0], b[1] - a[1])
            for tt in np.arange(0, L, 1.0):   # gold/magenta trim line on the slab edge
                x = a[0] + (b[0] - a[0]) * tt / L; y = a[1] + (b[1] - a[1]) * tt / L
                X, Y = cv.P(x, y, -1)
                xi, yi = round(X), math.floor(Y + .5)
                if 0 <= xi < PW and 0 <= yi < PH:
                    cv.col[yi, xi] = (NEON["gold"][2] if t else NEON["magenta"][2])
        obj = Obj(f"tier{t}", owned=t > 0)
        draw_tier(cv, plot, t, f"tierseed{t}", obj, t > 0)
        lamp(cv, -3, -3); lamp(cv, 25, 25); lamp(cv, -3, 25)
        tree(cv, -3, 6, "t1"); tree(cv, -3, 14, "t2"); tree(cv, 6, 25, "t3"); tree(cv, 16, 25, "t4")
        if t > 0:
            owned_glow(cv, [obj], "gold")
        for left, top, w, h, neon in cv.signs:
            halo(cv, (left, top, w, h), neon)
        for X, Y in cv.blinkers:
            point_glow(cv, int(X), int(Y), RED, [RED_D, RED_D, RED], 2)
        for X, Y in cv.lamp_heads:
            point_glow(cv, int(X), int(Y), WIN["hot"], [WIN["warm"], WIN["warm"], WIN["yellow"]], 1)
        img = Image.fromarray(cv.col)
        name = TIER_NAMES[t]
        draw_text(img, (PW - text_w(name, F3)) // 2, PH - 19, name, F3, NEON["gold"][3] if t else NEON["magenta"][3])
        sub = (TIER_RENT[t] + " €/MIN") if t else "SE VENDE"
        draw_text(img, (PW - text_w(sub, F3)) // 2, PH - 11, sub, F3, NEON["cyan"][3] if t else STEEL[3])
        a = np.array(img)
        for i in range(6):   # tier pips
            on = t > 0 and i <= t
            for dx in range(3):
                for dy in range(2):
                    a[PH - 25 + dy, PW // 2 - 17 + i * 6 + dx] = NEON["gold"][3] if on else STEEL[0]
        if t:
            num = str(t)
        strip.paste(Image.fromarray(a), (t * PW, 0))
    return strip


def main():
    os.makedirs(OUT, exist_ok=True)
    img, cv = render_city()
    img = construction_label(img, cv)
    img = sale_label(img, cv)
    img = hud(img)
    img = snap_palette(img)
    big = img.resize((600, 600), Image.NEAREST)
    big.save(os.path.join(OUT, "city_600.png"))
    # closeup: 2x of a 300x300 crop of the 600 view (=4x the base pixel)
    cx, cy = 300, 300
    if hasattr(cv, "office_pos"):
        X, Y = cv.P(*cv.office_pos)
        cx, cy = int(X * 2) + 40, int(Y * 2) - 20
    cx = min(max(cx, 150), 450); cy = min(max(cy, 150), 450)
    crop = big.crop((cx - 150, cy - 150, cx + 150, cy + 150)).resize((600, 600), Image.NEAREST)
    crop.save(os.path.join(OUT, "closeup_2x.png"))
    strip = snap_palette(render_tiers())
    strip.resize((strip.width * 3, strip.height * 3), Image.NEAREST).save(os.path.join(OUT, "tiers.png"))
    print("palette size", len(PALETTE))


if __name__ == "__main__":
    main()
