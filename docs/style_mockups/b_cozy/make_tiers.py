"""Tiny Realtor - cozy pastel diorama: the same plot at every upgrade tier -> tiers.png"""
import os, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from engine import Scene, PAL, ihash, F35, draw_text, text_width
import buildings as B
from ui import draw_sky, panel, outline_silhouette, pin, tag

S, SZ = 1.45, 1.33
CW, CH = 92, 214           # low-res cell size
PX0, PY0, PX1, PY1 = 0.0, 0.0, 22.0, 22.0     # the plot
TX0, TY0, TX1, TY1 = -3.5, -3.5, 25.5, 25.5   # plot + sidewalk
SLAB = 9
TIERS = [("LOT", "lot"), ("HOUSE", "house"), ("ESTATE", "estate"), ("APARTMENTS", "apt"), ("TOWER", "tower"), ("SKYSCRAPER", "sky")]


def ground(sc, kind):
    Ys, Xs = np.mgrid[0:CH, 0:CW]
    gx, gy = sc.unproj(Xs.astype(float), Ys.astype(float))
    inside = (gx >= TX0) & (gx <= TX1) & (gy >= TY0) & (gy <= TY1)
    plot = (gx >= PX0) & (gx <= PX1) & (gy >= PY0) & (gy <= PY1)
    cls = np.zeros((CH, CW), np.int8)
    cls[inside] = 2
    cls[inside & plot] = {"lot": 5, "house": 3, "estate": 3}.get(kind, 4)
    if kind == "estate":
        cls[inside & (gx > 2.3) & (gx < 13.7) & (gy > 1.3) & (gy < 7.2)] = 8
        cls[inside & (gx > 3) & (gx < 13) & (gy > 2) & (gy < 6.5)] = 7
    if kind == "house":
        cls[inside & (gx > 9.2) & (gx < 10.8) & (gy > 0) & (gy < 7)] = 6
    if kind in ("tower", "sky"):
        cls[inside & plot & ((gx < 2) | (gy < 2) | (gx > 20) | (gy > 20))] = 3
    lit = np.zeros((CH, CW, 3), np.uint8); shd = np.zeros((CH, CW, 3), np.uint8)

    def paint(mask, ln, sn):
        lit[mask] = PAL[ln]; shd[mask] = PAL[sn]
    tex = ihash(Xs, Ys, 21)
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
    dn = np.roll(cls, -1, 0)
    paint((cls == 2) & (np.roll(cls, 1, 0) != 2) & (np.roll(cls, 1, 0) != 0), "curb", "curbD")
    paint((cls == 3) & (dn != 3) & (dn != 0), "grsM", "grsXX")
    m = cls > 0
    Y_, X_ = np.nonzero(m)
    sc.write(X_, Y_, (gx - gy)[m], lit[m], shd[m], gx[m], gy[m], np.zeros(m.sum()), True, 1)


def build(sc, kind):
    if kind == "lot":
        sc.sprite(["ccccc", "cWWWc", "ccccc", "..|..", "..|.."], {"c": ("corL", "corD"), "W": ("white", "uiD"), "|": ("ink2", "ink2")},
                  14.0, 4.0, 0, 2, 4, bias=1.0)
        for t in np.linspace(0, 1, 12):
            sc.pixels([(0, 0, "trunk", "trunkD"), (0, -1, "white", "uiD")], 0.6 + t * 20.8, 0.6, 0, bias=0.4)
        for t in np.linspace(0, 1, 12):
            sc.pixels([(0, 0, "trunk", "trunkD"), (0, -1, "white", "uiD")], 21.4, 0.6 + t * 20.8, 0, bias=0.4)
        for k, (x, y) in enumerate([(4, 6), (17, 15), (8, 17), (13, 10), (5, 13)]):
            B.tree(sc, x, y, r=1, kind="bush", seed=40 + k, shadow=False)
        return 6
    if kind == "house":
        h = B.build_house(sc, 5.0, 7.0, 15.5, 15.5, 4242, fac="pea", owned=True)
        B.tree(sc, 18.0, 17.5, r=3, th=4, seed=15)
        B.tree(sc, 4.0, 19.0, r=2, th=3, seed=16)
        B.tree(sc, 18.5, 5.0, r=1, kind="bush", seed=17)
        B.tree(sc, 3.0, 3.5, r=1, kind="bush", seed=18)
        x = 0.4
        while x <= 21.6:
            if not (9.0 < x < 11.0):
                sc.pixels([(0, 0, "white", "uiD"), (0, -1, "white", "uiD"), (0, -2, "white", "uiD")], x, 0.4, 0, bias=0.3)
            x += 0.75
        B.flag(sc, 20.5, 2.0, 0, h=8)
        return h + 6
    if kind == "estate":
        h = B.build_estate(sc, 3.5, 9.5, 18.0, 19.0, 99, fac="ros", owned=True)
        B.tree(sc, 16.5, 3.0, th=12, kind="palm", seed=3)
        B.tree(sc, 1.5, 20.0, r=2, kind="cypress", seed=5)
        B.tree(sc, 20.5, 20.5, r=2, kind="cypress", seed=6)
        B.parasol(sc, 16.0, 7.0, 0, "teaL")
        sc.box(0.3, 0.3, 21.7, 1.1, 0, 1.6, _hedge, _hedge_top)
        sc.box(20.9, 0.3, 21.7, 21.7, 0, 1.6, _hedge, _hedge_top)
        B.flag(sc, 20.0, 2.5, 0, h=8)
        return h + 9
    if kind == "apt":
        poly = [(0.5, 0.5), (14.5, 0.5), (21.5, 7.5), (21.5, 21.5), (0.5, 21.5)]
        h = B.build_apartment(sc, poly, 8, "cre", 3131, owned=True, awning="tea")
        return h
    if kind == "tower":
        h = B.build_tower(sc, 2.0, 2.0, 20.0, 20.0, 777, owned=True, floors=15, acc="pea")
        return h + 4
    if kind == "sky":
        return B.build_skyscraper(sc, 2.0, 2.0, 20.0, 20.0, 888, owned=True, floors=22)


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


def cell(kind):
    sc = Scene(CW, CH, S, SZ, ((TX0 + TX1) / 2, (TY0 + TY1) / 2), (CW // 2, CH - 54))
    ground(sc, kind)
    B.slab_sides(sc, TX0, TY0, TX1, TY1, SLAB)
    top = build(sc, kind)
    sc.shadows((TX0 - 2, TY0 - 2, TX1 + 2, TY1 + 2), elevs=(48, 44), azim_off=(0, 4))
    return sc, top


LOTTAG = []


def main():
    pad = 8
    Wt = pad * 2 + CW * len(TIERS)
    Ht = CH + 4
    out = draw_sky(Wt, Ht, stops=[(0.0, "sky0"), (0.4, "sky1"), (0.75, "sky2"), (1.0, "sky3")])
    kinds = np.zeros((Ht, Wt), np.int8)
    for i, (name, kind) in enumerate(TIERS):
        sc, top = cell(kind)
        img = sc.compose()
        ox, oy = pad + i * CW, 4
        m = sc.kind > 0
        region = out[oy:oy + CH, ox:ox + CW]
        region[m] = img[m]
        kinds[oy:oy + CH, ox:ox + CW] |= m.astype(np.int8)
        if kind == "lot":
            LOTTAG.append((ox, oy, sc))
    out = outline_silhouette(out, kinds)
    for ox, oy, sc in LOTTAG:
        X, Y = sc.ipt(11.0, 11.0, 2.0)
        tag(out, ox + X, oy + Y - 8, kind="sale", text="SE VENDE", price="85.000 €")
    for i, (name, kind) in enumerate(TIERS):
        ox, oy = pad + i * CW, 4
        # label pill
        lab = f"{i}  {name}" if False else name
        tw = text_width(name, F35)
        bw = tw + 16
        x0 = ox + (CW - bw) // 2
        bw = tw + 17
        x0 = ox + (CW - bw) // 2
        y0 = oy + CH - 20
        panel(out, x0, y0, x0 + bw, y0 + 10, fill="uiL")
        cx = x0 + 2
        out[y0 + 2:y0 + 8, cx:cx + 7] = PAL["teaL"]
        out[y0 + 2, cx] = PAL["uiL"]; out[y0 + 2, cx + 6] = PAL["uiL"]; out[y0 + 7, cx] = PAL["uiL"]; out[y0 + 7, cx + 6] = PAL["uiL"]
        draw_text(out, str(i + 1), cx + 2, y0 + 2, PAL["white"], F35)
        draw_text(out, name, x0 + 12, y0 + 3, PAL["ink"], F35)
        if i < len(TIERS) - 1:
            ax, ay = ox + CW - 2, oy + CH - 17
            for k, row in enumerate(["#..", "##.", "###", "##.", "#.."]):
                for j, ch in enumerate(row):
                    if ch == "#": out[ay + k, ax + j] = PAL["teaD"]
    big = Image.fromarray(out, "RGB").resize((Wt * 2, Ht * 2), Image.NEAREST)
    big.save(os.path.join(HERE, "tiers.png"))
    print("tiers", big.size)


if __name__ == "__main__":
    main()
