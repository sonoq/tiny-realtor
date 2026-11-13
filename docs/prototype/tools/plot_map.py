"""Top-down map of the saved block: every plot coloured by category (shows the subdivision)."""
import json, sys
from PIL import Image, ImageDraw, ImageFont
from shapely.geometry import LineString
B = json.load(open(sys.argv[1]))
COL = {"residential": "#c9714b", "commercial": "#4f86b8", "office": "#7d8aa3", "hotel": "#9a6bb0",
       "civic": "#d9c27a", "house": "#b5533e", "empty": "#b08d5e"}
S = 1.6
xs = [c[0] for p in B["plots"] for c in p["poly"]]; ys = [c[1] for p in B["plots"] for c in p["poly"]]
mx, my = min(xs) - 25, max(ys) + 25
W, H = int((max(xs) - min(xs) + 50) * S), int((max(ys) - min(ys) + 50) * S) + 40
T = lambda x, y: ((x - mx) * S, (my - y) * S)
img = Image.new("RGB", (W, H), "#cfc6b4"); d = ImageDraw.Draw(img)
for r in B["roads"]:
    g = LineString(r["line"]).buffer(r["width"] / 2, cap_style=2)
    d.polygon([T(*c) for c in g.exterior.coords], fill="#5b5d66")
for g in B["greens"]:
    d.polygon([T(*c) for c in g["poly"]], fill="#6f9e4c")
for p in B["plots"]:
    pts = [T(*c) for c in p["poly"]]
    fill = COL.get(p["cat"], "#888")
    d.polygon(pts, fill=fill, outline="#2b2630")
    if p["levels_src"] == "estimated":   # hatch plots whose height was guessed
        x0 = min(q[0] for q in pts); y0 = min(q[1] for q in pts)
        d.point([(x0 + 3, y0 + 3)], fill="#ffffff")
try: f = ImageFont.load_default(size=13)
except TypeError: f = ImageFont.load_default()
x = 6
for k, c in COL.items():
    d.rectangle([x, H - 28, x + 12, H - 16], fill=c, outline="#2b2630"); d.text((x + 16, H - 30), k, fill="#2b2630", font=f)
    x += 16 + int(d.textlength(k, font=f)) + 14
img.save(sys.argv[2]); print(img.size, len(B["plots"]), "plots")
