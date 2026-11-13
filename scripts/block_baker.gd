class_name BlockBaker
extends RefCounted

# Turns one raw Overpass answer (everything within an office's max radius) into the saved block
# that BlockView draws: format "tiny-realestate-block" v2. A GDScript port of
# docs/prototype/tools/bake_block.py, hardened for real data. Steps:
#   1. lat/lon -> local metres around the office (x east, y north)
#   2. find the dominant street direction and turn everything so streets follow the iso axes
#   3. roads: centre lines clipped to the disc, width from the tag or the road class
#   4. plots from buildings (ways and multipolygon outer rings), clipped to the disc; levels from
#      building:levels or height, else the local median of tagged neighbours plus a stable hash
#   5. greens, water (lakes, riverbanks and sea from coastlines), lots from construction sites
#      and surface car parks split into game-sized plots
#   6. the office's own building, and a 4 m tile grid of plot ids (run-length coded rows)
# v2 over v1: "radius_m" (the block is a disc, not a box), "water", "land" (islands over sea),
# road lines with any number of points, "office_plot", "levels_src", "grid.rle", "stats".
# Pure data: safe to run on a worker thread.

const FORMAT := "tiny-realestate-block"
const VERSION := 2
const FLOOR_M := 3.2
const TILE := 4.0
const DISC_SIDES := 96
# smallest building kept, in m2 (sheds, kiosks and tracing slivers below this are noise)
const MIN_BUILDING := 8.0
const MIN_LEVELS_FOR_MEDIAN := 5
# local height medians are taken per square of this size, so a tower district reads taller than
# the low streets next to it
const MEDIAN_CELL := 200.0
const LOT_MAX := 750.0
const LOT_MIN := 140.0
const ROAD_RX := "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|" \
	+ "living_street|service|pedestrian|road|busway)(_link)?$"
const WIDTH := {
	"motorway": 24.0, "trunk": 22.0, "primary": 20.0, "secondary": 16.0, "tertiary": 13.0,
	"unclassified": 9.0, "residential": 9.0, "living_street": 7.0, "service": 5.0,
	"pedestrian": 7.0, "road": 8.0, "busway": 8.0,
}
const CATS := {
	"apartments": "residential", "residential": "residential", "house": "residential",
	"detached": "residential", "semidetached_house": "residential", "terrace": "residential",
	"dormitory": "residential", "bungalow": "residential", "commercial": "commercial",
	"retail": "commercial", "supermarket": "commercial", "kiosk": "commercial",
	"office": "office", "hotel": "hotel", "industrial": "industrial", "warehouse": "industrial",
	"manufacture": "industrial", "garage": "utility", "garages": "utility", "shed": "utility",
	"roof": "utility", "carport": "utility", "parking": "utility", "service": "utility",
	"transformer_tower": "utility", "construction": "empty",
}
const CIVIC := ["church", "cathedral", "chapel", "mosque", "temple", "shrine", "synagogue",
	"school", "university", "college", "hospital", "public", "civic", "government",
	"train_station", "transportation", "museum", "kindergarten", "fire_station", "stadium",
	"sports_hall", "library", "townhall", "theatre"]
const CIVIC_AMENITY := ["school", "university", "college", "hospital", "townhall", "library",
	"place_of_worship", "theatre", "police", "fire_station", "kindergarten", "museum"]
# floors a building of each kind gets when nothing nearby is tagged either
const DEFAULT_LEVELS := {"residential": 4, "commercial": 3, "office": 6, "hotel": 6,
	"civic": 3, "industrial": 2, "utility": 1}
const LOW_TYPES := ["house", "detached", "semidetached_house", "bungalow", "terrace"]
const GREEN_LEISURE := ["park", "garden", "playground", "pitch", "common", "recreation_ground",
	"dog_park", "nature_reserve", "golf_course"]
const GREEN_LANDUSE := ["grass", "meadow", "forest", "village_green", "recreation_ground",
	"cemetery", "allotments", "orchard", "flowerbed", "plant_nursery"]
const GREEN_NATURAL := ["wood", "scrub", "grassland", "heath"]
const SAND := ["beach", "sand"]
const LOT_LANDUSE := ["construction", "brownfield", "greenfield", "vacant"]


static func query(lat: float, lon: float, radius: float) -> String:
	var a := "(around:%d,%.6f,%.6f)" % [roundi(radius), lat, lon]
	var parts: Array[String] = [
		'way["building"]' + a,
		'relation["building"]["type"="multipolygon"]' + a,
		'way["highway"~"%s"]' % ROAD_RX + a,
		'way["landuse"]' + a,
		'way["leisure"~"^(%s)$"]' % "|".join(GREEN_LEISURE) + a,
		'relation["leisure"~"^(park|garden)$"]' + a,
		'way["natural"~"^(water|wood|scrub|grassland|heath|beach|sand|coastline)$"]' + a,
		'relation["natural"="water"]' + a,
		'way["waterway"="riverbank"]' + a,
		'way["amenity"="parking"]' + a,
	]
	return "[out:json][timeout:90][maxsize:268435456];(" + ";".join(parts) + ";);out geom qt;"


# raw: the parsed Overpass JSON; centre: the office (lat, lon); radius: the max radius in metres
static func bake(raw: Dictionary, lat0: float, lon0: float, radius: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var k := Geo.scale_at(lat0)
	var els: Array = raw.get("elements", [])
	# --- 1. shapes in local metres, before turning -----------------------------------------
	var shapes: Array[Dictionary] = []
	for e: Dictionary in els:
		var tags: Dictionary = e.get("tags", {})
		if tags.is_empty():
			continue
		var lines: Array[PackedVector2Array] = []
		if e["type"] == "way":
			lines = _runs(e.get("geometry", []), lat0, lon0, k)
		elif e["type"] == "relation":
			var outer: Array[PackedVector2Array] = []
			for m: Dictionary in e.get("members", []):
				if m.get("type") == "way" and m.get("role", "outer") in ["outer", ""]:
					outer.append_array(_runs(m.get("geometry", []), lat0, lon0, k))
			lines = Geo.rings(outer)
		else:
			continue
		if not lines.is_empty():
			shapes.append({"id": "%s%d" % [String(e["type"]).left(1), int(e["id"])],
				"tags": tags, "lines": lines})
	# --- 2. dominant street direction -------------------------------------------------------
	var rot := _rotation(shapes)
	var turn := deg_to_rad(rot)
	for s in shapes:
		var lines: Array[PackedVector2Array] = s["lines"]
		for i in lines.size():
			var turned := PackedVector2Array()
			for p in lines[i]:
				turned.append(p.rotated(turn))
			lines[i] = turned
	var disc := Geo.circle(radius, DISC_SIDES)
	# --- 3..5. sort every shape into its layer ----------------------------------------------
	var roads: Array[Dictionary] = []
	var greens: Array[Dictionary] = []
	var water: Array[Dictionary] = []
	var coast: Array[PackedVector2Array] = []
	var lots: Array[Dictionary] = []
	var landuse: Array[Dictionary] = []
	var builds: Array[Dictionary] = []
	for s in shapes:
		var tags: Dictionary = s["tags"]
		var lines: Array[PackedVector2Array] = s["lines"]
		if tags.has("building") and tags["building"] != "no" and not _underground(tags):
			for i in lines.size():
				builds.append({"id": s["id"] if i == 0 else "%s_%d" % [s["id"], i],
					"tags": tags, "poly": lines[i]})
		elif tags.has("highway"):
			if tags.get("area") == "yes" or _underground(tags):
				continue
			for line in lines:
				_add_road(roads, tags, line, disc, radius)
		elif tags.get("natural") == "coastline":
			coast.append_array(lines)
		elif tags.get("natural") == "water" or tags.get("waterway") == "riverbank" \
				or tags.get("landuse") in ["reservoir", "basin"]:
			_add_areas(water, "water", lines, disc)
		elif tags.get("leisure") in GREEN_LEISURE:
			_add_areas(greens, tags["leisure"], lines, disc)
		elif tags.get("landuse") in GREEN_LANDUSE:
			_add_areas(greens, tags["landuse"], lines, disc)
		elif tags.get("natural") in GREEN_NATURAL:
			_add_areas(greens, tags["natural"], lines, disc)
		elif tags.get("natural") in SAND:
			_add_areas(greens, "sand", lines, disc)
		elif tags.get("landuse") in LOT_LANDUSE or (tags.get("amenity") == "parking"
				and tags.get("parking", "surface") == "surface"):
			var kind: String = tags.get("landuse", "parking")
			for line in lines:
				for piece in _clean_clip(line, disc, radius):
					lots.append({"id": s["id"], "kind": kind, "poly": piece})
		elif tags.has("landuse"):
			for line in lines:
				var poly := Geo.weld(line)
				if poly.size() >= 3:
					landuse.append({"kind": tags["landuse"], "poly": poly,
						"box": Geo.bounds(poly)})
	var sea := Geo.sea(coast, disc)
	for poly: PackedVector2Array in sea["water"]:
		water.append({"kind": "sea", "poly": poly})
	var land: Array[Dictionary] = []
	for poly: PackedVector2Array in sea["islands"]:
		for piece in _clean_clip(poly, disc, radius):
			land.append({"kind": "island", "poly": piece})
	# --- 4. plots ---------------------------------------------------------------------------
	var plots := _building_plots(builds, landuse, disc, radius)
	var n_buildings := plots.size()
	for lot in lots:
		var parts: Array[PackedVector2Array] = []
		_split(lot["poly"], lot["id"], 0, parts)
		for i in parts.size():
			var poly: PackedVector2Array = parts[i]
			plots.append({"id": "%s_%d" % [lot["id"], i], "cat": "empty", "osm_type": lot["kind"],
				"levels": 0, "levels_src": "none", "height_m": 0.0, "poly": poly})
	# --- 6. the office's building and the tile grid ------------------------------------------
	var office := _office_plot(plots, n_buildings)
	var grid := _grid(plots, radius)
	var out_plots: Array = []
	for p in plots:
		var poly: PackedVector2Array = p["poly"]
		out_plots.append({"id": p["id"], "cat": p["cat"], "osm_type": p["osm_type"],
			"levels": p["levels"], "levels_src": p["levels_src"],
			"height_m": snappedf(p["height_m"], 0.1), "area_m2": roundi(absf(Geo.area(poly))),
			"poly": _ring(poly), "owned": false, "tier": 0})
	var estimated := 0
	for p in plots:
		if p["levels_src"] == "estimated":
			estimated += 1
	return {
		"format": FORMAT, "format_version": VERSION,
		"source": "OpenStreetMap via Overpass API",
		"attribution": "© OpenStreetMap contributors (ODbL)",
		"center": {"lat": lat0, "lon": lon0}, "rotation_deg": snappedf(rot, 0.01),
		"radius_m": radius, "seed": absi(("%f%f" % [lat0, lon0]).hash()),
		"roads": roads.map(func(r: Dictionary) -> Dictionary:
			return {"name": r["name"], "kind": r["kind"], "width": r["width"],
				"line": _ring(r["line"])}),
		"greens": greens.map(_area_out), "water": water.map(_area_out),
		"land": land.map(_area_out),
		"plots": out_plots, "office_plot": office, "grid": grid,
		"stats": {"elements": els.size(), "buildings": n_buildings,
			"lots": plots.size() - n_buildings, "levels_estimated": estimated,
			"roads": roads.size(), "greens": greens.size(), "water": water.size(),
			"bake_ms": Time.get_ticks_msec() - t0},
	}


# Overpass geometry as metre polylines; a null (a node outside a clipped output) splits a run
static func _runs(geometry: Array, lat0: float, lon0: float, k: Vector2) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var cur := PackedVector2Array()
	for g: Variant in geometry:
		if g is Dictionary:
			cur.append(Geo.to_local(g["lat"], g["lon"], lat0, lon0, k))
		elif cur.size() > 1:
			out.append(cur)
			cur = PackedVector2Array()
		else:
			cur = PackedVector2Array()
	if cur.size() > 1:
		out.append(cur)
	return out


static func _underground(tags: Dictionary) -> bool:
	return tags.get("tunnel", "no") != "no" or tags.get("location") == "underground" \
		or tags.get("covered") == "yes" or int(_number(tags.get("layer", "0"))) < 0


# the most common street direction modulo 90 degrees, weighted by length, as the turn (degrees)
# that lays it along the x axis; the smaller of the two turns that do it, so north stays near up
static func _rotation(shapes: Array[Dictionary]) -> float:
	var hist := PackedFloat32Array()
	hist.resize(90)
	for s in shapes:
		if not s["tags"].has("highway"):
			continue
		for line: PackedVector2Array in s["lines"]:
			for i in range(1, line.size()):
				var d := line[i] - line[i - 1]
				var ang := fposmod(rad_to_deg(atan2(d.y, d.x)), 90.0)
				hist[int(ang) % 90] += d.length()
	var best := 0
	var best_w := -1.0
	for i in 90:
		# a 5-degree window, so a grid drawn a degree or two off still counts as one direction
		var w := 0.0
		for j in range(-2, 3):
			w += hist[(i + j + 90) % 90]
		if w > best_w:
			best_w = w
			best = i
	if best_w <= 0.0:
		return 0.0
	var a := best + 0.5
	return -a if a <= 45.0 else 90.0 - a


static func _add_road(roads: Array[Dictionary], tags: Dictionary, line: PackedVector2Array,
		disc: PackedVector2Array, radius: float) -> void:
	var kind: String = String(tags["highway"]).trim_suffix("_link")
	var width: float = WIDTH.get(kind, 8.0)
	if tags.has("width"):
		var w := _number(tags["width"])
		if w >= 3.0 and w <= 60.0:
			width = w
	if String(tags["highway"]).ends_with("_link"):
		width = minf(width, 10.0)
	var pieces: Array[PackedVector2Array] = []
	if _inside(line, radius):
		pieces.append(line)
	else:
		for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(line, disc):
			pieces.append(piece)
	for piece in pieces:
		var clean := Geo.weld(piece, 0.5)
		if clean.size() >= 2:
			roads.append({"name": tags.get("name", ""), "kind": kind, "width": width,
				"line": clean})


static func _add_areas(into: Array[Dictionary], kind: String, lines: Array[PackedVector2Array],
		disc: PackedVector2Array) -> void:
	var radius := disc[0].x
	for line in lines:
		for piece in _clean_clip(line, disc, radius):
			if absf(Geo.area(piece)) >= 4.0:
				into.append({"kind": kind, "poly": piece})


# a traced ring made drawable, then cut to the disc (untouched when it is fully inside)
static func _clean_clip(line: PackedVector2Array, disc: PackedVector2Array,
		radius: float) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var poly := Geo.repair(line)
	if poly.size() < 3:
		return out
	if _inside(poly, radius):
		out.append(poly)
		return out
	var box := Geo.bounds(poly)
	if box.position.x > radius or box.position.y > radius or box.end.x < -radius \
			or box.end.y < -radius:
		return out
	for piece in Geo.clip(poly, disc):
		if piece.size() >= 3:
			out.append(piece)
	return out


static func _inside(pts: PackedVector2Array, radius: float) -> bool:
	var r2 := radius * radius * 0.995
	for p in pts:
		if p.length_squared() > r2:
			return false
	return true


static func _building_plots(builds: Array[Dictionary], landuse: Array[Dictionary],
		disc: PackedVector2Array, radius: float) -> Array[Dictionary]:
	var plots: Array[Dictionary] = []
	# first the tagged heights, gathered per square for the local medians
	var cells := {}
	var every: Array[int] = []
	for b in builds:
		var lv := _tagged_levels(b["tags"])
		if lv > 0:
			var c := Geo.centre(b["poly"])
			var key := Vector2i(floori(c.x / MEDIAN_CELL), floori(c.y / MEDIAN_CELL))
			if not cells.has(key):
				cells[key] = [] as Array[int]
			cells[key].append(lv)
			every.append(lv)
	var global := _median(every) if every.size() >= MIN_LEVELS_FOR_MEDIAN * 2 else 0
	var medians := {}
	for key: Vector2i in cells:
		var near: Array[int] = []
		# the square and its eight neighbours, so a cell with two tags does not decide alone
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				near.append_array(cells.get(key + Vector2i(dx, dy), [] as Array[int]))
		if near.size() >= MIN_LEVELS_FOR_MEDIAN:
			medians[key] = _median(near)
	for b in builds:
		var tags: Dictionary = b["tags"]
		var pieces := _clean_clip(b["poly"], disc, radius)
		for j in pieces.size():
			var piece := pieces[j]
			var a := absf(Geo.area(piece))
			if a < MIN_BUILDING:
				continue
			# a building the disc edge cuts in two keeps one id per piece
			var id: String = b["id"] if j == 0 else "%s_c%d" % [b["id"], j]
			var type: String = tags["building"]
			var cat := _category(tags, piece, landuse)
			if cat == "empty":
				plots.append({"id": id, "cat": "empty", "osm_type": type, "levels": 0,
					"levels_src": "none", "height_m": 0.0, "poly": piece})
				continue
			var levels := _tagged_levels(tags)
			var src := "osm"
			var height := _height(tags)
			if levels <= 0:
				src = "estimated"
				var c := Geo.centre(piece)
				var key := Vector2i(floori(c.x / MEDIAN_CELL), floori(c.y / MEDIAN_CELL))
				var base: int = medians.get(key, global)
				if base <= 0:
					base = DEFAULT_LEVELS.get(cat, 4)
				# a stable wobble of one floor either way, so a street is not a flat wall
				levels = base + int(_h01(id + "lv") * 3.0) - 1
				if type in LOW_TYPES:
					levels = mini(levels, 2)
				if cat == "utility":
					levels = 1
				# a tiny footprint is never a tower
				if a < 60.0:
					levels = mini(levels, 3)
				levels = clampi(levels, 1, 60)
			if height <= 0.0:
				height = levels * FLOOR_M + 1.0
			elif src == "estimated":
				src = "osm"
				levels = clampi(roundi(height / FLOOR_M), 1, 150)
			plots.append({"id": id, "cat": cat, "osm_type": type, "levels": levels,
				"levels_src": src, "height_m": height, "poly": piece})
	return plots


static func _tagged_levels(tags: Dictionary) -> int:
	if tags.has("building:levels"):
		var lv := _number(tags["building:levels"])
		if lv >= 1.0:
			return clampi(roundi(lv), 1, 150)
	if tags.has("height"):
		var h := _height(tags)
		if h > 0.0:
			return clampi(roundi(h / FLOOR_M), 1, 150)
	return 0


static func _height(tags: Dictionary) -> float:
	if not tags.has("height"):
		return 0.0
	var raw: String = tags["height"]
	var h := _number(raw)
	if raw.contains("'") or raw.contains("ft"):
		h *= 0.3048
	return h if h >= 2.0 and h <= 900.0 else 0.0


# the first number in a tag value ("5", "4.5", "5;6", "12 m"); 0 when there is none
static func _number(value: Variant) -> float:
	var s := str(value).strip_edges().replace(",", ".")
	var digits := ""
	for ch in s:
		if (ch >= "0" and ch <= "9") or (ch == "." and not digits.contains(".")) \
				or (ch == "-" and digits == ""):
			digits += ch
		elif digits != "":
			break
	return digits.to_float() if digits.is_valid_float() else 0.0


static func _category(tags: Dictionary, poly: PackedVector2Array, landuse: Array[Dictionary]) -> String:
	var type: String = tags["building"]
	if CATS.has(type):
		return CATS[type]
	if type in CIVIC or tags.get("amenity") in CIVIC_AMENITY:
		return "civic"
	if tags.get("tourism") in ["hotel", "hostel"]:
		return "hotel"
	if tags.has("office"):
		return "office"
	if tags.has("shop"):
		return "commercial"
	# a plain building=yes takes its kind from the land use it stands in
	var c := Geo.centre(poly)
	for lu in landuse:
		var box: Rect2 = lu["box"]
		if box.has_point(c) and Geometry2D.is_point_in_polygon(c, lu["poly"]):
			match lu["kind"]:
				"retail", "commercial":
					return "commercial"
				"industrial", "railway":
					return "industrial"
	return "residential"


# recursive split of an empty lot into game-sized plots, cutting the longer side near the middle
# (the prototype's oriented-box split; the streets are already axis-aligned here)
static func _split(poly: PackedVector2Array, seed: String, depth: int,
		out: Array[PackedVector2Array]) -> void:
	var a := absf(Geo.area(poly))
	if a <= LOT_MAX or depth > 8:
		if a >= LOT_MIN * 0.5:
			out.append(poly)
		return
	var box := Geo.bounds(poly)
	var t := 0.5 + (_h01(seed + str(depth)) - 0.5) * 0.3
	var halves: Array[Rect2] = []
	if box.size.x >= box.size.y:
		var cut := box.position.x + box.size.x * t
		halves = [Rect2(box.position, Vector2(cut - box.position.x, box.size.y)),
			Rect2(Vector2(cut, box.position.y), Vector2(box.end.x - cut, box.size.y))]
	else:
		var cut := box.position.y + box.size.y * t
		halves = [Rect2(box.position, Vector2(box.size.x, cut - box.position.y)),
			Rect2(Vector2(box.position.x, cut), Vector2(box.size.x, box.end.y - cut))]
	for i in 2:
		var r := halves[i].grow(0.01)
		var rect := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
			Vector2(r.position.x, r.end.y)])
		for part in Geo.clip(poly, rect):
			if absf(Geo.area(part)) > 1.0:
				_split(part, "%s.%d" % [seed, i], depth + 1, out)


# the building the office moves into: the one under the clicked point, else the nearest one
static func _office_plot(plots: Array[Dictionary], n_buildings: int) -> String:
	var best := ""
	var best_d := 45.0
	for i in n_buildings:
		var p: Dictionary = plots[i]
		if p["cat"] == "empty":
			continue
		var poly: PackedVector2Array = p["poly"]
		if Geometry2D.is_point_in_polygon(Vector2.ZERO, poly):
			return p["id"]
		var d := Geo.centre(poly).length()
		if d < best_d and absf(Geo.area(poly)) >= 40.0:
			best_d = d
			best = p["id"]
	return best


# which plot each 4 m tile belongs to (0 = street or open ground); rows are run-length coded as
# "id*count" tokens, since most of a row is long runs
static func _grid(plots: Array[Dictionary], radius: float) -> Dictionary:
	var n := ceili(radius * 2.0 / TILE)
	var origin := Vector2(-radius, -radius)
	var cells := PackedInt32Array()
	cells.resize(n * n)
	for i in plots.size():
		var poly: PackedVector2Array = plots[i]["poly"]
		var box := Geo.bounds(poly)
		var x0 := maxi(0, floori((box.position.x - origin.x) / TILE))
		var x1 := mini(n - 1, floori((box.end.x - origin.x) / TILE))
		var y0 := maxi(0, floori((box.position.y - origin.y) / TILE))
		var y1 := mini(n - 1, floori((box.end.y - origin.y) / TILE))
		for gy in range(y0, y1 + 1):
			for gx in range(x0, x1 + 1):
				var c := origin + Vector2(gx + 0.5, gy + 0.5) * TILE
				if Geometry2D.is_point_in_polygon(c, poly):
					cells[gy * n + gx] = i + 1
	var rows: Array[String] = []
	for gy in n:
		var tokens: Array[String] = []
		var gx := 0
		while gx < n:
			var v := cells[gy * n + gx]
			var run := 1
			while gx + run < n and cells[gy * n + gx + run] == v:
				run += 1
			tokens.append(str(v) if run == 1 else "%d*%d" % [v, run])
			gx += run
		rows.append(",".join(tokens))
	return {"tile_m": TILE, "origin": [origin.x, origin.y], "w": n, "h": n, "rle": true,
		"cells": rows}


static func _median(values: Array[int]) -> int:
	var s := values.duplicate()
	s.sort()
	return s[s.size() / 2]


static func _ring(poly: PackedVector2Array) -> Array:
	var out := []
	for p in poly:
		out.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	return out


static func _area_out(a: Dictionary) -> Dictionary:
	return {"kind": a["kind"], "poly": _ring(a["poly"])}


# a stable 0..1 hash, so the same building always gets the same estimated height
static func _h01(key: String) -> float:
	return float(key.hash() & 0xFFFF) / 65536.0
