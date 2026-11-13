"""Bake raw Overpass JSON into a self-contained 'saved block' JSON the game would keep.
usage: bake_block.py raw.json baked.json
Steps: project lat/lon -> metres, align the street grid with the axes, buffer roads,
turn buildings into plots, split empty land into plots (recursive OBB split),
fill in missing heights with a deterministic hash, rasterize a coarse tile grid.
"""
import json, math, sys, hashlib
from shapely.geometry import Polygon, LineString, Point, box
from shapely.ops import unary_union
from shapely import affinity
from shapely.strtree import STRtree

raw = json.load(open(sys.argv[1]))
els = raw["elements"]

# --- 1. projection (local equirectangular, metres) --------------------------------
lats = [p["lat"] for e in els for p in e["geometry"]]
lons = [p["lon"] for e in els for p in e["geometry"]]
lat0, lon0 = sum(lats) / len(lats), sum(lons) / len(lons)
kx, ky = 111320.0 * math.cos(math.radians(lat0)), 110540.0
def proj(g): return [((p["lon"] - lon0) * kx, (p["lat"] - lat0) * ky) for p in g]

# --- 2. dominant street direction -> rotate so streets are axis aligned ------------
hist = [0.0] * 90
for e in els:
    if "highway" not in e["tags"]: continue
    pts = proj(e["geometry"])
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        ang = math.degrees(math.atan2(y2 - y1, x2 - x1)) % 90
        hist[int(ang)] += math.hypot(x2 - x1, y2 - y1)
rot = -max(range(90), key=lambda i: hist[i]) - 0.5   # degrees
def geom(pts): return affinity.rotate(Polygon(pts), rot, origin=(0, 0)) if len(pts) > 3 else None

# --- 3. roads -----------------------------------------------------------------------
WIDTH = {"motorway": 24, "trunk": 22, "primary": 20, "secondary": 18, "tertiary": 14,
         "residential": 10, "service": 6, "footway": 3, "pedestrian": 8}
roads, road_lines = [], []
for e in els:
    t = e["tags"]
    if "highway" not in t: continue
    w = float(t.get("width", WIDTH.get(t["highway"], 10)))
    line = affinity.rotate(LineString(proj(e["geometry"])), rot, origin=(0, 0))
    road_lines.append(line)
    roads.append({"name": t.get("name", ""), "kind": t["highway"], "width": w,
                  "line": [[round(x, 1), round(y, 1)] for x, y in line.coords]})

# --- 4. plots -------------------------------------------------------------------------
CATS = {"apartments": "residential", "residential": "residential", "house": "house",
        "detached": "house", "commercial": "commercial", "retail": "commercial",
        "office": "office", "hotel": "hotel", "church": "civic", "school": "civic",
        "yes": "residential"}

def h01(*parts):  # deterministic hash -> [0,1)
    return int(hashlib.sha1("|".join(map(str, parts)).encode()).hexdigest()[:8], 16) / 2**32

def obb_split(poly, seed, min_area=280.0, max_area=750.0, depth=0):
    """Recursive oriented-bounding-box split (Parish & Mueller / Vanegas style, simplified)."""
    if poly.area <= max_area or depth > 10:
        return [poly] if poly.area >= min_area * 0.5 else []
    obb = poly.minimum_rotated_rectangle
    c = list(obb.exterior.coords)
    e1 = (c[1][0] - c[0][0], c[1][1] - c[0][1]); e2 = (c[2][0] - c[1][0], c[2][1] - c[1][1])
    long_e = e1 if math.hypot(*e1) >= math.hypot(*e2) else e2
    L = math.hypot(*long_e); ux, uy = long_e[0] / L, long_e[1] / L
    t = 0.5 + (h01(seed, depth) - 0.5) * 0.3           # cut near the middle, jittered
    cx, cy = obb.centroid.x, obb.centroid.y
    off = (t - 0.5) * L
    px, py = cx + ux * off, cy + uy * off
    big = 1e4
    half = Polygon([(px - uy * big, py + ux * big), (px + uy * big, py - ux * big),
                    (px + uy * big - ux * big, py - ux * big - uy * big),
                    (px - uy * big - ux * big, py + ux * big - uy * big)])
    a, b = poly.intersection(half), poly.difference(half)
    out = []
    for k, part in enumerate((a, b)):
        for g in getattr(part, "geoms", [part]):
            if g.geom_type == "Polygon" and g.area > 1:
                out += obb_split(g, f"{seed}.{k}", min_area, max_area, depth + 1)
    return out

plots, greens = [], []
for e in els:
    t = e["tags"]
    g = geom(proj(e["geometry"]))
    if g is None: continue
    if "building" in t:
        lv_tag = t.get("building:levels")
        if lv_tag: levels, src = int(float(lv_tag)), "osm"
        else:      levels, src = 5 + int(h01(e["id"], "lv") * 4), "estimated"   # Eixample-ish 5..8
        plots.append({"id": f"w{e['id']}", "cat": CATS.get(t["building"], "residential"),
                      "osm_type": t["building"], "levels": levels, "levels_src": src,
                      "geom": g, "owned": False, "tier": 0})
    elif "landuse" in t:
        # empty land: inset a frontage ring, split it, keep the middle as a courtyard
        ring_in = g.buffer(-24, join_style=2)
        frontage = g.difference(ring_in) if not ring_in.is_empty else g
        parts = []
        for gg in getattr(frontage, "geoms", [frontage]):
            parts += obb_split(gg, e["id"])
        for k, p in enumerate(parts):
            plots.append({"id": f"w{e['id']}_{k}", "cat": "empty", "osm_type": t["landuse"],
                          "levels": 0, "levels_src": "none", "geom": p, "owned": False, "tier": 0})
        if not ring_in.is_empty: greens.append({"kind": "courtyard", "geom": ring_in})
    elif "leisure" in t:
        greens.append({"kind": t["leisure"], "geom": g})

# --- 5. coarse tile grid (what the game logic would use for clicks/placement) ---------
TILE = 4.0
allg = unary_union([p["geom"] for p in plots] + [r["geom"] for r in greens])
minx, miny, maxx, maxy = allg.bounds
minx, miny = math.floor(minx / TILE) * TILE - 16, math.floor(miny / TILE) * TILE - 16
gw, gh = int((maxx - minx) / TILE) + 9, int((maxy - miny) / TILE) + 9
tree = STRtree([p["geom"] for p in plots])
rows = []
for j in range(gh):
    row = []
    for i in range(gw):
        pt = Point(minx + (i + .5) * TILE, miny + (j + .5) * TILE)
        hit = tree.query(pt, predicate="intersects")
        row.append(int(hit[0]) + 1 if len(hit) else 0)   # 0 = street/patio, n = plot index+1
    rows.append(row)

def ring(g): return [[round(x, 1), round(y, 1)] for x, y in list(g.exterior.coords)[:-1]]
baked = {
    "format": "tiny-realestate-block", "format_version": 1,
    "source": "hand-made Overpass-shaped sample (Overpass blocked in sandbox)",
    "attribution": "(c) OpenStreetMap contributors (when real OSM data is used)",
    "center": {"lat": round(lat0, 6), "lon": round(lon0, 6)}, "rotation_deg": round(rot, 2),
    "seed": 1859,
    "roads": roads,
    "greens": [{"kind": r["kind"], "poly": ring(r["geom"])} for r in greens],
    "plots": [{k: v for k, v in p.items() if k != "geom"} | {
                  "poly": ring(p["geom"]), "area_m2": round(p["geom"].area),
                  "height_m": round(p["levels"] * 3.2 + (1.0 if p["levels"] else 0), 1)}
              for p in plots],
    "grid": {"tile_m": TILE, "origin": [minx, miny], "w": gw, "h": gh,
             "cells": [",".join(map(str, r)) for r in rows]},
}
json.dump(baked, open(sys.argv[2], "w"), separators=(",", ":"))
n_est = sum(p["levels_src"] == "estimated" for p in plots)
print(f"rot={rot:.1f}deg plots={len(plots)} (levels estimated for {n_est}), "
      f"greens={len(greens)} roads={len(roads)} grid={gw}x{gh}")
