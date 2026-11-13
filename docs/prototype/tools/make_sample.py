"""Generate a hand-made OSM sample of a few Eixample (Barcelona) blocks, in the exact
JSON shape Overpass returns for `out body geom;`.  Used because overpass-api.de is
blocked from this sandbox.  Geometry follows the real Cerdà grid (113.3 m chamfered
blocks, 20 m streets, grid rotated ~45 deg), but individual buildings are synthetic.
"""
import json, math, random, sys

LAT0, LON0 = 41.3925, 2.1625          # around Rambla Catalunya / Consell de Cent
BEARING = math.radians(44.6)          # direction of the "sea-parallel" streets (Arago...)
BLOCK = 113.3                         # manzana side (m)
STREET = 20.0                         # standard street width (m)
PITCH = BLOCK + STREET
CHAMFER = 14.1                        # 20 m xamfra diagonal

rnd = random.Random(1859)             # year of the Pla Cerda

# local axes: a = along Arago (bearing 44.6), b = along Passeig de Gracia (bearing 314.6)
ax = (math.sin(BEARING), math.cos(BEARING))                 # east, north components
bx = (math.sin(BEARING - math.pi / 2), math.cos(BEARING - math.pi / 2))

def to_latlon(a, b):
    e = a * ax[0] + b * bx[0]
    n = a * ax[1] + b * bx[1]
    lat = LAT0 + n / 110540.0
    lon = LON0 + e / (111320.0 * math.cos(math.radians(LAT0)))
    return {"lat": round(lat, 7), "lon": round(lon, 7)}

elements = []
next_id = [900000000]
def way(coords, tags, closed=True):
    pts = list(coords) + ([coords[0]] if closed else [])
    next_id[0] += rnd.randint(3, 400)
    elements.append({"type": "way", "id": next_id[0], "tags": tags,
                     "geometry": [to_latlon(a, b) for a, b in pts]})

COLS = ["Carrer de Balmes", "Rambla de Catalunya", "Passeig de Gracia",
        "Carrer de Pau Claris", "Carrer de Roger de Lluria"]
ROWS = ["Gran Via de les Corts Catalanes", "Carrer de la Diputacio", "Carrer del Consell de Cent",
        "Carrer d'Arago", "Carrer de Valencia"]
NC, NR = 4, 4   # manzanas

# streets (centerlines). col streets run along b, row streets along a.
for i, name in enumerate(COLS):
    a = i * PITCH - STREET / 2
    tags = {"highway": "primary" if "Gracia" in name else "secondary", "name": name}
    if "Gracia" in name: tags["width"] = "30"
    if "Rambla" in name: tags.update({"highway": "tertiary", "width": "26"})
    way([(a, -PITCH * 0.25 - STREET / 2), (a, NR * PITCH)], tags, closed=False)
for j, name in enumerate(ROWS):
    b = j * PITCH - STREET / 2
    tags = {"highway": "primary" if "Gran Via" in name else "secondary", "name": name}
    if "Gran Via" in name: tags["width"] = "34"
    way([(-PITCH * 0.25 - STREET / 2, b), (NC * PITCH, b)], tags, closed=False)

TYPES = (["apartments"] * 14 + ["residential"] * 4 + ["commercial"] * 2 + ["retail"] * 2
         + ["office"] * 2 + ["hotel"])

def octagon(x0, y0, w, h, c):
    return [(x0 + c, y0), (x0 + w - c, y0), (x0 + w, y0 + c), (x0 + w, y0 + h - c),
            (x0 + w - c, y0 + h), (x0 + c, y0 + h), (x0, y0 + h - c), (x0, y0 + c)]

def bldg_tags(kind=None, levels_range=(6, 9)):
    t = {"building": kind or rnd.choice(TYPES)}
    if rnd.random() < 0.62:                      # ~38% of buildings lack building:levels
        t["building:levels"] = str(rnd.randint(*levels_range))
    return t

def split_len(total, lo=11, hi=24):
    cuts, pos = [], 0.0
    while total - pos > hi:
        w = rnd.uniform(lo, hi); cuts.append(w); pos += w
    cuts.append(total - pos)
    return cuts

for cj in range(NR):
    for ci in range(NC):
        x0 = ci * PITCH + (5 if ci in (1, 2) else 0)        # Passeig de Gracia is wider
        w = BLOCK - (5 if ci in (1, 2) else 0) - (5 if ci == 1 else 0)
        y0 = cj * PITCH + (7 if cj == 0 else 0)             # Gran Via is wider
        h = BLOCK - (7 if cj == 0 else 0)
        if (ci, cj) == (3, 2):                               # an empty lot -> procedural plots
            way(octagon(x0, y0, w, h, CHAMFER), {"landuse": "brownfield", "name": "Solar"})
            continue
        d = rnd.uniform(22, 27)                              # typical building depth
        # 4 corner plots (chamfered)
        corners = [
            [(x0 + CHAMFER, y0), (x0 + d, y0), (x0 + d, y0 + d), (x0, y0 + d), (x0, y0 + CHAMFER)],
            [(x0 + w - d, y0), (x0 + w - CHAMFER, y0), (x0 + w, y0 + CHAMFER), (x0 + w, y0 + d), (x0 + w - d, y0 + d)],
            [(x0 + w - d, y0 + h - d), (x0 + w, y0 + h - d), (x0 + w, y0 + h - CHAMFER), (x0 + w - CHAMFER, y0 + h), (x0 + w - d, y0 + h)],
            [(x0, y0 + h - d), (x0 + d, y0 + h - d), (x0 + d, y0 + h), (x0 + CHAMFER, y0 + h), (x0, y0 + h - CHAMFER)],
        ]
        for poly in corners:
            way(poly, bldg_tags(levels_range=(7, 10)))
        # side strips
        for side in range(4):
            length = (w if side % 2 == 0 else h) - 2 * d
            pos = d
            for seg in split_len(length):
                dd = min(d + rnd.uniform(-4, 6), 31)
                if side == 0:   p = [(x0 + pos, y0), (x0 + pos + seg, y0), (x0 + pos + seg, y0 + dd), (x0 + pos, y0 + dd)]
                elif side == 2: p = [(x0 + pos, y0 + h - dd), (x0 + pos + seg, y0 + h - dd), (x0 + pos + seg, y0 + h), (x0 + pos, y0 + h)]
                elif side == 1: p = [(x0 + w - dd, y0 + pos), (x0 + w, y0 + pos), (x0 + w, y0 + pos + seg), (x0 + w - dd, y0 + pos + seg)]
                else:           p = [(x0, y0 + pos), (x0 + dd, y0 + pos), (x0 + dd, y0 + pos + seg), (x0, y0 + pos + seg)]
                kind = None
                if (ci, cj) == (0, 3) and side == 0 and pos < 40: kind = "church"
                if (ci, cj) == (0, 3) and side == 1 and pos < 50: kind = "school"
                way(p, bldg_tags(kind, (5, 8) if kind else (6, 9)))
                pos += seg
        # interior of the manzana: garden, low commercial roofs, or both
        ix0, iy0, iw, ih = x0 + 33, y0 + 33, w - 66, h - 66
        r = rnd.random()
        if r < 0.4:
            way([(ix0, iy0), (ix0 + iw, iy0), (ix0 + iw, iy0 + ih), (ix0, iy0 + ih)], {"leisure": "garden", "name": "Interior d'illa"})
        elif r < 0.75:
            way([(ix0 - 2, iy0 - 2), (ix0 + iw * 0.6, iy0 - 2), (ix0 + iw * 0.6, iy0 + ih + 2), (ix0 - 2, iy0 + ih + 2)], {"building": "retail", "building:levels": "1"})
            way([(ix0 + iw * 0.6 + 4, iy0), (ix0 + iw, iy0), (ix0 + iw, iy0 + ih), (ix0 + iw * 0.6 + 4, iy0 + ih)], {"leisure": "garden"})
        else:
            way([(ix0, iy0), (ix0 + iw, iy0), (ix0 + iw, iy0 + ih), (ix0, iy0 + ih)], {"building": "commercial", "building:levels": "1"})

out = {"version": 0.6, "generator": "hand-made sample in Overpass API JSON shape",
       "osm3s": {"copyright": "SYNTHETIC SAMPLE modelled on the Eixample grid; real data would be (c) OpenStreetMap contributors, ODbL"},
       "elements": elements}
json.dump(out, open(sys.argv[1], "w"), indent=0)
print(len(elements), "elements")
