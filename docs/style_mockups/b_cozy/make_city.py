"""Tiny Realtor - 'Cozy pastel diorama' style mockup: the in-game 600x600 view.
A floating diorama chunk cut around the Pau Claris x Consell de Cent intersection (Eixample),
built from realestate/data/block_saved.json.   usage: python3 make_city.py
"""
import json, math, os, sys
import numpy as np
from PIL import Image
from shapely.geometry import Polygon, box as sbox
from shapely import contains_xy

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from engine import Scene, PAL, h01, ihash
import buildings as B
from ui import draw_sky, draw_float_shadow, hud, outline_silhouette

DATA = os.path.join(HERE, "..", "..", "realestate", "data", "block_saved.json")
D = json.load(open(DATA))

W = H = 300
S, SZ = 1.45, 1.33
TX0, TX1, TY0, TY1 = 98.0, 200.0, -36.0, 52.0
TILE = sbox(TX0, TY0, TX1, TY1)
SLAB = 14
sc = Scene(W, H, S, SZ, ((TX0 + TX1) / 2, (TY0 + TY1) / 2), (150, 186))


def octo(x0, y0, x1, y1, c=14):
    return Polygon([(x0 + c, y0), (x1 - c, y0), (x1, y0 + c), (x1, y1 - c), (x1 - c, y1), (x0 + c, y1), (x0, y1 - c), (x0, y0 + c)])


# Eixample manzanas around the crossing: building-line octagons (14 m chamfers)
OCTS = [octo(31, 11, 139, 124), octo(31, -122, 139, -9), octo(159, -122, 273, -9), octo(159, 11, 273, 124)]
SIDEWALKS = [o.buffer(5.0, join_style=2) for o in OCTS]
OFFICE_C = (131.0, 19.0)
RADIUS = 60.0

ROLE = {
    "w900039636": "office",
    "w900041288": "apt_owned",
    "w900041645": "skyscraper",
    "w900024939": "tower",
    "w900028597": "lot",
    "w900030468": "apt",
    "w900044301_1": "estate",
    "w900044301_0": "construction",
    "w900044301_2": "house",
    "w900044301_3": "park",
}
DROP = {"w900041928", "w900044301_12", "w900030981", "w900025956", "w900044208", "w900040890"}
FACS = ["cre", "pea", "sky", "ros", "but", "min"]


def clip(poly):
    g = Polygon(poly).intersection(TILE)
    if g.is_empty or g.geom_type != "Polygon" or g.area < 20: return None
    g = g.simplify(0.05)
    return [(round(x, 2), round(y, 2)) for x, y in list(g.exterior.coords)[:-1]]


plots = {}
for p in D["plots"]:
    if p["id"] in DROP or not Polygon(p["poly"]).intersects(TILE): continue
    cp = clip(p["poly"])
    if cp: plots[p["id"]] = dict(p, cpoly=cp)


def bounds(poly):
    xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
    return min(xs), min(ys), max(xs), max(ys)


# ------------------------------------------------------------------ ground ----------
def ground():
    Ys, Xs = np.mgrid[0:H, 0:W]
    gx, gy = sc.unproj(Xs.astype(float), Ys.astype(float))
    inside = (gx >= TX0) & (gx <= TX1) & (gy >= TY0) & (gy <= TY1)
    cls = np.zeros((H, W), np.int8)      # 1 road 2 sidewalk 3 grass 4 patio 5 dirt 6 sand 7 water 8 stone
    cls[inside] = 1
    for swp in SIDEWALKS: cls[inside & contains_xy(swp, gx, gy)] = 2
    for o in OCTS: cls[inside & contains_xy(o, gx, gy)] = 4
    for pid, p in plots.items():
        role = ROLE.get(pid, "apt")
        g = Polygon(p["cpoly"])
        if role in ("house", "estate", "park"):
            cls[inside & contains_xy(g, gx, gy)] = 3
        elif role == "lot":
            cls[inside & contains_xy(g.buffer(-0.4), gx, gy)] = 5
    cls[inside & (gx > 99) & (gx < 112) & (gy > 37) & (gy < 52)] = 3          # back courtyard garden
    cls[inside & (gx > 165.3) & (gx < 176.2) & (gy > 13.3) & (gy < 18.7)] = 8  # estate pool rim
    cls[inside & (gx > 166) & (gx < 175.5) & (gy > 14) & (gy < 18)] = 7
    cls[inside & (gx > 186.8) & (gx < 188.4) & (gy > 10.5) & (gy < 16.5)] = 6  # house path
    cls[inside & (gx > 194) & (np.abs(gy - 22) < 1.0)] = 6                    # park path
    dd = np.hypot(gx - 197.5, gy - 22)
    cls[inside & (dd < 2.6) & (gx > 194)] = 8
    cls[inside & (dd < 1.7) & (gx > 194)] = 7

    lit = np.zeros((H, W, 3), np.uint8); shd = np.zeros((H, W, 3), np.uint8)

    def paint(mask, ln, sn):
        lit[mask] = PAL[ln]; shd[mask] = PAL[sn]

    tex = ihash(Xs, Ys, 21)
    paint(cls == 1, "asp", "aspX")
    paint((cls == 1) & (tex < 0.06), "asp2", "aspX")
    paint(cls == 2, "pavL", "pavX")
    paint((cls == 2) & ((((Xs + 2 * Ys) % 8) == 0) | (((Xs - 2 * Ys) % 8) == 0)), "pavP", "pavXP")
    paint(cls == 4, "pavP", "pavXP")
    paint((cls == 4) & ((((Xs + 2 * Ys) % 6) == 0) | (((Xs - 2 * Ys) % 6) == 0)), "sand", "sandX")
    paint(cls == 3, "grsL", "grsX")
    paint((cls == 3) & (tex < 0.10), "grsH", "grsX")
    paint((cls == 3) & (tex > 0.88), "grsM", "grsXX")
    paint(cls == 5, "dirL", "dirX")
    paint((cls == 5) & (tex < 0.14), "dirM", "dirX")
    paint((cls == 5) & (tex > 0.95), "grsM", "grsX")
    paint(cls == 6, "sand", "sandX")
    paint(cls == 7, "watM", "watX")
    paint((cls == 7) & ((((Xs + 2 * Ys) // 2) % 5) == 0), "watL", "watM")
    paint(cls == 8, "stone", "stoneD")
    up = np.roll(cls, 1, 0); dn = np.roll(cls, -1, 0); lf = np.roll(cls, 1, 1); rt = np.roll(cls, -1, 1)
    paint((cls == 2) & ((dn == 1) | (lf == 1) | (rt == 1) | (up == 1)), "curb", "curbD")
    paint((cls == 1) & (up == 2), "curbD", "aspX")
    paint((cls == 3) & (dn != 3) & (dn != 0), "grsM", "grsXX")

    road = cls == 1
    band = lambda v, c: (v >= c) & (v < c + 1 / S)
    near = (np.abs(gx - 149) < 16) & (np.abs(gy - 1) < 16)
    lanes = (road & band(gy, 0.6) & ((gx % 6) < 3) & ~near) | (road & band(gx, 148.8) & ((gy % 6) < 3) & ~near)
    paint(lanes, "mark", "markX")
    zx = lambda a, b: road & (gx >= a) & (gx <= b) & ((np.floor(gy * S) % 2) == 0) & (np.abs(gy - 1) < 6)
    zy = lambda a, b: road & (gy >= a) & (gy <= b) & ((np.floor(gx * S) % 2) == 0) & (np.abs(gx - 149) < 6)
    for m in (zx(127.5, 131), zx(167, 170.5), zy(-17, -13.5), zy(15.5, 19)):
        paint(m, "mark", "markX")
    bike = road & (gy > 4.2) & (gy < 5.6) & ~near
    paint(bike, "minM", "minX")
    paint(bike & ((gx % 5) < 0.7), "white", "minD")
    # office radius: dashed teal ring + inner glow + sparse sparkle tint
    dr = np.hypot(gx - OFFICE_C[0], gy - OFFICE_C[1])
    ang = np.arctan2(gy - OFFICE_C[1], gx - OFFICE_C[0])
    dash = ((ang * RADIUS / 2.6) % 3) < 2.0
    paint(inside & (dr >= RADIUS - 1 / S) & (dr < RADIUS) & dash, "teaH", "teaL")
    paint(inside & (dr >= RADIUS) & (dr < RADIUS + 2 / S) & dash, "teaL", "teaD")
    paint(inside & (dr >= RADIUS + 2 / S) & (dr < RADIUS + 3 / S) & dash, "teaD", "teaX")
    sp = inside & (dr < RADIUS - 2) & ((Xs % 4) == 0) & ((Ys % 4) == 0) & (((Xs // 4 + Ys // 4) % 2) == 0)
    paint(sp & ((cls == 2) | (cls == 4)), "teaH", "pavXP")
    m = cls > 0
    Y_, X_ = np.nonzero(m)
    sc.write(X_, Y_, (gx - gy)[m], lit[m], shd[m], gx[m], gy[m], np.zeros(m.sum()), True, 1)


def slab_sides():
    B.slab_sides(sc, TX0, TY0, TX1, TY1, SLAB)


# ------------------------------------------------------------------ buildings -------
TAGS = {}


def build_all():
    owned = []
    sc.pins = []
    for k, (pid, p) in enumerate(sorted(plots.items())):
        oid = 11 + k
        role = ROLE.get(pid, "apt")
        poly = p["cpoly"]
        x0, y0, x1, y1 = bounds(poly)
        seed = int(''.join(ch for ch in pid if ch.isdigit())) % 100000
        if role == "apt":
            fac = FACS[int(h01(pid, "fac") * len(FACS))]
            aw = ["cor", "tea", "but", "sky"][int(h01(pid, "aw") * 4)]
            B.build_apartment(sc, poly, p["levels"], fac, seed, owned=False, awning=aw, oid=oid)
        elif role == "apt_owned":
            h = B.build_apartment(sc, poly, 7, "min", seed, owned=True, awning="tea", oid=oid)
            sc.pins.append((x0 + (x1 - x0) * 0.5, y0 + (y1 - y0) * 0.45, h + 6)); owned.append(pid)
        elif role == "office":
            build_office(poly, oid)
        elif role == "skyscraper":
            top = B.build_skyscraper(sc, 113.5, 38.0, 136.5, 51.5, seed, owned=True, oid=oid, floors=22)
            sc.pins.append((125.0, 44.7, top + 4)); owned.append(pid)
        elif role == "tower":
            h = (B.GF + B.FL * 14 + 1) / SZ           # glass tower keeps the Eixample chamfered footprint
            sc.prism(poly, 0, h, B.tower_wall, B.roof_garden, oid=oid, acc="pea", owned=True)
            B.tree(sc, x0 + 4, y0 + 4, h, r=2, th=1, seed=61)
            B.tree(sc, x0 + 12, y0 + 3.5, h, r=3, th=1, seed=62)
            B.parasol(sc, x0 + 8, y0 + 13, h, "corL")
            sc.box(x0 + 3, y1 - 8, x0 + 9, y1 - 3, h, h + 3, B.plain_wall(("frmL", "frmL", "frmD", "gtX")), B.plain_top("teaL", "teaD"))
            B.flag(sc, x1 - 4.0, y0 + 1.5, h)
            sc.pins.append(((x0 + x1) / 2, (y0 + y1) / 2, h + 7)); owned.append(pid)
        elif role == "lot":
            g = Polygon(poly).centroid
            sc.sprite(["ccccc", "cWWWc", "ccccc", "..|..", "..|.."], {"c": ("corL", "corD"), "W": ("white", "uiD"), "|": ("ink2", "ink2")},
                      g.x + 2, g.y - 6, 0, 2, 4, bias=1.0)
            for t in np.linspace(0, 1, 9):
                sc.pixels([(0, 0, "trunk", "trunkD"), (0, -1, "white", "uiD")], x0 + 13 + t * (x1 - x0 - 14), y0 + 0.8, 0, bias=0.4)
            for t in np.linspace(0, 1, 7):
                sc.pixels([(0, 0, "trunk", "trunkD"), (0, -1, "white", "uiD")], x1 - 0.8, y0 + 0.8 + t * (y1 - y0 - 14), 0, bias=0.4)
            for kk in range(6):
                B.tree(sc, x0 + 3 + h01(pid, kk) * (x1 - x0 - 6), y0 + 3 + h01(pid, kk, 1) * (y1 - y0 - 6), r=1, kind="bush", seed=kk + 40, shadow=False)
            TAGS["lot"] = (g.x, g.y, 2.0)
        elif role == "estate":
            B.build_estate(sc, 162.5, 19.5, 176.5, 27.0, seed, fac="ros", owned=True, oid=oid)
            B.tree(sc, 177.5, 13.0, th=12, kind="palm", seed=3)
            B.tree(sc, 163.0, 12.5, th=10, kind="palm", seed=4)
            B.tree(sc, 180.0, 26.0, r=2, kind="cypress", seed=5)
            B.parasol(sc, 178.0, 17.5, 0, "teaL")
            hedge_l(159.6, 11.6, 181.6, 27.6)
            B.flag(sc, 180.5, 12.4, 0, h=8)
            sc.pins.append((169.5, 23.3, 14.5)); owned.append(pid)
        elif role == "construction":
            top = B.build_construction(sc, 161.0, 30.0, 180.5, 49.5, seed, oid=oid, built=6)
            B.crane(sc, 184.5, 44.0, 0, 68, jib_dir=(-1, -1), jib_len=22)
            TAGS["cons"] = (170.75, 39.75, top)
            owned.append(pid)
        elif role == "house":
            B.build_house(sc, 183.5, 16.5, 192.5, 27.0, seed, fac="pea", owned=True, oid=oid)
            B.tree(sc, 191.5, 31.5, r=3, th=4, seed=15)
            B.tree(sc, 184.0, 31.0, r=2, th=3, seed=16)
            B.tree(sc, 193.0, 12.5, r=1, kind="bush", seed=17)
            B.tree(sc, 184.0, 12.5, r=1, kind="bush", seed=18)
            fence_x(182.4, 193.6, 10.6)
            B.person(sc, 187.5, 11.5, 3)
            B.flag(sc, 193.2, 15.0, 0, h=8)
            sc.pins.append((188.0, 21.7, 13)); owned.append(pid)
        elif role == "park":
            for i, (x, y, r) in enumerate([(197.5, 30, 3), (196.5, 14, 2)]):
                B.tree(sc, x, y, r=r, th=4, seed=80 + i)
            B.bench(sc, 197.0, 25.5, "x")
    return owned


def build_office(poly, oid):
    h = B.levels_to_h(6) / SZ
    b = dict(fac="cre", seed=77, owned=True, shop=True, awning="tea", shut=1.0, shutc="teaL", shutcD="teaD")
    sc.prism(poly, 0, h, B.apt_wall, B.flat_roof, oid=oid, b=b)
    cx, cy = 133.6, 16.4                 # corner turret (tribuna) protruding from the chamfer, teal dome

    def oc(r):
        return [(cx + r * math.cos(math.radians(22.5 + 45 * k)), cy + r * math.sin(math.radians(22.5 + 45 * k))) for k in range(8)]
    tb = dict(fac="cre", seed=78, owned=True, shop=False, shut=1.0, shutc="teaL", shutcD="teaD", period=2)
    zt = h + 5 / SZ
    sc.prism(oc(4.4), 0, zt, B.apt_wall, B.plain_top("teaL", "teaD"), oid=oid, b=tb)
    z = zt
    for r in [4.4, 3.9, 3.2, 2.3, 1.3]:
        sc.prism(oc(r), z, z + 1.0, B.plain_wall(("teaL", "teaL", "teaD", "teaX")), B.plain_top("teaH", "teaL"), oid=oid, lip=False)
        z += 1.0
    sc.box(cx - .35, cy - .35, cx + .35, cy + .35, z, z + 3, B.plain_wall(("golL", "golL", "golD", "golD")), B.plain_top("golH", "golL"), lip=False)
    B.sign_board(sc, 121.0, 30.5, h, "TINY\nREALTOR", fg="corL", bg="uiL", frame="teaD", pad=2, legs=3, bias=3)
    B.potted(sc, 116.5, 14.0, h, 3)
    B.potted(sc, 135.5, 33.5, h, 5)
    B.flag(sc, 136.5, 26.0, h, h=9)


def fence_x(xa, xb, y):
    x = xa
    while x <= xb:
        sc.pixels([(0, 0, "white", "uiD"), (0, -1, "white", "uiD"), (0, -2, "white", "uiD")], x, y, 0, bias=0.3)
        x += 0.75


def hedge_l(x0, y0, x1, y1):
    sc.box(x0, y0, x1, y0 + 0.9, 0, 1.6, _hedge, _hedge_top)


def _hedge(c):
    t = 0 if c.sun > 0.45 else (1 if c.sun > -0.25 else 2)
    n = len(c.X)
    lit = np.repeat(B.P([("leL", "leM", "leD")[t]]), n, 0); shd = np.repeat(B.P(["leX"]), n, 0)
    lit[ihash(c.X, c.Y, 3) < 0.2] = PAL[("leM", "leD", "leX")[t]]
    lit[ihash(c.X, c.Y, 4) < 0.07] = PAL["flwP"]
    return lit, shd


def _hedge_top(c):
    n = len(c.X)
    lit = np.repeat(B.P(["leH"]), n, 0); shd = np.repeat(B.P(["leD"]), n, 0)
    lit[ihash(c.X, c.Y, 5) < 0.3] = PAL["leL"]
    return lit, shd, True


# ------------------------------------------------------------------ street life ------
def street_life():
    def row(fixed, a, b, axis, step=7.5, seed=0, lamps=True):
        t, k = a, 0
        while t <= b:
            x, y = (t, fixed) if axis == "x" else (fixed, t)
            if lamps and k % 2 == 1:
                B.lamp(sc, x + (2.0 if axis == "x" else 0), y + (0 if axis == "x" else 2.0))
            B.tree(sc, x, y, r=3 if h01(seed, k) < 0.6 else 2, th=4, seed=seed * 100 + k)
            t += step; k += 1
    row(7.6, 100, 121, "x", seed=1)
    row(-12.6, 100, 121, "x", seed=2)
    row(-12.6, 178, 199, "x", seed=3)
    row(7.6, 178, 199, "x", seed=4, lamps=False)
    row(142.6, 29, 51, "y", seed=5)
    row(142.6, -35, -28, "y", seed=6)
    row(155.6, -35, -28, "y", seed=7)
    row(155.6, 29, 51, "y", seed=8)
    B.tree(sc, 103, 47, r=4, th=4, seed=200)
    B.tree(sc, 109.5, 41, r=3, th=4, seed=201)
    B.tree(sc, 100.5, 40, r=2, kind="cypress", seed=300)
    for i, x in enumerate([103.0, 107.0, 111.0]):           # cafe terrace
        B.parasol(sc, x, -12.0, 0, ["corL", "golL", "corL"][i])
    spots = [(102, -11.0), (106, -12.5), (110, -11.2), (116, -12.0), (124, -14.5), (141.5, -20), (143.5, -31), (157, -18),
             (156, -31), (176, -11.0), (190, -11.5), (141, 30), (143.5, 44), (156.5, 36), (155, 48), (120, 8.5), (110, 7.0),
             (133, 6.5), (146, 7.5), (152, -7.5), (186, 7.0), (196, 8.0), (101.5, 8.2), (171, -13.5), (162, -6.8),
             (129.5, -1.0), (130.0, 3.5), (168.5, 2.0), (148.0, -15.0), (150.5, 17.0), (145.0, 17.5), (134.5, 9.0), (137.5, 12.5)]
    for i, (x, y) in enumerate(spots):
        B.person(sc, x, y, 500 + i)
    cars = [(110, -2.0, "x"), (124, 3.0, "x", True), (178, -2.0, "x"), (194, 2.6, "x"),
            (146.5, 34, "y"), (151.5, 46, "y", True), (146.5, -27, "y"), (151.5, -20, "y"), (139.5, 0.6, "x"),
            (151.0, 8.0, "y"), (160.5, -1.5, "x", True), (146.8, 20.5, "y")]
    for i, cdat in enumerate(cars):
        B.car(sc, cdat[0], cdat[1], cdat[2], 700 + i, taxi=len(cdat) > 3)


def main():
    ground()
    slab_sides()
    owned = build_all()
    street_life()
    sc.shadows((TX0 - 2, TY0 - 2, TX1 + 2, TY1 + 2), elevs=(48, 44), azim_off=(0, 4))
    out = sc.compose()
    bg = draw_sky(W, H)
    draw_float_shadow(bg, sc, (TX0, TY0, TX1, TY1), SLAB)
    m = sc.kind == 0
    out[m] = bg[m]
    out = outline_silhouette(out, sc.kind)
    TAGS["pops"] = [(108.0, 30.0, 40.0, "+320"), (182.0, 2.0, 20.0, "+95")]
    hud(out, sc, owned, TAGS)
    img = Image.fromarray(out, "RGB")
    img.resize((600, 600), Image.NEAREST).save(os.path.join(HERE, "city_600.png"))
    img.save(os.path.join(HERE, "city_lowres.png"))
    cx, cy = 152, 150
    img.crop((cx - 75, cy - 75, cx + 75, cy + 75)).resize((600, 600), Image.NEAREST).save(os.path.join(HERE, "closeup_2x.png"))
    print("ok colours:", len({tuple(c) for c in out.reshape(-1, 3)}), "owned:", len(owned))


if __name__ == "__main__":
    main()
