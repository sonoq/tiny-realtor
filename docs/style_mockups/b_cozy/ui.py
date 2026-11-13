"""Background, floating shadow and the light rounded-pixel HUD."""
import math
import numpy as np
from engine import PAL, F35, F57, draw_text, text_width, ihash

BAYER = np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) / 16.0


def draw_sky(W, H, stops=None):
    stops = stops or [(0.0, "sky0"), (0.35, "sky1"), (0.62, "sky2"), (1.0, "sky3")]
    out = np.zeros((H, W, 3), np.uint8)
    yy, xx = np.mgrid[0:H, 0:W]
    t = yy / (H - 1)
    th = BAYER[yy % 4, xx % 4]
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        m = (t >= a) & (t <= b)
        f = (t - a) / (b - a)
        use_b = f > th
        out[m & ~use_b] = PAL[ca]
        out[m & use_b] = PAL[cb]
    # puffy flat-bottomed clouds
    for (cx, cy, s) in [(44, 72, 1.0), (262, 126, 0.85), (214, 54, 0.6), (70, 168, 0.6), (150, 40, 0.45)]:
        puffs = [(-14, 1, 5), (-7, -2, 7), (2, -4, 9), (11, -1, 7), (18, 1, 5)]
        mask = np.zeros((H, W), bool)
        hi = np.zeros((H, W), bool)
        for bx, by, r in puffs:
            r *= s; X = cx + bx * s; Y = cy + by * s
            d = (xx - X) ** 2 + (yy - Y) ** 2
            mask |= d <= r * r
            hi |= ((xx - X + r * 0.35) ** 2 + (yy - Y + r * 0.45) ** 2) <= (r * 0.55) ** 2
        mask &= yy <= cy + 3 * s
        out[mask] = PAL["cloud"]
        under = mask & (yy >= cy + 1 * s)
        out[under] = PAL["cloud2"]
        rim = mask & ~np.roll(mask, -1, 0) & ~under
        out[rim] = PAL["cloud2"]
    # a few birds
    for bx, by in [(118, 58), (126, 54), (122, 62), (238, 92)]:
        for dx, dy in ((0, 0), (1, 1), (2, 0), (-1, -0)):
            pass
        out[by, bx] = PAL["ink2"]; out[by + 1, bx + 1] = PAL["ink2"]; out[by, bx + 2] = PAL["ink2"]
        out[by - 1, bx - 1] = PAL["ink2"]; out[by - 1, bx + 3] = PAL["ink2"]
    return out


def draw_float_shadow(bg, sc, tile, slab):
    x0, y0, x1, y1 = tile
    fx, fy = sc.proj(x1, y0, 0)
    lx, _ = sc.proj(x0, y0, 0); rx, _ = sc.proj(x1, y1, 0)
    H, W = bg.shape[:2]
    yy, xx = np.mgrid[0:H, 0:W]
    cx, cy = (lx + rx) / 2, fy + slab + 15
    rxr, ryr = (rx - lx) * 0.36, 7.5
    d = ((xx - cx) / rxr) ** 2 + ((yy - cy) / ryr) ** 2
    core = d < 0.55
    mid = (d >= 0.55) & (d < 1.0) & ((xx + yy) % 2 == 0)
    edge = (d >= 1.0) & (d < 1.35) & ((xx % 2 == 0) & (yy % 2 == 0))
    bg[core | mid | edge] = PAL["floatsh"]


def outline_silhouette(out, kind, color="ink2"):
    obj = kind > 0
    sky = ~obj
    nb = np.zeros_like(obj)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        nb |= np.roll(np.roll(sky, dy, 0), dx, 1)
    edge = obj & nb & (kind != 3)
    edge[0, :] = edge[-1, :] = False; edge[:, 0] = edge[:, -1] = False
    o = out.copy()
    o[edge] = PAL[color]
    return o


# ------------------------------------------------------------------ widgets ---------
def panel(a, x0, y0, x1, y1, fill="uiL", line="ink", shade="uiD", hi="white", drop=True):
    if drop:
        a[y1 + 1, x0 + 2:x1 - 1] = PAL["ink2"]
    a[y0 + 1:y1, x0 + 1:x1] = PAL[fill]
    a[y0, x0 + 2:x1 - 1] = PAL[line]; a[y1, x0 + 2:x1 - 1] = PAL[line]
    a[y0 + 2:y1 - 1, x0] = PAL[line]; a[y0 + 2:y1 - 1, x1] = PAL[line]
    for (px, py) in ((x0 + 1, y0 + 1), (x1 - 1, y0 + 1), (x0 + 1, y1 - 1), (x1 - 1, y1 - 1)):
        a[py, px] = PAL[line]
    a[y1 - 1, x0 + 2:x1 - 1] = PAL[shade]
    a[y1 - 2, x0 + 1] = PAL[shade]; a[y1 - 2, x1 - 1] = PAL[shade]
    a[y0 + 1, x0 + 2:x1 - 1] = PAL[hi]


def _darker(px):
    return (px.astype(int) * np.array([0.86, 0.80, 0.84])).astype(np.uint8)


def icon(a, rows, x, y, cmap):
    for j, r in enumerate(rows):
        for i, ch in enumerate(r):
            if ch in ". ": continue
            a[y + j, x + i] = PAL[cmap[ch]]


COIN = [".ooo.",
        "oyyyo",
        "oyhyo",
        "oyyyo",
        ".ooo."]
COIN7 = ["..ooo..",
         ".oyyyo.",
         "oyhyyyo",
         "oyhyyyo",
         "oyyyyyo",
         ".oyyyo.",
         "..ooo.."]
COIN7 = ["..ddd..",
         ".dyyyd.",
         "dyhhyyd",
         "dyhyyod",
         "dyyyyod",
         ".dyood.",
         "..ddd.."]
HOUSE_PLUS = ["....#....",
              "...###...",
              "..#####..",
              ".#######.",
              "..#...#..",
              "..#.#.#..",
              "..#.#.#.."]
ARROW_UP = ["...#...",
            "..###..",
            ".#####.",
            "###.###",
            "..###..",
            "..###..",
            "..###.."]
ARROW_UP = ["...#...",
            "..###..",
            ".#####.",
            "#######",
            "..###..",
            "..###..",
            "..###.."]
MENU = ["#######", ".......", "#######", ".......", "#######"]
LOCPIN = [".###.", "##.##", "#####", ".###.", "..#.."]
KEY = [".##....", "#..####", ".##.#.#"]


def button(a, x, y, size, fill, fill_d, icon_rows, icon_col):
    x1, y1 = x + size - 1, y + size - 1
    # round-ish button: panel with stronger bevel
    panel(a, x, y, x1, y1, fill=fill, line="ink", shade=fill_d, hi="white")
    ih, iw = len(icon_rows), len(icon_rows[0])
    ix, iy = x + (size - iw) // 2, y + (size - ih) // 2
    for j, r in enumerate(icon_rows):
        for i, ch in enumerate(r):
            if ch == "#":
                a[iy + j + 1, ix + i] = PAL[fill_d]
    for j, r in enumerate(icon_rows):
        for i, ch in enumerate(r):
            if ch == "#":
                a[iy + j, ix + i] = PAL[icon_col]


def fmt(n):
    return f"{n:,}".replace(",", ".")


def hud(a, sc, owned, tags, money=1284300, income=7560):
    H, W = a.shape[:2]
    # ---- money panel (top-left)
    s = fmt(money)
    tw = text_width(s, F57)
    x0, y0 = 4, 4
    x1 = x0 + 6 + 7 + 4 + tw + 3 + 5 + 6
    panel(a, x0, y0, x1, y0 + 16)
    icon(a, COIN7, x0 + 5, y0 + 5, {"d": "golD", "y": "golL", "h": "golH", "o": "golD"})
    cx = draw_text(a, s, x0 + 16, y0 + 5, PAL["ink"], F57, gap=1, shadow=PAL["uiD"])
    draw_text(a, "€", cx + 2, y0 + 5, PAL["golD"], F57, gap=1)
    # ---- income pill
    inc = "+" + fmt(income) + " €/MIN"
    iw = text_width(inc, F35)
    panel(a, x0 + 3, y0 + 19, x0 + 3 + iw + 10, y0 + 29, fill="teaH", line="teaX", shade="teaL", hi="white")
    draw_text(a, inc, x0 + 9, y0 + 22, PAL["teaX"], F35)
    # small up-trend arrow
    icon(a, ["..#", ".#.", "#.."], x0 + 5, y0 + 23, {"#": "teaX"}) if False else None
    # ---- buttons (top-right)
    bs = 19
    bx = W - 4 - bs
    button(a, bx, 4, bs, "uiL", "uiD", MENU, "ink2")
    button(a, bx - bs - 3, 4, bs, "teaL", "teaD", ARROW_UP, "white")
    button(a, bx - 2 * (bs + 3), 4, bs, "corL", "corD", HOUSE_PLUS, "white")
    # counter of properties under the buttons
    lab = f"{len(owned)} FINCAS"
    lw = text_width(lab, F35)
    px1 = W - 4; px0 = px1 - lw - 16
    panel(a, px0, 26, px1, 36)
    icon(a, ["..#..", ".###.", "#####", ".#.#.", ".###."], px0 + 4, 29, {"#": "corL"})
    draw_text(a, lab, px0 + 11, 29, PAL["ink"], F35)
    # ---- location pill (bottom-left)
    loc = "EIXAMPLE, BARCELONA"
    lw = text_width(loc, F35)
    panel(a, 4, H - 17, 4 + lw + 17, H - 6)
    icon(a, LOCPIN, 9, H - 14, {"#": "corL"})
    a[H - 13, 11] = PAL["white"]
    draw_text(a, loc, 17, H - 14, PAL["ink"], F35)
    # ---- OSM credit (bottom-right)
    cr = "© OPENSTREETMAP CONTRIBUTORS"
    cw = text_width(cr, F35)
    draw_text(a, cr, W - 5 - cw, H - 11, PAL["ink2"], F35)

    # ---- ownership pins above owned buildings
    for (x, y, z) in getattr(sc, "pins", []):
        X, Y = sc.ipt(x, y, z)
        pin(a, X, Y - 3)
    # ---- income pops (coin + amount) rising from owned buildings
    for (x, y, z, txt) in tags.get("pops", []):
        X, Y = sc.ipt(x, y, z)
        icon(a, COIN7, X - 3, Y - 3, {"d": "golD", "y": "golL", "h": "golH", "o": "golD"})
        tw = text_width(txt, F35)
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1), (1, 1)):
            draw_text(a, txt, X + 6 + dx, Y - 2 + dy, PAL["white"], F35)
        draw_text(a, txt, X + 6, Y - 2, PAL["golD"], F35)
    # ---- world tags: construction progress
    if "cons" in tags:
        X, Y = sc.ipt(*tags["cons"])
        tag(a, X, Y - 4, kind="progress", pct=0.62)
    if "lot" in tags:
        X, Y = sc.ipt(*tags["lot"])
        tag(a, X, Y - 10, kind="sale", text="SE VENDE", price="85.000 €")


def tag(a, X, Y, kind, pct=0.0, text="", price=""):
    """floating speech-bubble tag whose pointer tip is at (X, Y)"""
    if kind == "progress":
        bw = 34
        x0, y0 = X - bw // 2, Y - 13
        panel(a, x0, y0, x0 + bw, y0 + 10)
        bl, br = x0 + 3, x0 + bw - 13
        a[y0 + 3:y0 + 7, bl:br] = PAL["uiD"]
        fw = int((br - bl) * pct)
        a[y0 + 3:y0 + 7, bl:bl + fw] = PAL["golL"]
        a[y0 + 3, bl:bl + fw] = PAL["golH"]
        a[y0 + 6, bl:bl + fw] = PAL["golD"]
        draw_text(a, f"{int(pct * 100)}%", br + 2, y0 + 3, PAL["ink"], F35)
        fill, line = "uiL", "ink"
    else:
        t1w = text_width(text, F35); t2w = text_width(price, F35)
        bw = max(t1w, t2w) + 8
        x0, y0 = X - bw // 2, Y - 17
        panel(a, x0, y0, x0 + bw, y0 + 14, fill="corL", line="ink", shade="corD", hi="corH")
        draw_text(a, text, x0 + (bw - t1w) // 2 + 1, y0 + 2, PAL["white"], F35, shadow=PAL["corD"])
        draw_text(a, price, x0 + (bw - t2w) // 2 + 1, y0 + 8, PAL["white"], F35, shadow=PAL["corD"])
        y0 = y0 + 4
        fill, line = "corL", "ink"
    yb = y0 + (10 if kind == "progress" else 10)
    a[yb, X - 1:X + 2] = PAL[fill]
    a[yb + 1, X - 1] = PAL[line]; a[yb + 1, X + 1] = PAL[line]; a[yb + 1, X] = PAL[fill]
    a[yb + 2, X] = PAL[line]


PIN = ["..#####..",
       ".#hhttt#.",
       "#hhtwttt#",
       "#htwwwtt#",
       "#twwwwwt#",
       "#ttwtwtt#",
       ".#twtwt#.",
       "..#ttt#..",
       "...#t#...",
       "....#...."]


def pin(a, X, Y):
    """teal map-pin with a white house: anchored at its tip (X, Y)"""
    h = len(PIN)
    x0, y0 = X - 4, Y - h + 1
    cm = {"#": "teaX", "t": "teaL", "h": "teaH", "w": "white"}
    for j, r in enumerate(PIN):
        for i, ch in enumerate(r):
            if ch != "." and 0 <= y0 + j < a.shape[0] and 0 <= x0 + i < a.shape[1]:
                a[y0 + j, x0 + i] = PAL[cm[ch]]
