"""Render a baked block (block_saved.json) as procedural isometric pixel art.
usage: render_iso.py block_saved.json out_dir
Everything is maths: footprints are extruded to height, walls are shaded by facing,
windows/roof props/trees are placed with a deterministic hash, then the low-res image
is upscaled with nearest-neighbour so pixels stay crisp.
"""
import json, math, sys, hashlib, os
from PIL import Image, ImageDraw, ImageFont
from shapely.geometry import Polygon, LineString, Point
from shapely.ops import unary_union

B = json.load(open(sys.argv[1])); OUT = sys.argv[2]

def h01(*parts):
    return int(hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:8], 16) / 2**32

def hexc(s): return tuple(int(s[i:i + 2], 16) for i in (1, 3, 5))
def mul(c, f): return tuple(max(0, min(255, int(v * f))) for v in c)
def mix(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

PAL = {  # small fixed palette = pixel-art look
    "paving": hexc("#cfc6b4"), "paving2": hexc("#c4bba8"), "curb": hexc("#a39a88"),
    "asphalt": hexc("#5b5d66"), "asphalt2": hexc("#55575f"), "mark": hexc("#e8e2cf"),
    "green": hexc("#6f9e4c"), "green2": hexc("#5d8a40"), "dirt": hexc("#b08d5e"), "dirt2": hexc("#9f7e52"),
    "tree": hexc("#4f8a3a"), "tree_hi": hexc("#76b04f"), "tree_lo": hexc("#3a6a2c"), "trunk": hexc("#6b4a2f"),
    "outline": hexc("#2b2630"), "glass": hexc("#3d4a63"), "glass_hi": hexc("#9fc3dc"), "shop": hexc("#2f3442"),
}
ROOF = {  # roof colour by plot category ("plots coloured by building type")
    "residential": ["#c9714b", "#d08355", "#bd6644"], "house": ["#b5533e"],
    "commercial": ["#4f86b8", "#5a93c4"], "office": ["#7d8aa3", "#8a97ae"],
    "hotel": ["#9a6bb0"], "civic": ["#d9c27a"], "empty": ["#b08d5e"],
}
FACADE = {
    "residential": ["#e6d3ad", "#dcc39a", "#e9c9a4", "#d8b892", "#e3dccb", "#d9a98a"],
    "house": ["#e8d8b8"], "commercial": ["#c9d3dc", "#b9c6d2"], "office": ["#aeb7c4", "#c0c6cf"],
    "hotel": ["#e2d2e6"], "civic": ["#e4d7b0"],
}
LIGHT_R, LIGHT_L, TOPF = 1.0, 0.78, 1.0      # right-facing walls lit, left-facing in shade

# ---- projection -----------------------------------------------------------------------
# ground (x east-ish, y north-ish) after grid alignment. u = x, v = -y. viewer at +u,+v.
def make_proj(s, sz, ox, oy):
    def P(x, y, z=0.0):
        u, v = x, -y
        return (round((u - v) * s + ox), round((u + v) * s * 0.5 - z * sz + oy))
    return P

def bbox_uv(poly):
    us = [p[0] for p in poly]; vs = [-p[1] for p in poly]
    return min(us), max(us), min(vs), max(vs)

def signed_area(poly):
    return sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(poly, poly[1:] + poly[:1])) / 2

# ---- scene objects ---------------------------------------------------------------------
def build_objects(owned_ids=()):
    objs = []
    for idx, p in enumerate(B["plots"]):
        if p["cat"] == "empty" or p["height_m"] <= 0: continue
        poly = [tuple(c) for c in p["poly"]]
        h = p["height_m"]
        objs.append({"kind": "bldg", "poly": poly, "z0": 0, "z1": h, "plot": p, "idx": idx,
                     "owned": p["id"] in owned_ids})
        # roof props: stairwell boxes / water tanks on bigger roofs (Eixample "casetes")
        g = Polygon(poly)
        if g.area > 140:
            n = 1 + int(h01(p["id"], "props") * 2)
            c = g.centroid
            for k in range(n):
                dx = (h01(p["id"], k, "x") - .5) * min(10, math.sqrt(g.area) * .4)
                dy = (h01(p["id"], k, "y") - .5) * min(10, math.sqrt(g.area) * .4)
                w = 2.5 + h01(p["id"], k, "w") * 2.5
                bx = [(c.x + dx - w / 2, c.y + dy - w / 2), (c.x + dx + w / 2, c.y + dy - w / 2),
                      (c.x + dx + w / 2, c.y + dy + w / 2), (c.x + dx - w / 2, c.y + dy + w / 2)]
                if g.contains(Polygon(bx)):
                    objs.append({"kind": "prop", "poly": bx, "z0": h, "z1": h + 2.2,
                                 "parent": len(objs) - 1 - k, "plot": p})
    # street trees every ~9 m along both sidewalks, skipping intersections
    road_polys = [LineString(r["line"]).buffer(r["width"] / 2, cap_style=2) for r in B["roads"]]
    roads_u = unary_union(road_polys)
    builds = unary_union([Polygon(p["poly"]) for p in B["plots"]]).buffer(1.5)
    rx = [c[0] for r in B["roads"] for c in r["line"]]; ry = [c[1] for r in B["roads"] for c in r["line"]]
    for r in B["roads"]:
        line = LineString(r["line"])
        for side in (-1, 1):
            off = line.offset_curve(side * (r["width"] / 2 + 2.2))
            L = off.length; d = 4.0
            while d < L:
                pt = off.interpolate(d)
                inside = (min(rx) + 1 < pt.x < max(rx) - 1) and (min(ry) + 1 < pt.y < max(ry) - 1)
                if inside and not roads_u.contains(pt) and not builds.contains(pt):
                    objs.append({"kind": "tree", "poly": [(pt.x - 1.5, pt.y - 1.5), (pt.x + 1.5, pt.y - 1.5),
                                 (pt.x + 1.5, pt.y + 1.5), (pt.x - 1.5, pt.y + 1.5)], "pt": (pt.x, pt.y),
                                 "z0": 0, "z1": 7, "seed": f"{r['name']}{side}{d:.0f}"})
                d += 9.0
    return objs, road_polys

def depth_sort(objs):
    """Topological painter's order for (roughly) axis-aligned footprints in iso."""
    n = len(objs)
    bbs = [bbox_uv(o["poly"]) for o in objs]
    after = [[] for _ in range(n)]; indeg = [0] * n
    eps = 0.05
    order_cells = {}
    for i, (u0, u1, v0, v1) in enumerate(bbs):           # spatial hash to keep it O(n)
        for cu in range(int(u0 // 20), int(u1 // 20) + 2):
            for cv in range(int(v0 // 20), int(v1 // 20) + 2):
                order_cells.setdefault((cu, cv), []).append(i)
    seen = set()
    for cell in order_cells.values():
        for a in cell:
            for b in cell:
                if a >= b or (a, b) in seen: continue
                seen.add((a, b))
                A, Bb = bbs[a], bbs[b]
                # screen-overlap test is implied by being near; decide who is in front
                if objs[a].get("parent") == b: first, second = b, a
                elif objs[b].get("parent") == a: first, second = a, b
                elif A[1] <= Bb[0] + eps and not (Bb[3] <= A[2] + eps): first, second = a, b
                elif Bb[1] <= A[0] + eps and not (A[3] <= Bb[2] + eps): first, second = b, a
                elif A[3] <= Bb[2] + eps: first, second = a, b
                elif Bb[3] <= A[2] + eps: first, second = b, a
                elif objs[a]["z0"] != objs[b]["z0"]:          # prop on roof goes after roof
                    first, second = (a, b) if objs[a]["z0"] < objs[b]["z0"] else (b, a)
                else:
                    ca, cb = (A[0] + A[1] + A[2] + A[3]), (Bb[0] + Bb[1] + Bb[2] + Bb[3])
                    first, second = (a, b) if ca <= cb else (b, a)
                after[first].append(second); indeg[second] += 1
    import heapq
    key = lambda i: bbs[i][0] + bbs[i][2]
    ready = [(key(i), i) for i in range(n) if indeg[i] == 0]; heapq.heapify(ready)
    out = []
    while ready:
        _, i = heapq.heappop(ready); out.append(i)
        for j in after[i]:
            indeg[j] -= 1
            if indeg[j] == 0: heapq.heappush(ready, (key(j), j))
    if len(out) < n:  # cycle fallback
        rest = sorted(set(range(n)) - set(out), key=key); out += rest
    return [objs[i] for i in out]

# ---- drawing ---------------------------------------------------------------------------
def draw_box(dr, P, o, s, sz):
    poly, z0, z1 = o["poly"], o["z0"], o["z1"]
    p = o["plot"]; cat = p["cat"]
    seed = p["id"]
    if o["kind"] == "prop":
        facade = hexc("#d9d2c4"); roof = hexc("#bdb5a6")
    else:
        fl = FACADE.get(cat, FACADE["residential"]); facade = hexc(fl[int(h01(seed, "f") * len(fl))])
        rl = ROOF.get(cat, ROOF["residential"]); roof = hexc(rl[int(h01(seed, "r") * len(rl))])
    ccw = signed_area([(x, -y) for x, y in poly]) > 0       # orientation in (u,v)
    pts = poly
    walls = []
    for a, b in zip(pts, pts[1:] + pts[:1]):
        du, dv = b[0] - a[0], -(b[1] - a[1])
        nu, nv = (dv, -du) if ccw else (-dv, du)
        Ln = math.hypot(nu, nv) or 1; nu, nv = nu / Ln, nv / Ln
        if nu + nv <= 1e-6: continue                        # faces away from viewer
        shade = LIGHT_L + (LIGHT_R - LIGHT_L) * max(0, min(1, (nu - nv + 1) / 2))
        walls.append((a, b, shade, math.hypot(du, dv)))
    for a, b, shade, L in walls:
        q = [P(a[0], a[1], z0), P(b[0], b[1], z0), P(b[0], b[1], z1), P(a[0], a[1], z1)]
        col = mul(facade, shade)
        dr.polygon(q, fill=col)
        if o["kind"] != "bldg":
            dr.line([q[2], q[3]], fill=mul(col, 1.08)); continue
        floors = p["levels"]; fh = (z1 - z0) / max(1, floors)
        if fh * sz >= 2.0 and L > 3:
            nwin = max(1, int(L / 3.6))
            for f in range(floors):
                zf = z0 + f * fh + fh * 0.35
                for k in range(nwin):
                    t = (k + 0.5) / nwin
                    x, y = a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t
                    sx, sy = P(x, y, zf)
                    if f == 0:   # ground floor: shop fronts / doors
                        c = PAL["shop"] if cat in ("commercial", "residential", "hotel") else mul(col, .6)
                        dr.rectangle([sx, sy - max(1, int(fh * sz * .55)), sx + max(0, int(s * 1.2)), sy], fill=mul(c, shade))
                    else:
                        lit = h01(seed, f, k, a) < 0.12
                        c = PAL["glass_hi"] if lit else PAL["glass"]
                        dr.rectangle([sx, sy - max(1, int(fh * sz * .45)), sx + max(0, int(s * 0.7)), sy], fill=mul(c, shade))
            # balcony/cornice line under the top floor + dark base line
            ta, tb = P(a[0], a[1], z1 - 0.6), P(b[0], b[1], z1 - 0.6)
            dr.line([ta, tb], fill=mul(col, 0.82))
        dr.line([q[0], q[1]], fill=mul(col, 0.55))
    top = [P(x, y, z1) for x, y in poly]
    dr.polygon(top, fill=mul(roof, TOPF))
    # pixel outline on the roof edge (parapet) - darker on the far side, light on near side
    dr.line(top + [top[0]], fill=mul(roof, 0.72))
    if o["kind"] == "bldg" and o.get("owned"):
        dr.line(top + [top[0]], fill=hexc("#ffd84a"), width=1)
    # silhouette edges for the visible vertical corners
    for a, b, shade, L in walls:
        dr.line([P(a[0], a[1], z0), P(a[0], a[1], z1)], fill=mul(facade, shade * 0.9))

def draw_tree(dr, P, o, s, sz):
    x, y = o["pt"]
    bx, by = P(x, y, 0)
    r = max(1, round(1.9 * s)); hgt = max(2, round(3.2 * sz))
    dr.line([(bx, by), (bx, by - hgt)], fill=PAL["trunk"])
    cx, cy = bx, by - hgt - r + 1
    dr.ellipse([cx - r, cy - r, cx + r, cy + r], fill=PAL["tree"])
    if r >= 2:
        dr.ellipse([cx - r + 1, cy - r, cx, cy - 1], fill=PAL["tree_hi"])
        dr.point([(cx + r - 1, cy + 1), (cx, cy + r)], fill=PAL["tree_lo"])

def render(s, crop=None, owned_ids=()):
    sz = s * 0.95
    objs, road_polys = build_objects(owned_ids)
    allpts = [c for p in B["plots"] for c in p["poly"]] + [c for r in B["roads"] for c in r["line"]]
    xs = [((x) + (y)) * s for x, y in allpts]; ys = [((x) - (y)) * s * .5 for x, y in allpts]
    ox, oy = -min(xs) + 8, -min(ys) + 60 * sz
    W, H = int(max(xs) - min(xs) + 16), int(max(ys) - min(ys) + 70 * sz)
    P = make_proj(s, sz, ox, oy)
    img = Image.new("RGB", (W, H), hexc("#1f2433")); dr = ImageDraw.Draw(img)
    # the block is a floating diorama slab: rectangle in ground coords + earth sides
    rx = [c[0] for r in B["roads"] for c in r["line"]]; ry = [c[1] for r in B["roads"] for c in r["line"]]
    x0, x1, y0, y1 = min(rx), max(rx), min(ry), max(ry)
    slab = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    dep = 9.0
    dr.polygon([P(x1, y1), P(x1, y0), P(x1, y0, -dep), P(x1, y1, -dep)], fill=hexc("#7a5a3c"))
    dr.polygon([P(x0, y0), P(x1, y0), P(x1, y0, -dep), P(x0, y0, -dep)], fill=hexc("#5e4530"))
    for k in range(1, 3):  # strata lines
        dr.line([P(x0, y0, -dep * k / 3), P(x1, y0, -dep * k / 3), P(x1, y1, -dep * k / 3)], fill=hexc("#4f3a29"))
    dr.polygon([P(x, y) for x, y in slab], fill=PAL["paving"])
    mask = Image.new("L", (W, H), 0); ImageDraw.Draw(mask).polygon([P(x, y) for x, y in slab], fill=255)
    dith = img.copy(); dd = dith.load()
    for j in range(0, H, 2):
        for i in range((j // 2) % 4, W, 4): dd[i, j] = PAL["paving2"]
    img = Image.composite(dith, img, mask); dr = ImageDraw.Draw(img)
    clip = Polygon(slab)
    road_polys = [rp.intersection(clip) for rp in road_polys]
    # roads
    for rp in road_polys:
        for g in getattr(rp, "geoms", [rp]):
            dr.polygon([P(x, y) for x, y in g.exterior.coords], fill=PAL["asphalt"])
    for rp in road_polys:  # curbs
        for g in getattr(rp, "geoms", [rp]):
            c = [P(x, y) for x, y in g.exterior.coords]; dr.line(c, fill=PAL["curb"])
    inter = unary_union([a.intersection(b) for i, a in enumerate(road_polys) for b in road_polys[i + 1:]])
    for g in getattr(inter, "geoms", [inter]):
        if g.is_empty: continue
        dr.polygon([P(x, y) for x, y in g.exterior.coords], fill=PAL["asphalt"])
    # lane dashes + zebra crossings
    for r in B["roads"]:
        line = LineString(r["line"]); d = 0
        while d < line.length:
            p0, p1 = line.interpolate(d), line.interpolate(min(d + 3, line.length))
            if not inter.buffer(2).contains(p0):
                dr.line([P(p0.x, p0.y), P(p1.x, p1.y)], fill=PAL["mark"])
            d += 8
    for g in getattr(inter, "geoms", [inter]):
        if g.is_empty: continue
        mnx, mny, mxx, mxy = g.bounds
        for (x0, y0, x1, y1, horiz) in [(mnx, mny - 4, mxx, mny - 1, True), (mnx, mxy + 1, mxx, mxy + 4, True),
                                         (mnx - 4, mny, mnx - 1, mxy, False), (mxx + 1, mny, mxx + 4, mxy, False)]:
            k = 0.0; span = (x1 - x0) if horiz else (y1 - y0)
            while k < span - 1:
                if horiz: q = [(x0 + k, y0), (x0 + k + 1.2, y0), (x0 + k + 1.2, y1), (x0 + k, y1)]
                else:     q = [(x0, y0 + k), (x1, y0 + k), (x1, y0 + k + 1.2), (x0, y0 + k + 1.2)]
                dr.polygon([P(x, y) for x, y in q], fill=PAL["mark"]); k += 2.6
    # greens, courtyards, empty plots
    for gr in B["greens"]:
        c = [P(x, y) for x, y in gr["poly"]]
        dr.polygon(c, fill=PAL["green"]); dr.line(c + [c[0]], fill=PAL["green2"])
    for p in B["plots"]:
        if p["cat"] != "empty": continue
        c = [P(x, y) for x, y in p["poly"]]
        dr.polygon(c, fill=PAL["dirt"]); dr.line(c + [c[0]], fill=PAL["dirt2"])
        g = Polygon(p["poly"]).centroid; sx, sy = P(g.x, g.y)     # "for sale" sign
        dr.line([(sx, sy), (sx, sy - round(4 * sz))], fill=PAL["trunk"])
        dr.rectangle([sx - round(2 * s), sy - round(7 * sz), sx + round(2 * s), sy - round(4 * sz)], fill=hexc("#e8d44d"))
    # building shadows (cheap: offset footprint toward -u)
    shadow = Image.new("L", (W, H), 0); sd = ImageDraw.Draw(shadow)
    for o in objs:
        if o["kind"] != "bldg": continue
        h = o["z1"] * 0.35
        sd.polygon([P(x - h, y + h * .2) for x, y in o["poly"]], fill=60)
    img = Image.composite(Image.new("RGB", (W, H), (60, 55, 70)), img, shadow.point(lambda v: v))
    dr = ImageDraw.Draw(img)
    # extruded objects in painter's order
    for o in depth_sort(objs):
        if o["kind"] == "tree": draw_tree(dr, P, o, s, sz)
        else: draw_box(dr, P, o, s, sz)
    if crop:
        cx, cy = P(*crop[0]); w, h = crop[1]
        img = img.crop((cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2))
    return img

os.makedirs(OUT, exist_ok=True)
# 1) overview of the whole saved block
ov = render(0.55)
ov = ov.resize((ov.width * 2, ov.height * 2), Image.NEAREST); ov.save(f"{OUT}/iso_overview.png")
# 2) what the 600x600 corner window would show: one manzana, closer, with a tiny HUD
plots = B["plots"]
target = min(plots, key=lambda p: math.hypot(*Polygon(p["poly"]).centroid.coords[0]))
c = Polygon(target["poly"]).centroid
owned = {p["id"] for p in plots if Polygon(p["poly"]).centroid.distance(c) < 60 and h01(p["id"], "own") < .6}
win = render(1.35, crop=((c.x, c.y), (300, 300)), owned_ids=owned)
win = win.resize((600, 600), Image.NEAREST)
d = ImageDraw.Draw(win)
d.rectangle([0, 0, 600, 34], fill=(32, 28, 40)); d.line([(0, 34), (600, 34)], fill=(255, 216, 74))
try: f = ImageFont.load_default(size=18)
except TypeError: f = ImageFont.load_default()
rent = sum(p["levels"] * 140 for p in plots if p["id"] in owned)
d.text((10, 7), f"EUR 1.284.300   +{rent:,}/min".replace(",", "."), fill=(255, 216, 74), font=f)
d.text((420, 7), f"{len(owned)} fincas  Eixample", fill=(220, 220, 230), font=f)
win.save(f"{OUT}/iso_window_600.png")
print("ok", ov.size, win.size, len(owned))
