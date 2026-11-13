"""Procedural building tiers + props for the cozy pastel diorama style."""
import math
import numpy as np
from engine import PAL, FACADES, h01, ihash, F35, SUN_H

GF = 5          # ground-floor height in px
FL = 4          # upper floor height in px
CORN = 2        # cornice rows


def levels_to_h(levels):
    return GF + FL * max(0, levels - 1) + CORN


def P(names):
    return np.array([PAL[n] for n in names], np.uint8)


def tone(c):
    return 0 if c.sun > 0.45 else (1 if c.sun > -0.25 else 2)


SHIFT = {0: 2, 1: 2, 2: 3}


def wall_coords(c):
    A, B, z0 = c.info["A"], c.info["B"], c.info["z0"]
    sc = c.scene
    XA, YA = sc.proj(A[0], A[1], z0); XB, YB = sc.proj(B[0], B[1], z0)
    if XA > XB: XA, YA, XB, YB = XB, YB, XA, YA
    dxs = max(XB - XA, 1e-6)
    r = np.floor((c.z - z0) * sc.SZ + 1e-4).astype(int)
    if abs(YB - YA) < 0.2 * dxs:
        colm = c.X - int(math.floor(XA + 0.5))
        pair = colm // 2; sub = colm % 2
        npairs = max(1, int(round(dxs / 2)))
    else:
        slope = (YB - YA) / dxs
        fb = np.floor(YA + (c.X - XA) * slope + 1e-6)
        f0 = math.floor(YA + 1e-6)
        pair = np.abs(fb - f0).astype(int)
        prev = np.floor(YA + (c.X - 1 - XA) * slope + 1e-6)
        sub = (prev == fb).astype(int)
        npairs = int(abs(math.floor(YB + 1e-6) - f0)) + 1
    return r, pair, sub, npairs


def ramp_cols(ramp, t, codes_lit, codes_shd=None):
    pass


# ======================================================================================
# apartment block (Eixample-style) facade
# ======================================================================================
def apt_wall(c):
    b = c.info["b"]
    t = tone(c)
    F = FACADES[b["fac"]]
    r, pair, sub, npairs = wall_coords(c)
    n = len(r)
    Htot = int(round((c.info["z1"] - c.info["z0"]) * c.scene.SZ))
    lit = np.repeat(P([F[t]]), n, 0); shd = np.repeat(P([F[SHIFT[t]]]), n, 0)

    def paint(mask, ln, sn):
        lit[mask] = PAL[ln]; shd[mask] = PAL[sn]

    seed = b["seed"]
    per = b.get("period", 3)
    first = 1 if npairs >= 3 else 0
    last = npairs - 2 if npairs >= 3 else npairs - 1
    span = last - first
    off = first + (span % per) // 2
    win = (pair >= first) & (pair <= last) & (((pair - off) % per) == 0)
    if npairs <= 2: win = pair == 0
    upper = (r >= GF) & (r < Htot - CORN)
    rr = (r - GF) % FL
    fl = (r - GF) // FL
    gl, gd = ("glaL", "glaD") if t < 2 else ("glaD", "glaX")
    # shutters
    hs = ihash(pair * 7 + edge_seed(c), fl, seed % 997)
    shut_side = (~win) & upper & (rr >= 1) & (rr <= 2)
    lw = ((pair - 1 - off) % per == 0)          # pillar right after a window -> its left col is shutter
    rw = ((pair + 1 - off) % per == 0)
    shut = shut_side & (((lw & (sub == 0)) & (ihash(pair - 1, fl, seed) < b.get("shut", .18))) |
                        ((rw & (sub == 1)) & (ihash(pair + 1, fl, seed) < b.get("shut", .18))))
    shut &= (pair >= first) & (pair <= last)
    sh_l, sh_d = (b.get("shutc", "shut"), b.get("shutcD", "shutD"))
    paint(shut, sh_l if t < 2 else sh_d, sh_d)
    glass = upper & win & (rr >= 1) & (rr <= 2)
    paint(glass, gl, gd)
    # reflections / lit windows
    refl = glass & (rr == 2) & (sub == 0) & (ihash(pair, fl, seed + 3) < 0.35)
    paint(upper & win & (rr == 3) & (ihash(pair, fl, seed + 5) < 0.0), gl, gd)
    paint(refl, "glaH" if t < 2 else "glaL", gl)
    adj = ((lw & (sub == 0)) | (rw & (sub == 1))) & (pair >= first) & (pair <= last)
    balc = upper & (rr == 0) & (win | adj)
    princ = upper & (fl == 0) & (rr == 0) & (pair >= first) & (pair <= last)   # 'balcon corregut' on the 1st floor
    ll = "white" if t == 0 else F[max(0, t - 1)]
    rail = balc | princ
    paint(rail, ll, F[min(3, t + 1)])
    paint(rail & ((c.X % 2) == 0), "rail" if t < 2 else F[3], "rail")
    # plant pots / flowers on some balconies
    pl = upper & (rr == 1) & adj & (ihash(pair * 3 + sub, fl, seed + 9) < 0.16)
    paint(pl, "leL" if t < 2 else "leM", "leD")
    fw = pl & (ihash(pair, fl * 5 + sub, seed + 11) < 0.45)
    paint(fw, "flwP" if seed % 2 else "flwY", "rosD")
    # ground floor shops
    gfm = r < GF
    if b.get("shop", True):
        shopg = gfm & (r <= 3) & win
        paint(shopg, "glaX" if t < 2 else "glaX", "glaX")
        shoph = shopg & (r == 3) & (sub == 0)
        paint(shoph, "glaD", "glaX")
        aw = b.get("awning", "cor")
        awn = gfm & (r == GF - 1) & (pair >= first) & (pair <= last)
        awn2 = gfm & (r == GF - 2) & (pair >= first) & (pair <= last) & (sub == 0) & win
        stripe = (pair * 2 + sub) % 2 == 0
        a1 = {"cor": ("corL", "corD"), "tea": ("teaL", "teaD"), "but": ("golL", "golD"), "sky": ("gtM", "gtD")}[aw]
        paint(awn & stripe, a1[0] if t < 2 else a1[1], a1[1])
        paint(awn & ~stripe, "white" if t < 2 else "uiD", "uiD")
        paint(awn2, a1[0] if t < 2 else a1[1], a1[1])
    else:
        door = gfm & (r <= 3) & win
        paint(door, gd, "glaX")
    # plinth
    paint((r == 0) & ~(gfm & win & b.get("shop", True)), F[min(3, t + 1)], F[3])
    # cornice
    paint(r >= Htot - 1, "white" if t == 0 else F[max(0, t - 1)], F[t + 1 if t < 3 else 3])
    paint(r == Htot - CORN, F[min(3, t + 1)], F[3])
    return lit, shd


def edge_seed(c):
    return int(c.info.get("edge_i", 0)) * 13


def flat_roof(c):
    b = c.info["b"]
    n = len(c.X)
    X, Y = c.X, c.Y
    lit = np.repeat(P(["terL"]), n, 0); shd = np.repeat(P(["terD"]), n, 0)
    grout = ((X + 2 * Y) % 6 == 0) | ((X - 2 * Y) % 6 == 0)
    lit[grout] = PAL["terM"]; shd[grout] = PAL["terX"]
    if b.get("roof_hi", True):
        sp = (ihash(X, Y, 5) < 0.06) & ~grout
        lit[sp] = PAL["terH"]
    inner = (~c.edge) & (c.e_up2 | c.e_l2)
    lit[inner] = PAL["terD"]; shd[inner] = PAL["terX"]
    cop_l, cop_d = ("teaL", "teaD") if b.get("owned") else ("white", "creD")
    cop_l2 = "teaH" if b.get("owned") else "white"
    lit[c.edge] = PAL[cop_l]; shd[c.edge] = PAL[cop_d]
    top = c.edge & (c.e_up | c.e_l)
    lit[top] = PAL[cop_l2]
    return lit, shd, True


def plain_wall(names):
    """walls with a single ramp (props, huts)"""
    def sh(c):
        t = tone(c)
        n = len(c.X)
        r = np.floor((c.z - c.info["z0"]) * c.scene.SZ + 1e-4).astype(int)
        lit = np.repeat(P([names[t]]), n, 0); shd = np.repeat(P([names[SHIFT[t]]]), n, 0)
        Ht = int(round((c.info["z1"] - c.info["z0"]) * c.scene.SZ))
        top = r >= Ht - 1
        if c.info.get("lip", True):
            lit[top] = PAL[names[max(0, t - 1)]]
        d = c.info.get("door")
        if d is not None and t == 0:
            r_, pair, sub, npairs = wall_coords(c)
            dm = (r <= 1) & (pair == min(npairs - 1, 1)) & (sub == 0)
            lit[dm] = PAL[d]; shd[dm] = PAL[d]
        return lit, shd
    return sh


def plain_top(lname, sname, edge_l=None, edge_s=None):
    def sh(c):
        n = len(c.X)
        lit = np.repeat(P([lname]), n, 0); shd = np.repeat(P([sname]), n, 0)
        if edge_l:
            lit[c.edge] = PAL[edge_l]; shd[c.edge] = PAL[edge_s or sname]
        return lit, shd, True
    return sh


# ======================================================================================
# roof props
# ======================================================================================
def roof_props(sc, poly, z, seed, owned=False, big=True):
    from shapely.geometry import Polygon, box as sbox
    g = Polygon(poly).buffer(-1.6)
    if g.is_empty: return
    minx, miny, maxx, maxy = g.bounds
    placed = []
    def try_place(w, d, tag):
        for k in range(12):
            cx = minx + h01(seed, tag, k, "x") * (maxx - minx)
            cy = miny + h01(seed, tag, k, "y") * (maxy - miny)
            bb = sbox(cx - w / 2, cy - d / 2, cx + w / 2, cy + d / 2)
            if g.contains(bb) and all(not bb.buffer(0.8).intersects(o) for o in placed):
                placed.append(bb); return cx, cy
        return None
    # stair hut (caseta)
    p = try_place(4.0, 3.2, "hut")
    if p:
        cx, cy = p
        sc.box(cx - 2, cy - 1.6, cx + 2, cy + 1.6, z, z + 3.0, plain_wall(("creL", "creM", "creD", "creX")),
               plain_top("terM", "terX", "white", "creD"), door="glaX")
    if h01(seed, "tank") < 0.7:
        p = try_place(1.8, 1.8, "tank")
        if p:
            cx, cy = p
            sc.box(cx - .9, cy - .9, cx + .9, cy + .9, z, z + 2.0, plain_wall(("skyL", "skyM", "skyD", "skyX")),
                   plain_top("skyL", "skyD"))
    # parasol + table / plants / laundry
    for k in range(2 if big else 1):
        if h01(seed, "par", k) < 0.6:
            p = try_place(2.4, 2.4, f"par{k}")
            if p: parasol(sc, p[0], p[1], z, ["corL", "teaL", "golL", "skyL"][int(h01(seed, k, "pc") * 4)])
    for k in range(3):
        p = try_place(0.9, 0.9, f"pot{k}")
        if p: potted(sc, p[0], p[1], z, seed + k)
    if h01(seed, "laundry") < 0.5:
        p = try_place(3.0, 0.6, "laundry")
        if p: laundry(sc, p[0], p[1], z, seed)


def parasol(sc, x, y, z, c1):
    c2 = {"corL": "corD", "teaL": "teaD", "golL": "golD", "skyL": "skyD"}[c1]
    rows = [".aaba.",
            "aabbaa",
            "..|...",
            "..|..."]
    rows = [".aWa.", "aaWaa", "..|..", "..|.."]
    cm = {"a": (c1, c2), "W": ("white", "uiD"), "|": ("ink2", "ink2")}
    sc.sprite(rows, cm, x, y, z, 2, 3, bias=1.0)
    sc.disks.append((x, y, 1.3, z + 2.0, z + 2.6))


def potted(sc, x, y, z, seed):
    kind = int(h01(seed, "pk") * 3)
    if kind == 0:
        rows = [".g.", "ggg", ".p."]
    elif kind == 1:
        rows = ["gf", "gg", "pp"]
    else:
        rows = [".g", "gg", "p."]
    cm = {"g": ("leL", "leD"), "f": ("flwP", "rosD"), "p": ("terM", "terX")}
    sc.sprite(rows, cm, x, y, z, 1, 2, bias=0.6)


def laundry(sc, x, y, z, seed):
    cols = ["white", "corH", "skyL", "golH", "teaH", "rosL"]
    pts = [(-3, -3, "ink2", "ink2"), (3, -3, "ink2", "ink2"), (-3, -2, "ink2", "ink2"), (3, -2, "ink2", "ink2"),
           (-3, -1, "ink2", "ink2"), (3, -1, "ink2", "ink2")]
    for i in range(-2, 3):
        cc = cols[int(h01(seed, i, "l") * len(cols))]
        pts.append((i, -3, cc, "uiD"))
        if h01(seed, i, "l2") < 0.6: pts.append((i, -2, cc, "uiD"))
    sc.pixels(pts, x, y, z, bias=0.6)


# ======================================================================================
# vegetation
# ======================================================================================
def tree(sc, x, y, z=0.0, r=3, th=3, seed=0, kind="round", shadow=True):
    pts = []
    s = sc.S
    if kind == "round":
        for i in range(-r, r + 1):
            for j in range(-r, r + 1):
                d2 = i * i + (j * 1.1) ** 2
                if d2 > (r + 0.35) ** 2: continue
                if abs(i) == r and abs(j) >= r - 1 and r > 2: continue
                nx, ny = i / r, j / r
                v = -0.55 * nx - 0.8 * ny + (ihash(i + int(x * 3), j + int(y * 3), seed) - 0.5) * 0.55
                rim = 0.45 * nx + 0.85 * ny > 0.8
                if rim: L, D = "leD", "leX"
                elif v > 0.55: L, D = "leH", "leM"
                elif v > -0.05: L, D = "leL", "leD"
                elif v > -0.55: L, D = "leM", "leD"
                else: L, D = "leD", "leX"
                pts.append((i, j - th - r, L, D))
        for k in range(th):
            pts.append((0, -k, "trunk", "trunkD"))
        if h01(seed, "fruit") < 0.25:
            for k in range(3):
                pts.append((int((h01(seed, k, "fx") - .5) * r * 1.4), int(-th - r + (h01(seed, k, "fy") - .5) * r * 1.2), "flwO", "flwO"))
        if shadow: sc.disks.append((x, y, r / s * 0.85, z + th / sc.SZ, z + (th + 2 * r) / sc.SZ))
    elif kind == "cypress":
        hgt = r * 3
        for j in range(hgt):
            w = 1 if j < 2 or j > hgt - 2 else (2 if j < hgt * 0.35 else 1)
            for i in range(-w + (1 if w == 2 else 0), w):
                L = "leM" if i < 0 or w == 1 else "leD"
                if j < hgt * 0.6 and i < 0: L = "leL"
                pts.append((i, -j - 1, L, "leX"))
        if shadow: sc.disks.append((x, y, 0.9, z + 0.5, z + hgt / sc.SZ))
    elif kind == "palm":
        H = th
        for k in range(H):
            pts.append((k // 4 if k > H // 2 else 0, -k, "trunk", "trunkD"))
        tx, ty = (H - 1) // 4 if H - 1 > H // 2 else 0, -H
        fr = [(-1, 0), (-2, 1), (-3, 1), (-4, 2), (1, 0), (2, 1), (3, 1), (4, 2), (0, -1), (-1, -1), (1, -1),
              (-2, -1), (2, -2), (-3, 0), (3, 0), (0, 1), (-1, 1), (1, 1)]
        for i, j in fr:
            L = "leL" if i <= 0 and j <= 0 else ("leM" if j <= 0 else "leD")
            pts.append((tx + i, ty + j, L, "leX"))
        pts.append((tx, ty, "leH", "leM"))
        if shadow: sc.disks.append((x, y, 2.6, z + H * 0.8, z + H + 1))
    elif kind == "bush":
        for i in range(-r, r + 1):
            for j in range(-r, 1):
                if i * i + (j * 1.6) ** 2 > (r + .3) ** 2: continue
                v = -0.6 * i / r - 0.8 * j / max(r, 1) + (ihash(i, j, seed) - .5) * .5
                L = "leL" if v > 0.3 else ("leM" if v > -0.3 else "leD")
                pts.append((i, j - 1, L, "leX"))
        if h01(seed, "flw") < 0.6:
            for k in range(2):
                pts.append((int((h01(seed, k, "a") - .5) * 2 * r), -1 - int(h01(seed, k, "b") * r * .6), "flwP" if k else "flwY", "rosD"))
    sc.pixels(pts, x, y, z, bias=1.2)


# ======================================================================================
# small life: cars, people, lamps, benches
# ======================================================================================
CAR_COLS = [("corL", "corD"), ("teaL", "teaD"), ("white", "uiD"), ("gtM", "gtD"), ("corL", "corD"), ("white", "uiD"), ("teaL", "teaD")]
_VCACHE = {}


def voxel_sprite(boxes, S, SZ, k=1.0, step=0.06):
    """Rasterise small axis-aligned boxes into a pixel sprite (exact iso, nearest surface wins).
    box: (x0,y0,z0,x1,y1,z1, top, side_lit(-y face), side_shade(+x face)) colours = (lit, shd)"""
    pix = {}
    for (x0, y0, z0, x1, y1, z1, ct, cl, cr) in boxes:
        x0, y0, z0, x1, y1, z1 = [v * k for v in (x0, y0, z0, x1, y1, z1)]
        faces = []
        xs = np.arange(x0, x1 + 1e-6, step); ys = np.arange(y0, y1 + 1e-6, step); zs = np.arange(z0, z1 + 1e-6, step)
        if ct: X, Y = np.meshgrid(xs, ys); faces.append((X.ravel(), Y.ravel(), np.full(X.size, z1), ct, 0.002))
        if cl: X, Z = np.meshgrid(xs, zs); faces.append((X.ravel(), np.full(X.size, y0), Z.ravel(), cl, 0.0))
        if cr: Y, Z = np.meshgrid(ys, zs); faces.append((np.full(Y.size, x1), Y.ravel(), Z.ravel(), cr, 0.0))
        for X, Y, Z, cc, pr in faces:
            PX = np.floor((X + Y) * S + 0.5).astype(int); PY = np.floor((X - Y) * S / 2 - Z * SZ + 0.5).astype(int)
            dep = X - Y + 0.01 * Z + pr
            for px, py, d in zip(PX, PY, dep):
                if (px, py) not in pix or pix[(px, py)][0] < d:
                    pix[(px, py)] = (d, cc)
    xs = [p[0] for p in pix]; ys = [p[1] for p in pix]
    mx, my = min(xs), min(ys)
    w, h = max(xs) - mx + 1, max(ys) - my + 1
    chars = {}
    grid = [["."] * w for _ in range(h)]
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    for (px, py), (d, cc) in pix.items():
        if cc not in chars: chars[cc] = alphabet[len(chars)]
        grid[py - my][px - mx] = chars[cc]
    return ["".join(r) for r in grid], {v: k_ for k_, v in chars.items()}, -mx, -my


def car_sprite(axis, c1, c2, S, SZ, taxi=False):
    key = (axis, c1, c2, S, SZ, taxi)
    if key in _VCACHE: return _VCACHE[key]
    roof = ("ink2", "ink") if taxi else (c1, c2)
    body_side = (c1, c2)
    glass_l = ("glaH", "glaL"); glass_r = ("glaL", "glaD")
    wheel = ("ink", "ink")
    L, Wd = 2.3, 1.0
    if axis == "x":
        bx = [(-L, -Wd, 0.3, L, Wd, 1.0, (c1, c2), body_side, (c2, c2)),
              (-1.2, -0.85, 1.0, 0.9, 0.85, 1.75, roof, glass_l, glass_r),
              (1.2, -1.02, 0.0, 1.8, -0.9, 0.55, None, wheel, None),
              (-1.8, -1.02, 0.0, -1.2, -0.9, 0.55, None, wheel, None)]
    else:
        bx = [(-Wd, -L, 0.3, Wd, L, 1.0, (c1, c2), (c2, c2), body_side),
              (-0.85, -0.9, 1.0, 0.85, 1.2, 1.75, roof, glass_r, glass_l),
              (0.9, 1.2, 0.0, 1.02, 1.8, 0.55, None, None, wheel),
              (0.9, -1.8, 0.0, 1.02, -1.2, 0.55, None, None, wheel)]
    res = voxel_sprite(bx, S, SZ, k=1.25)
    _VCACHE[key] = res
    return res


def car(sc, x, y, axis, seed, z=0.0, taxi=False):
    c1, c2 = CAR_COLS[int(h01(seed, "cc") * len(CAR_COLS))]
    if taxi: c1, c2 = "golL", "golD"
    rows, cm, ax, ay = car_sprite(axis, c1, c2, sc.S, sc.SZ, taxi)
    sc.sprite(rows, cm, x, y, z, ax, ay, bias=2.0)
    sc.disks.append((x, y, 1.5, 0, 1.6))


def person(sc, x, y, seed, z=0.0):
    cols = ["corL", "teaL", "golL", "skyD", "rosD", "white", "minD", "peaD"]
    c = cols[int(h01(seed, "p") * len(cols))]
    rows = ["h", "c", "l"] if h01(seed, "t") < 0.7 else ["h", "c", "c"]
    cm = {"h": ("skin", "skinD"), "c": (c, c), "l": ("ink2", "ink2")}
    sc.sprite(rows, cm, x, y, z, 0, 2, bias=0.8)


def lamp(sc, x, y, z=0.0):
    rows = ["ll", "|.", "|.", "|.", "|.", "|."]
    rows = [".l", "|.", "|.", "|.", "|.", "|.", "|."]
    cm = {"l": ("golH", "golL"), "|": ("ink2", "ink2")}
    sc.sprite(rows, cm, x, y, z, 0, 6, bias=0.8)


def bench(sc, x, y, axis, z=0.0):
    rows = ["bbb", "b.b"] if axis == "x" else ["bbb", "b.b"]
    cm = {"b": ("trunk", "trunkD")}
    sc.sprite(rows, cm, x, y, z, 1, 1, bias=0.7)


def flag(sc, x, y, z, color=("teaL", "teaD"), h=7, logo=True):
    rows = ["|" + "ffff"[:4]]
    rows = ["|ffff", "|fWff", "|fff.", "|....", "|....", "|....", "|....", "|...."][:h]
    if not logo: rows[1] = "|ffff"
    cm = {"|": ("ink2", "ink2"), "f": color, "W": ("white", "uiD")}
    sc.sprite(rows, cm, x, y, z, 0, h - 1, bias=0.8)


def sign_board(sc, x, y, z, text, fg="corL", bg="uiL", frame="teaD", pad=2, legs=2, bias=1.5):
    lines = text.split("\n")
    w = max(sum(len(F35.get(ch, F35[" "])[0]) + 1 for ch in ln) - 1 for ln in lines)
    hgt = len(lines) * 6 - 1
    W_, H_ = w + 2 * pad, hgt + 2 * pad
    grid = [["B"] * W_ for _ in range(H_)]
    for j in range(H_):
        for i in range(W_):
            if i == 0 or j == 0 or i == W_ - 1 or j == H_ - 1: grid[j][i] = "F"
    for li, ln in enumerate(lines):
        lw = sum(len(F35.get(ch, F35[" "])[0]) + 1 for ch in ln) - 1
        cx = pad + (w - lw) // 2
        for ch in ln:
            g = F35.get(ch, F35[" "])
            for j, row in enumerate(g):
                for i, cc in enumerate(row):
                    if cc == "#": grid[pad + li * 6 + j][cx + i] = "T"
            cx += len(g[0]) + 1
    rows = ["".join(r) for r in grid]
    # legs
    for k in range(legs):
        lr = ["."] * W_
        lr[2] = "|"; lr[W_ - 3] = "|"
        rows.append("".join(lr))
    cm = {"B": (bg, "uiD"), "F": (frame, frame), "T": (fg, fg), "|": ("ink2", "ink2")}
    sc.sprite(rows, cm, x, y, z, W_ // 2, len(rows) - 1, bias=bias)


# ======================================================================================
# tiers
# ======================================================================================
def build_apartment(sc, poly, levels, fac, seed, owned=False, shop=True, awning="cor", props=True, oid=0):
    from shapely.geometry import Polygon
    h = levels_to_h(levels) / sc.SZ
    sh = [("shut", "shutD"), ("shut", "shutD"), ("white", "uiD"), ("terM", "terD"), ("shut", "shutD")][int(h01(seed, "shc") * 5)]
    shp = 0.0 if h01(seed, "shp") < 0.2 else 0.85
    b = dict(fac=fac, seed=seed, owned=owned, shop=shop, awning=awning, levels=levels, shutc=sh[0], shutcD=sh[1], shut=shp)
    sc.prism(poly, 0, h, apt_wall, flat_roof, oid=oid, b=b)
    if props: roof_props(sc, poly, h, seed, owned, big=Polygon(poly).area > 300)
    if owned:
        g = Polygon(poly).buffer(-1.0)
        # flag on the front-most roof corner
        pts = list(g.exterior.coords)
        fx, fy = max(pts, key=lambda p: p[0] - p[1])
        flag(sc, fx - 0.6, fy + 0.6, h)
    return h


def gable_roof(sc, x0, y0, x1, y1, z, rise, along="x", over=0.6, oid=0, owned=False):
    """pitched terracotta roof with ridge along 'along' axis."""
    x0 -= over; y0 -= over; x1 += over; y1 += over
    if along == "x":
        ym = (y0 + y1) / 2
        A = [(x0, y0, z), (x1, y0, z), (x1, ym, z + rise), (x0, ym, z + rise)]   # south slope (faces -y: lit)
        Bq = [(x0, ym, z + rise), (x1, ym, z + rise), (x1, y1, z), (x0, y1, z)]  # north slope
        gab = [(x1, y0 + over, z), (x1, y1 - over, z), (x1, ym, z + rise - over * 0.6)]
        sc.face(A, roof_tiles, oid=oid, eave=("y", y0), owned=owned)
        sc.face(Bq, roof_tiles, oid=oid, eave=("y", y1), owned=owned)
        sc.face(gab, gable_sh, oid=oid, bias=-0.05)
        sc.blockers.append(([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], z, z + rise * 0.6))
    else:
        xm = (x0 + x1) / 2
        A = [(x0, y0, z), (xm, y0, z + rise), (xm, y1, z + rise), (x0, y1, z)]
        Bq = [(xm, y0, z + rise), (x1, y0, z), (x1, y1, z), (xm, y1, z + rise)]
        gab = [(x0 + over, y0, z), (x1 - over, y0, z), (xm, y0, z + rise - over * 0.6)]
        sc.face(A, roof_tiles, oid=oid, eave=("x", x0), owned=owned)
        sc.face(Bq, roof_tiles, oid=oid, eave=("x", x1), owned=owned)
        sc.face(gab, gable_sh, oid=oid, bias=-0.05)
        sc.blockers.append(([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], z, z + rise * 0.6))


def hip_roof(sc, x0, y0, x1, y1, z, rise, over=0.6, oid=0, owned=False):
    x0 -= over; y0 -= over; x1 += over; y1 += over
    w, d = x1 - x0, y1 - y0
    inset = min(w, d) / 2
    if w >= d:
        r0, r1 = (x0 + inset, (y0 + y1) / 2), (x1 - inset, (y0 + y1) / 2)
    else:
        r0, r1 = ((x0 + x1) / 2, y0 + inset), ((x0 + x1) / 2, y1 - inset)
    R0 = (r0[0], r0[1], z + rise); R1 = (r1[0], r1[1], z + rise)
    c00, c10, c11, c01 = (x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)
    if w >= d:
        faces = [[c00, c10, R1, R0], [c10, c11, R1], [c11, c01, R0, R1], [c01, c00, R0]]
    else:
        faces = [[c00, c10, R0], [c10, c11, R1, R0], [c11, c01, R1], [c01, c00, R0, R1]]
    for f in faces:
        sc.face(f, roof_tiles, oid=oid, eave=None, owned=owned)
    sc.blockers.append(([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], z, z + rise * 0.7))


def roof_tiles(c):
    n = len(c.X)
    nz = c.n[2]
    hl = np.linalg.norm(c.n[:2])
    s = (c.n[:2] @ SUN_H) / hl if hl > 1e-6 else 0
    lam = s * 0.8 + nz * 0.6
    if lam > 0.75: base, alt, sh = "terH", "terL", "terD"
    elif lam > 0.35: base, alt, sh = "terL", "terM", "terD"
    else: base, alt, sh = "terM", "terD", "terX"
    lit = np.repeat(P([base]), n, 0); shd = np.repeat(P([sh]), n, 0)
    rows = (c.z * c.scene.SZ)
    course = (np.floor(rows + 1e-3).astype(int) % 2 == 0)
    stag = ((c.X + (np.floor(rows).astype(int) // 2)) % 3 == 0)
    lit[course] = PAL[alt]
    lit[stag & ~course] = PAL[alt]
    if c.info.get("owned"):
        pass
    e = c.edge & c.e_dn
    lit[e] = PAL["terD"] if base != "terM" else PAL["terX"]
    return lit, shd, True


def gable_sh(c):
    t = tone(c)
    F = FACADES["cre"]
    n = len(c.X)
    return np.repeat(P([F[t]]), n, 0), np.repeat(P([F[SHIFT[t]]]), n, 0)


def house_wall_factory(fac, seed, levels=2, door_side=None):
    def sh(c):
        b = dict(fac=fac, seed=seed, period=2, shop=False, shut=0.9, shutc="shut", shutcD="shutD")
        c.info["b"] = b
        t = tone(c)
        F = FACADES[fac]
        r, pair, sub, npairs = wall_coords(c)
        n = len(r)
        Ht = int(round((c.info["z1"] - c.info["z0"]) * c.scene.SZ))
        lit = np.repeat(P([F[t]]), n, 0); shd = np.repeat(P([F[SHIFT[t]]]), n, 0)
        first = 1; last = npairs - 2
        off = first + ((last - first) % 3) // 2
        win = (pair >= first) & (pair <= last) & (((pair - off) % 3) == 0)
        fl = r // 4; rr = r % 4
        gl = "glaL" if t < 2 else "glaD"
        glass = win & (rr >= 1) & (rr <= 2) & (r < Ht - 1)
        lit[glass] = PAL[gl]; shd[glass] = PAL["glaD"]
        refl = glass & (rr == 2) & (sub == 0)
        lit[refl] = PAL["glaH" if t < 2 else "glaL"]
        sl = (~win) & (rr >= 1) & (rr <= 2) & (r < Ht - 1) & (pair >= first) & (pair <= last) & (
            (((pair - 1 - off) % 3 == 0) & (sub == 0)) | (((pair + 1 - off) % 3 == 0) & (sub == 1)))
        lit[sl] = PAL["shut" if t < 2 else "shutD"]; shd[sl] = PAL["shutD"]
        sill = win & (rr == 0) & (r > 0)
        lit[sill] = PAL["white" if t < 2 else F[t]]
        # flower boxes
        fb = sill & (ihash(pair, fl, seed) < 0.6)
        lit[fb & ((pair + fl) % 2 == 1)] = PAL["flwP"]
        lit[fb & ((pair + fl) % 2 == 0)] = PAL["leL"]
        # door on the lit long wall
        if door_side is not None and c.info.get("edge_i") == door_side:
            mid = npairs // 2
            dm = (pair == mid) & (r <= 2)
            lit[dm] = PAL["trunk"]; shd[dm] = PAL["trunkD"]
            dk = (pair == mid) & (r == 1) & (sub == 1)
            lit[dk] = PAL["golL"]
        lit[r == 0] = PAL[F[min(3, t + 1)]]
        return lit, shd
    return sh


def build_house(sc, x0, y0, x1, y1, seed, fac="cre", owned=False, oid=0, levels=2):
    h = levels * 4 / sc.SZ
    sc.box(x0, y0, x1, y1, 0, h, house_wall_factory(fac, seed, levels, door_side=0), None, oid=oid)
    along = "x" if (x1 - x0) >= (y1 - y0) else "y"
    gable_roof(sc, x0, y0, x1, y1, h, rise=min(x1 - x0, y1 - y0) * 0.55, along=along, oid=oid, owned=owned)
    # chimney
    cx, cy = x0 + (x1 - x0) * 0.75, y0 + (y1 - y0) * 0.6
    sc.box(cx - .6, cy - .6, cx + .6, cy + .6, h, h + min(x1 - x0, y1 - y0) * 0.55 + 1.2,
           plain_wall(("creL", "creM", "creD", "creX")), plain_top("terD", "terX"), shadow=True)
    return h


def build_estate(sc, x0, y0, x1, y1, seed, fac="pea", owned=False, oid=0):
    h = 3 * 4 / sc.SZ
    sc.box(x0, y0, x1, y1, 0, h, house_wall_factory(fac, seed, 3, door_side=0), None, oid=oid)
    hip_roof(sc, x0, y0, x1, y1, h, rise=min(x1 - x0, y1 - y0) * 0.38, oid=oid, owned=owned)
    return h


# ---- modern tower ----------------------------------------------------------------------
def tower_wall(c):
    t = tone(c)
    r, pair, sub, npairs = wall_coords(c)
    n = len(r)
    zb = int(round(c.info["z0"] * c.scene.SZ))
    ra = r + zb
    acc = c.info.get("acc", "min")
    F = FACADES[acc]
    lit = np.repeat(P([("gtM", "gtD", "gtX")[t]]), n, 0); shd = np.repeat(P([("gtD", "gtX", "gtX")[t]]), n, 0)
    frame_l = ("frmL", "frmL", "frmD")[t]
    slab = (ra % 4 == 0)
    lit[slab] = PAL[frame_l]; shd[slab] = PAL["frmD"]
    # glass: upper row lighter (sky reflection), mullion every 3 pairs
    up = (ra % 4 == 3)
    lit[up & ~slab] = PAL[("gtL", "gtM", "gtD")[t]]
    refl = (~slab) & (((c.X + 2 * c.Y) // 3) % 9 == 0) & (t < 2)
    lit[refl] = PAL["gtH"]
    mull = (~slab) & (pair % 3 == 0) & (sub == 0)
    lit[mull] = PAL[frame_l]; shd[mull] = PAL["frmD"]
    # accent balcony fronts (pastel) on every other slab, broken at mullions
    bal = slab & (((ra // 4) % 2) == 0) & (pair % 3 != 0)
    rail2 = (ra % 4 == 1) & (((ra // 4) % 2) == 0) & (pair % 3 != 0) & (sub == 1)
    lit[bal] = PAL[F[min(t + 1, 3)]]
    lit[rail2] = PAL[("frmL", "frmD", "gtX")[t]]
    pl = bal & (ihash(pair, ra, 3) < 0.12) & (t < 2)
    lit[pl] = PAL["leL"]
    lob = r < GF
    lit[lob] = PAL[("glaL", "glaD", "glaX")[t]]
    lit[lob & (r == GF - 1)] = PAL[frame_l]
    corner = (pair == 0) | (pair >= npairs - 1)
    lit[corner & ~lob] = PAL[frame_l]
    return lit, shd


def glass_wall(c):
    t = tone(c)
    r, pair, sub, npairs = wall_coords(c)
    n = len(r)
    zb = int(round(c.info["z0"] * c.scene.SZ))
    ra = r + zb
    lit = np.repeat(P([("gtL", "gtM", "gtD")[t]]), n, 0); shd = np.repeat(P([("gtD", "gtD", "gtX")[t]]), n, 0)
    band = (ra % 3 == 0)
    lit[band] = PAL[("gtM", "gtD", "gtX")[t]]
    mull = (pair % 2 == 0) & (sub == 0) & ~band
    lit[mull] = PAL[("gtM", "gtD", "gtX")[t]]
    # diagonal sky reflection streaks
    k = (c.X * 1 + c.Y * 2)
    streak = ((k // 3) % 17 == 0) | ((k // 3) % 17 == 2)
    lit[streak & ~band & (t < 2)] = PAL["gtH"]
    lit[streak & ~band & (t == 2)] = PAL["gtM"]
    if c.info.get("lobby"):
        lob = r < 5
        lit[lob] = PAL[("glaL", "glaD", "glaX")[t]]
        lit[lob & (r == 4)] = PAL["frmL"]
        door = lob & (r <= 2) & (pair == npairs // 2)
        lit[door] = PAL["golH"]
    top = r >= int(round((c.info["z1"] - c.info["z0"]) * c.scene.SZ)) - 1
    lit[top] = PAL[("frmL", "frmL", "frmD")[t]]
    return lit, shd


def roof_garden(c):
    n = len(c.X)
    lit = np.repeat(P(["grsL"]), n, 0); shd = np.repeat(P(["grsX"]), n, 0)
    sp = ihash(c.X, c.Y, 7)
    lit[sp < 0.12] = PAL["grsH"]; lit[(sp > 0.9)] = PAL["grsM"]
    owned = c.info.get("owned")
    lit[c.edge] = PAL["teaL" if owned else "frmL"]; shd[c.edge] = PAL["teaD" if owned else "frmD"]
    return lit, shd, True


def build_tower(sc, x0, y0, x1, y1, seed, owned=False, oid=0, floors=14, acc="min"):
    h = (GF + FL * (floors - 1) + 1) / sc.SZ
    sc.box(x0, y0, x1, y1, 0, h, tower_wall, roof_garden, oid=oid, acc=acc, owned=owned)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    # rooftop: pergola-ish hut, trees
    sc.box(cx - 2.5, y1 - 5, cx + 2.5, y1 - 1.6, h, h + 3, plain_wall(("frmL", "frmL", "frmD", "gtX")),
           plain_top("teaL" if owned else "gtM", "teaD" if owned else "gtD"))
    tree(sc, x0 + 2.2, y0 + 2.2, h, r=2, th=1, seed=seed + 1)
    tree(sc, x1 - 2.2, y0 + 3.0, h, r=2, th=1, seed=seed + 2)
    parasol(sc, cx, y0 + 4.5, h, "corL")
    if owned:
        flag(sc, x1 - 1.0, y0 + 1.0, h)
    return h


def build_skyscraper(sc, x0, y0, x1, y1, seed, owned=False, oid=0, floors=26):
    H = (GF + FL * (floors - 1)) / sc.SZ
    tiers = [(0.0, 0.46, 0.0), (0.46, 0.79, 1.5), (0.79, 1.0, 3.0)]
    zb = 0
    for i, (a, b_, ins) in enumerate(tiers):
        za, zb = round(H * a), round(H * b_)
        rx0, ry0, rx1, ry1 = x0 + ins, y0 + ins, x1 - ins, y1 - ins
        top = ledge_top(owned)
        sc.box(rx0, ry0, rx1, ry1, za, zb, glass_wall, top, oid=oid, lobby=(i == 0), owned=owned)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    wl = ("teaL", "teaL", "teaD", "teaX") if owned else ("frmL", "frmL", "frmD", "gtX")
    sc.box(x0 + 4.5, y0 + 4.5, x1 - 4.5, y1 - 4.5, zb, zb + 3, plain_wall(wl), plain_top("teaH" if owned else "frmL", "teaD"), lip=False)
    sc.box(x0 + 6.2, y0 + 6.2, x1 - 6.2, y1 - 6.2, zb + 3, zb + 6, plain_wall(("frmL", "frmL", "frmD", "gtX")), plain_top("frmL", "frmD"), lip=False)
    sc.box(cx - .5, cy - .5, cx + .5, cy + .5, zb + 6, zb + 15, plain_wall(("frmL", "frmL", "frmD", "gtX")),
           plain_top("red", "red"), lip=False)
    return zb + 15


def ledge_top(owned):
    def sh(c):
        n = len(c.X)
        lit = np.repeat(P(["frmD"]), n, 0); shd = np.repeat(P(["gtX"]), n, 0)
        lit[c.edge] = PAL["teaL" if owned else "frmL"]; shd[c.edge] = PAL["teaD" if owned else "frmD"]
        return lit, shd, True
    return sh


def flat_tech(c):
    n = len(c.X)
    lit = np.repeat(P(["frmD"]), n, 0); shd = np.repeat(P(["gtX"]), n, 0)
    lit[c.edge] = PAL["frmL"]
    return lit, shd, True


# ---- construction site -----------------------------------------------------------------
def scaffold_wall(c):
    t = tone(c)
    r, pair, sub, npairs = wall_coords(c)
    zb = int(round(c.info["z0"] * c.scene.SZ))
    ra = r + zb
    pole = ((pair % 3 == 0) & (sub == 0)) | (ra % 4 == 0)
    diag = ((pair * 2 + sub + ra) % 6 == 0)
    keep = pole | diag
    n = len(r)
    lit = np.repeat(P([("golL", "golL", "golD")[t]]), n, 0); shd = np.repeat(P(["golD"]), n, 0)
    lit[diag & ~pole] = PAL[("golD", "golD", "terD")[t]]
    # safety net strip
    return lit, shd, True, keep


def concrete_wall(c):
    t = tone(c)
    r, pair, sub, npairs = wall_coords(c)
    n = len(r)
    lit = np.repeat(P([("frmL", "frmD", "creX")[t]]), n, 0); shd = np.repeat(P([("creX", "creX", "skyX")[t]]), n, 0)
    zb = int(round(c.info["z0"] * c.scene.SZ))
    ra = r + zb
    hole = (ra % 4 != 0) & (ra % 4 != 3) & (pair % 2 == 1)
    lit[hole] = PAL[("glaD", "glaX", "glaX")[t]]
    return lit, shd


def build_construction(sc, x0, y0, x1, y1, seed, owned=True, oid=0, built=10, target=16, pct=0.62):
    h_built = (GF + FL * (built - 1)) / sc.SZ
    h_tgt = (GF + FL * (target - 1)) / sc.SZ
    # finished lower part = tower style
    sc.box(x0, y0, x1, y1, 0, h_built, tower_wall, None, oid=oid, acc="pea")
    # raw concrete floors being built
    h_raw = h_built + 12 / sc.SZ
    sc.box(x0 + 0.5, y0 + 0.5, x1 - 0.5, y1 - 0.5, h_built, h_raw, concrete_wall,
           plain_top("creD", "creX", "frmL", "creX"), oid=oid)
    # scaffolding cage (outer)
    sc.box(x0 - 0.9, y0 - 0.9, x1 + 0.9, y1 + 0.9, h_built - 3, h_raw + 3, scaffold_wall, None, oid=oid, shadow=False)
    return h_raw + 3


def crane(sc, mx, my, base_z, top_z, jib_dir=(1, -1), jib_len=24, seed=0):
    """tower crane drawn as pixels: lattice mast, jib, counter-jib, cable"""
    AX, AY = sc.ipt(mx, my, base_z)
    TX, TY = sc.ipt(mx, my, top_z)
    pts = []
    for Y in range(TY, AY + 1):
        k = AY - Y
        pts.append((0, -k, "golL", "golD"))
        pts.append((1, -k, "golD", "golD"))
        if k % 3 == 0: pts.append((1, -k, "golL", "golD"))
    # cab
    for dx in range(-1, 3):
        for dy in range(0, 3):
            pts.append((dx, -(AY - TY) - dy, "white" if dy < 2 else "golD", "uiD"))
    pts.append((2, -(AY - TY) - 1, "glaL", "glaD"))
    pts.append((-1, -(AY - TY) - 1, "glaL", "glaD"))
    # jib: along world direction -> screen direction
    jx = (jib_dir[0] + jib_dir[1]) * sc.S
    jy = (jib_dir[0] - jib_dir[1]) * sc.S / 2
    L = math.hypot(*jib_dir)
    jx, jy = jx / L, jy / L
    top = -(AY - TY) - 3
    n = int(jib_len * math.hypot(jx, jy))
    for i in range(-int(n * 0.35), n + 1):
        px = round(i * jx / math.hypot(jx, jy)); py = round(i * jy / math.hypot(jx, jy))
        pts.append((px, top + py, "golL", "golD"))
        if i > 0 and i % 3 == 0: pts.append((px, top + py - 1, "golD", "golD"))
        if 0 < i and i % 2 == 0: pts.append((px, top + py + 1, "golD", "golD"))
    # apex + tie lines
    pts.append((0, top - 1, "golD", "golD")); pts.append((0, top - 2, "golD", "golD")); pts.append((0, top - 3, "red", "red"))
    # counterweight
    ci = -int(n * 0.35)
    for dd in range(0, 3):
        for e in range(-1, 2):
            pts.append((round(ci * jx / math.hypot(jx, jy)) + dd, top + round(ci * jy / math.hypot(jx, jy)) + e + 1, "creX", "creX"))
    # trolley + cable + hook + load (a teal beam)
    ti = int(n * 0.7)
    tx, ty = round(ti * jx / math.hypot(jx, jy)), top + round(ti * jy / math.hypot(jx, jy))
    for k in range(1, 12):
        pts.append((tx, ty + k, "ink2", "ink2"))
    for dd in range(-2, 3):
        pts.append((tx + dd, ty + 12, "teaL", "teaD"))
    pts.append((tx, ty + 11, "golD", "golD"))
    sc.pixels(pts, mx, my, base_z, bias=8)


def lot_sign(sc, x, y, price="85K"):
    sign_board(sc, x, y, 0, "SE VENDE\n" + price + " €", fg="corD", bg="uiL", frame="corL", pad=2, legs=3)


# ======================================================================================
# diorama slab (earth strata on the two visible sides)
# ======================================================================================
def slab_sides(sc, TX0, TY0, TX1, TY1, SLAB):
    SZ = sc.SZ

    def earth(c):
        t = 0 if c.sun > 0 else 1
        r = np.floor(-c.z * SZ + 1e-4).astype(int)
        n = len(r)
        names = [("curb", "curbD"), ("grsM", "grsXX"), ("e0", "e0D"), ("e1", "e1D"), ("e2", "e2D"), ("e3", "e3D"), ("e4", "e4D")]
        Xf = c.X.astype(float)
        f = SLAB / 14.0
        bnd = [0, 1, 2, np.round(4 * f + np.sin(Xf * 0.31) * 0.8), np.round(7 * f + np.sin(Xf * 0.17 + 2.0) * 1.1),
               np.round(10 * f + np.sin(Xf * 0.23 + 4.0) * 0.9), SLAB - 1]
        lay = np.zeros(n, int)
        for k in range(1, 7): lay[r >= bnd[k]] = k
        lit = np.array([PAL[nm[t]] for nm in names], np.uint8)[lay]
        roots = (lay == 2) & (r == 2) & (ihash(c.X, 0, 7) < 0.3)
        lit[roots] = PAL[names[1][t]]
        peb = (lay >= 3) & (lay <= 5) & (ihash(c.X // 2, r, 9) < 0.035) & (c.X % 2 == 0)
        lit[peb] = PAL["stone" if t == 0 else "stoneD"]
        peb2 = (lay >= 3) & (lay <= 5) & (ihash((c.X - 1) // 2, r, 9) < 0.035) & ((c.X - 1) % 2 == 0)
        lit[peb2] = PAL["stoneD" if t == 0 else names[5][t]]
        return lit, lit.copy(), False
    z = -SLAB / SZ
    sc.face([(TX0, TY0, 0), (TX1, TY0, 0), (TX1, TY0, z), (TX0, TY0, z)], earth, bias=-0.5)
    sc.face([(TX1, TY0, 0), (TX1, TY1, 0), (TX1, TY1, z), (TX1, TY0, z)], earth, bias=-0.5)
