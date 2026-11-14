class_name BlockBaker
extends RefCounted

# Turns one raw Overpass answer (the streets and land around an office, within its max radius)
# into the saved area BlockView draws: format "tiny-realestate-block" v3. No real buildings are
# used: the player builds; the map only lends the streets, their names and the parks and water.
#   1. lat/lon -> local metres around the office (x east, y north)
#   2. find the dominant street direction and turn everything so streets follow the iso axes
#   3. roads (centre line, width from the tag or the class), railways, water, sea, greens
#   4. BLOCKS: polygonize the street network (StreetGraph), cut each face back by half its
#      streets' widths plus pavement, and take parks, water and rail land out of it
#   5. LOTS ("terrenos", saved as plots[]): each block is one lot, or a few when it is big, cut
#      straight across (Plotter.split) so every lot still faces a street; a lot knows the
#      streets it faces (its address, the sides that face them) and its zone (from landuse); a
#      share is pre-built by zone, so the area does not start barren, with a development of a
#      tier drawn by AreaBuilder (never real footprints); slivers become little gardens
#   6. the office's lot: the one under the clicked point, else the nearest
# Saved v2 areas (one small plot per building) are re-parcelled into lots by upgrade().
# Pure data: safe to run on a worker thread.

const FORMAT := "tiny-realestate-block"
const VERSION := 3
const FLOOR_M := 3.2
const DISC_SIDES := 96
# kerb to building line, added to half the street width when blocks are cut back
const PAVEMENT := 3.0
const MIN_FACE := 150.0
const MIN_BLOCK := 120.0
const CUT_CELL := 40.0
# a lot side faces a street when it lies within half the street's width plus the pavement plus
# this (m) of the centre line (blocks are cut back exactly that far, give or take simplifying)
const FRONT_TOL := 3.0
# a block smaller than this (m2), or thinner on average than GARDEN_WIDTH (m), or facing no
# street, is no lot: it becomes a little garden
const GARDEN_AREA := 260.0
const GARDEN_WIDTH := 7.0
const ROAD_RX := "^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|" \
	+ "living_street|pedestrian|road|busway)(_link)?$"
const RAIL_RX := "^(rail|light_rail|narrow_gauge|subway|tram|monorail)$"
const LANDUSE_RX := "^(residential|commercial|retail|industrial|railway|grass|meadow|forest|" \
	+ "village_green|recreation_ground|cemetery|allotments|orchard|construction|reservoir|basin)$"
const WIDTH := {
	"motorway": 24.0, "trunk": 22.0, "primary": 20.0, "secondary": 16.0, "tertiary": 13.0,
	"unclassified": 9.0, "residential": 9.0, "living_street": 7.0, "pedestrian": 7.0,
	"road": 8.0, "busway": 8.0,
}
const MAJOR := ["motorway", "trunk", "primary", "secondary", "tertiary"]
# a rail line cuts the blocks like a street this wide
const RAIL_WIDTH := 9.0
const GREEN_LEISURE := ["park", "garden", "playground", "pitch", "common", "recreation_ground",
	"dog_park", "nature_reserve", "golf_course"]
const GREEN_LANDUSE := ["grass", "meadow", "forest", "village_green", "recreation_ground",
	"cemetery", "allotments", "orchard"]
const GREEN_NATURAL := ["wood", "scrub", "grassland", "heath"]
const SAND := ["beach", "sand"]
const ZONES := {"residential": "residential", "commercial": "commercial", "retail": "commercial",
	"industrial": "industrial"}
# share of lots that start built, by zone, and how much a block may differ from it
const BUILT := {"residential": 0.62, "commercial": 0.7, "industrial": 0.45}
const BUILT_SPREAD := 0.3
# tiers from docs/DESIGN.md: 0 solar, 1 casa, 2 urbanizacion, 3 bloque, 4 torre, 5 rascacielos
const TIER_LEVELS := [Vector2i(0, 0), Vector2i(1, 2), Vector2i(2, 3), Vector2i(4, 7),
	Vector2i(9, 15), Vector2i(20, 35)]


static func query(lat: float, lon: float, radius: float) -> String:
	var a := "(around:%d,%.6f,%.6f)" % [roundi(radius), lat, lon]
	var parts: Array[String] = [
		'way["highway"~"%s"]' % ROAD_RX + a,
		'way["railway"~"%s"]' % RAIL_RX + a,
		'way["landuse"~"%s"]' % LANDUSE_RX + a,
		'way["leisure"~"^(%s)$"]' % "|".join(GREEN_LEISURE) + a,
		'relation["leisure"~"^(park|garden)$"]' + a,
		'way["natural"~"^(water|wood|scrub|grassland|heath|beach|sand|coastline)$"]' + a,
		'relation["natural"="water"]' + a,
		'way["waterway"="riverbank"]' + a,
	]
	return Overpass.compose("[out:json][timeout:90][maxsize:268435456];", parts)


# raw: the parsed Overpass JSON; (lat0, lon0): the office; radius: the max radius in metres
static func bake(raw: Dictionary, lat0: float, lon0: float, radius: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var k := Geo.scale_at(lat0)
	var els: Array = raw.get("elements", [])
	# --- 1. shapes in local metres ----------------------------------------------------------
	var shapes: Array[Dictionary] = []
	for e: Dictionary in els:
		var tags: Dictionary = e.get("tags", {})
		if tags.is_empty() or tags.has("building"):
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
	var wide := Geo.circle(radius + 4.0, DISC_SIDES)
	# --- 3. layers --------------------------------------------------------------------------
	var roads: Array[Dictionary] = []
	var rails: Array[Dictionary] = []
	var greens: Array[Dictionary] = []
	var water: Array[Dictionary] = []
	var coast: Array[PackedVector2Array] = []
	var zones: Array[Dictionary] = []
	var blocked: Array[PackedVector2Array] = []
	var graph := StreetGraph.new()
	for s in shapes:
		var tags: Dictionary = s["tags"]
		var lines: Array[PackedVector2Array] = s["lines"]
		if tags.has("highway"):
			if tags.get("area") == "yes" or _underground(tags):
				continue
			for line in lines:
				_add_road(roads, graph, tags, line, disc, wide, radius)
		elif tags.has("railway"):
			if _underground(tags):
				continue
			var kind: String = tags["railway"]
			for line in lines:
				for piece in _cut_line(line, disc, radius):
					rails.append({"kind": kind, "line": piece})
				# trams run in the street; the other lines fence off their own corridor
				if kind != "tram":
					for piece in _cut_line(line, wide, radius + 4.0):
						graph.add_line(piece, RAIL_WIDTH)
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
		elif tags.get("landuse") == "railway":
			for line in lines:
				var poly := Geo.repair(line)
				if poly.size() >= 3:
					blocked.append(poly)
		elif ZONES.has(tags.get("landuse", "")):
			for line in lines:
				var poly := Geo.repair(line)
				if poly.size() >= 3:
					zones.append({"zone": ZONES[tags["landuse"]], "poly": poly,
						"box": Geo.bounds(poly)})
	var sea := Geo.sea(coast, disc)
	for poly: PackedVector2Array in sea["water"]:
		poly = _tidy(poly)
		if not poly.is_empty():
			water.append({"kind": "sea", "poly": poly})
	var land: Array[Dictionary] = []
	for poly: PackedVector2Array in sea["islands"]:
		for piece in _clean_clip(poly, disc, radius):
			land.append({"kind": "island", "poly": piece})
	# the disc edge closes the blocks the circle cuts through
	var edge := disc.duplicate()
	edge.append(disc[0])
	graph.add_line(edge, 0.0)
	var t_graph := Time.get_ticks_msec()
	var faces := graph.faces(MIN_FACE)
	t_graph = Time.get_ticks_msec() - t_graph
	# --- 4. blocks --------------------------------------------------------------------------
	var off_limits: Array[PackedVector2Array] = blocked.duplicate()
	for g in greens:
		off_limits.append(g["poly"])
	for w in water:
		off_limits.append(w["poly"])
	var cutters := _cutter_index(roads, rails)
	var blocks: Array[Dictionary] = []
	for face in faces:
		for part in _block_parts(face, faces, cutters, off_limits):
			part = _tidy(part)
			if part.is_empty():
				continue
			blocks.append({"id": "b%d" % blocks.size(), "poly": part,
				"zone": _zone(part, zones)})
	# --- 5. lots ----------------------------------------------------------------------------
	var parcel := parcel(blocks, roads, radius, "%.4f%.4f" % [lat0, lon0])
	var plots: Array[Dictionary] = parcel["lots"]
	var courts: Array[Dictionary] = parcel["courts"]
	var office: int = parcel["office"]
	var built: int = parcel["built"]
	return {
		"format": FORMAT, "format_version": VERSION,
		"source": "OpenStreetMap via Overpass API (streets, land use, parks, water)",
		"attribution": "© OpenStreetMap contributors (ODbL)",
		"center": {"lat": lat0, "lon": lon0}, "rotation_deg": snappedf(rot, 0.01),
		"radius_m": radius, "seed": absi(("%f%f" % [lat0, lon0]).hash()),
		"roads": roads.map(_road_out),
		"rails": rails.map(func(r: Dictionary) -> Dictionary:
			return {"kind": r["kind"], "line": _ring(r["line"])}),
		"greens": greens.map(_area_out), "courts": courts.map(_area_out),
		"water": water.map(_area_out), "land": land.map(_area_out),
		"blocks": blocks.map(func(b: Dictionary) -> Dictionary:
			return {"id": b["id"], "zone": b["zone"], "poly": _ring(b["poly"])}),
		"plots": plots.map(_lot_out),
		"office_plot": plots[office]["id"] if office >= 0 else "",
		"stats": {"elements": els.size(), "roads": roads.size(), "rails": rails.size(),
			"faces": faces.size(), "blocks": blocks.size(), "plots": plots.size(),
			"lots": plots.size(), "built": built, "greens": greens.size(),
			"water": water.size(),
			"graph_ms": t_graph, "bake_ms": Time.get_ticks_msec() - t0},
	}


# Overpass geometry as metre polylines; a null (a node outside a clipped output) splits a run
static func _runs(geometry: Array, lat0: float, lon0: float,
		k: Vector2) -> Array[PackedVector2Array]:
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
		or tags.get("covered") == "yes" or tags.get("railway") == "subway" \
		or _number(tags.get("layer", "0")) < 0.0


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


static func _add_road(roads: Array[Dictionary], graph: StreetGraph, tags: Dictionary,
		line: PackedVector2Array, disc: PackedVector2Array, wide: PackedVector2Array,
		radius: float) -> void:
	var raw_kind: String = tags["highway"]
	var kind := raw_kind.trim_suffix("_link")
	var width: float = WIDTH.get(kind, 8.0)
	if tags.has("width"):
		var w := _number(tags["width"])
		if w >= 3.0 and w <= 60.0:
			width = w
	if raw_kind.ends_with("_link"):
		width = minf(width, 10.0)
	# a name the Latin font can draw (Tokyo's local names are Japanese), else none
	var name := CityBaker.pick_name(tags)
	var ref: String = tags.get("ref", "")
	if not CityBaker.is_latin(ref):
		ref = ""
	# one-way streets (Traffic drives them one way): 1 along the line, -1 against it
	var ow: String = tags.get("oneway", "")
	var oneway := 0
	if ow in ["yes", "true", "1"] or tags.get("junction", "") in ["roundabout", "circular"] \
			or (raw_kind in ["motorway", "motorway_link"] and ow != "no"):
		oneway = 1
	elif ow in ["-1", "reverse"]:
		oneway = -1
	for piece in _cut_line(line, disc, radius):
		var road := {"name": name, "ref": ref, "kind": kind, "width": width, "line": piece,
			"major": kind in MAJOR}
		if oneway != 0:
			road["oneway"] = oneway if _same_way(piece, line) else -oneway
		roads.append(road)
	# an expressway on a viaduct passes over the blocks instead of bounding them
	var raised: bool = (tags.get("bridge", "no") != "no" or _number(tags.get("layer", "0")) > 0.0) \
		and kind in ["motorway", "trunk"]
	if not raised:
		for piece in _cut_line(line, wide, radius + 4.0):
			graph.add_line(piece, width)


# whether a piece cut out of a line still runs the line's way (clipping may turn it round)
static func _same_way(piece: PackedVector2Array, line: PackedVector2Array) -> bool:
	var m := (piece[0] + piece[1]) * 0.5
	var best := INF
	var along := Vector2.ZERO
	for i in line.size() - 1:
		var q := Geometry2D.get_closest_point_to_segment(m, line[i], line[i + 1])
		if q.distance_to(m) < best:
			best = q.distance_to(m)
			along = line[i + 1] - line[i]
	return (piece[1] - piece[0]).dot(along) >= 0.0


static func _cut_line(line: PackedVector2Array, shape: PackedVector2Array,
		radius: float) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var pieces: Array = [line] if _inside(line, radius) \
		else Geometry2D.intersect_polyline_with_polygon(line, shape)
	for piece: PackedVector2Array in pieces:
		var clean := Geo.weld(piece, 0.5)
		if clean.size() >= 2:
			out.append(clean)
	return out


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
		if Geo.area(poly) < 0.0:
			poly.reverse()
		poly = _tidy(poly)
		if not poly.is_empty():
			out.append(poly)
		return out
	var box := Geo.bounds(poly)
	if box.position.x > radius or box.position.y > radius or box.end.x < -radius \
			or box.end.y < -radius:
		return out
	for piece in Geo.clip(poly, disc):
		piece = _tidy(piece)
		if not piece.is_empty():
			out.append(piece)
	return out


static func _inside(pts: PackedVector2Array, radius: float) -> bool:
	var r2 := radius * radius * 0.995
	for p in pts:
		if p.length_squared() > r2:
			return false
	return true


# a face of the street graph cut back by half of each street's width plus the pavement (every
# street near it, so dead ends bite into the block too), without the faces lying inside it (a
# face around a network the rest does not touch would otherwise cover it), and with parks,
# water and rail land taken out
static func _block_parts(face: Dictionary, faces: Array[Dictionary], cutters: Dictionary,
		off_limits: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var ring: PackedVector2Array = face["poly"]
	var box := Geo.bounds(ring)
	var area := Geo.area(ring)
	var cuts: Array[PackedVector2Array] = []
	for other in faces:
		var poly: PackedVector2Array = other["poly"]
		if other != face and Geo.area(poly) < area and box.encloses(Geo.bounds(poly)) \
				and Geometry2D.is_point_in_polygon(Geo.centre(poly), ring):
			cuts.append(poly)
	var seen := {}
	var c0 := Vector2i(floori(box.position.x / CUT_CELL), floori(box.position.y / CUT_CELL))
	var c1 := Vector2i(floori(box.end.x / CUT_CELL), floori(box.end.y / CUT_CELL))
	for cx in range(c0.x - 1, c1.x + 2):
		for cy in range(c0.y - 1, c1.y + 2):
			for seg: Array in cutters.get(Vector2i(cx, cy), []):
				var key: int = seg[3]
				if seen.has(key):
					continue
				seen[key] = true
				var band := Geometry2D.offset_polyline(PackedVector2Array([seg[0], seg[1]]),
					seg[2] + PAVEMENT, Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND)
				if not band.is_empty() and Geo.bounds(band[0]).intersects(box):
					cuts.append(band[0])
	for hole in off_limits:
		if Geo.bounds(hole).intersects(box):
			cuts.append(hole)
	var parts: Array[PackedVector2Array] = [ring]
	for cut in cuts:
		var cut_box := Geo.bounds(cut)
		var next: Array[PackedVector2Array] = []
		for part in parts:
			if Geo.bounds(part).intersects(cut_box):
				next.append_array(Geo.cut_out(part, cut))
			else:
				next.append(part)
		parts = next
	var out: Array[PackedVector2Array] = []
	for part in parts:
		var clean := Geo.repair(part)
		if clean.size() >= 3 and absf(Geo.area(clean)) >= MIN_BLOCK:
			out.append(clean)
	return out


# every street and rail segment, with half its width, in CUT_CELL cells, for cutting blocks
static func _cutter_index(roads: Array[Dictionary], rails: Array[Dictionary]) -> Dictionary:
	var cells := {}
	var n := 0
	var lines: Array = []
	for r in roads:
		lines.append([r["line"], float(r["width"]) * 0.5])
	for r in rails:
		if r["kind"] != "tram":
			lines.append([r["line"], RAIL_WIDTH * 0.5])
	for item: Array in lines:
		var line: PackedVector2Array = item[0]
		for i in range(1, line.size()):
			var seg := [line[i - 1], line[i], item[1], n]
			n += 1
			var steps := maxi(1, ceili(line[i - 1].distance_to(line[i]) / (CUT_CELL * 0.5)))
			var seen := {}
			for s in steps + 1:
				var p := line[i - 1].lerp(line[i], float(s) / steps)
				var c := Vector2i(floori(p.x / CUT_CELL), floori(p.y / CUT_CELL))
				if seen.has(c):
					continue
				seen[c] = true
				if not cells.has(c):
					cells[c] = []
				cells[c].append(seg)
	return cells


# the zone of the land use under the block's middle; plain city when nothing is mapped
static func _zone(poly: PackedVector2Array, zones: Array[Dictionary]) -> String:
	var c := Geo.centre(poly)
	for z in zones:
		var box: Rect2 = z["box"]
		if box.has_point(c) and Geometry2D.is_point_in_polygon(c, z["poly"]):
			return z["zone"]
	return "residential"


# street segments in 50 m cells, for finding the streets in front of each lot
static func _road_index(roads: Array[Dictionary]) -> Dictionary:
	var cells := {}
	for r in roads:
		var line: PackedVector2Array = r["line"]
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			var n := maxi(1, ceili(a.distance_to(b) / 25.0))
			var seen := {}
			for s in n + 1:
				var p := a.lerp(b, float(s) / n)
				var c := Vector2i(floori(p.x / 50.0), floori(p.y / 50.0))
				if seen.has(c):
					continue
				seen[c] = true
				if not cells.has(c):
					cells[c] = []
				cells[c].append([a, b, r])
	return cells


# blocks -> lots and gardens, shared by bake() and upgrade(); blocks as {id, zone, poly} and
# roads as {name, ref, kind, width, line, major} in local metres; `key` seeds the hashes
static func parcel(blocks: Array[Dictionary], roads: Array[Dictionary], radius: float,
		key: String) -> Dictionary:
	var names := _road_index(roads)
	var lots: Array[Dictionary] = []
	var courts: Array[Dictionary] = []
	var fronts := func(poly: PackedVector2Array) -> Dictionary:
		return _frontage(poly, names, radius)
	for b in blocks:
		var zone: String = b["zone"]
		var bid: String = b["id"]
		var poly: PackedVector2Array = b["poly"]
		var area := absf(Geo.area(poly))
		if area < GARDEN_AREA or 2.0 * area / _perimeter(poly) < GARDEN_WIDTH \
				or float(fronts.call(Plotter.ring_of(poly))["length"]) < Plotter.FRONT_MIN * 0.6:
			courts.append({"kind": "garden", "poly": poly})
			continue
		var density: float = BUILT[zone] + (_h01(bid + "dens") - 0.5) * BUILT_SPREAD
		for piece in Plotter.split(poly, bid + key, fronts):
			var lot := _tidy(piece)
			if lot.is_empty():
				continue
			if Geo.area(lot) < 0.0:
				lot.reverse()
			var face := _frontage(lot, names, radius)
			var id := "%s_%d" % [bid, lots.size()]
			var tier := _start_tier(id, zone, density, face["major"])
			var lv: Vector2i = TIER_LEVELS[tier]
			var streets: Array = face["streets"]
			lots.append({"id": id, "block": bid, "poly": lot,
				"street": streets[0] if not streets.is_empty() else "", "streets": streets,
				"corner": face["corner"], "fronts": face["fronts"], "zone": zone,
				"front_m": snappedf(face["length"], 0.1), "area_m2": roundi(absf(Geo.area(lot))),
				"built_tier": tier, "levels": lv.x + int(_h01(id + "lv") * (lv.y - lv.x + 1)),
				"owned": false})
	var office := _office_plot(lots)
	if office >= 0:
		lots[office]["built_tier"] = 3
		lots[office]["levels"] = maxi(5, int(lots[office]["levels"]))
	var built := 0
	for p in lots:
		if int(p["built_tier"]) > 0:
			built += 1
	return {"lots": lots, "courts": courts, "office": office, "built": built}


# which sides of a lot face a street: {"fronts": side indices, "length": metres of street front,
# "streets": names by frontage (most first), "corner": faces streets at an angle, "major": faces
# a main street, "dir": the way its longest street side runs}; a side on the disc's rim, a park
# or a rail line faces none
static func _frontage(poly: PackedVector2Array, cells: Dictionary, radius: float) -> Dictionary:
	var fronts: Array = []
	var by_name := {}
	var length := 0.0
	var major := false
	var dirs: Array[Vector2] = []
	var longest := 0.0
	var dir := Vector2.ZERO
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var side := a.distance_to(b)
		if side < 1.0 or (a.length() > radius - 2.0 and b.length() > radius - 2.0):
			continue
		# the middle and one more of three points along the side must be at a kerb
		var road := _street_at(a.lerp(b, 0.5), cells)
		if road.is_empty() or (_street_at(a.lerp(b, 0.2), cells).is_empty()
				and _street_at(a.lerp(b, 0.8), cells).is_empty()):
			continue
		fronts.append(i)
		length += side
		dirs.append((b - a) / side)
		if side > longest:
			longest = side
			dir = (b - a) / side
		major = major or road["major"]
		var name: String = road["name"] if road["name"] != "" else road["ref"]
		if name != "":
			by_name[name] = float(by_name.get(name, 0.0)) + side
	var streets: Array = by_name.keys()
	streets.sort_custom(func(p: String, q: String) -> bool: return by_name[p] > by_name[q])
	var corner := false
	for x in dirs.size():
		for y in range(x + 1, dirs.size()):
			if absf(dirs[x].dot(dirs[y])) < 0.7:
				corner = true
	return {"fronts": fronts, "length": length, "streets": streets, "corner": corner,
		"major": major, "dir": dir}


# the street whose kerb runs past this point, {} when none
static func _street_at(p: Vector2, cells: Dictionary) -> Dictionary:
	var c := Vector2i(floori(p.x / 50.0), floori(p.y / 50.0))
	var best := {}
	var best_d := INF
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for seg: Array in cells.get(c + Vector2i(dx, dy), []):
				var r: Dictionary = seg[2]
				var d := Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1]).distance_to(p) \
					- float(r["width"]) * 0.5
				if d < best_d:
					best_d = d
					best = r
	if best_d > PAVEMENT + FRONT_TOL:
		return {}
	return best


static func _perimeter(poly: PackedVector2Array) -> float:
	var sum := 0.0
	for i in poly.size():
		sum += poly[i].distance_to(poly[(i + 1) % poly.size()])
	return maxf(sum, 0.001)


# which lots start built, and how big: denser where the zone is busier and on main streets
static func _start_tier(id: String, zone: String, density: float, major: bool) -> int:
	var chance := density + (0.15 if major else 0.0)
	if _h01(id + "built") >= chance:
		return 0
	var roll := _h01(id + "tier")
	match zone:
		"industrial":
			return 1
		"commercial":
			return 4 if roll < 0.2 else 3
	if major:
		return 4 if roll < 0.12 else 3
	if roll < 0.3:
		return 1
	return 2 if roll < 0.45 else 3


# the lot under the clicked point, else the one whose edge is nearest, within 80 m; -1 when
# there is none
static func _office_plot(plots: Array[Dictionary]) -> int:
	var best := -1
	var best_d := 80.0
	for i in plots.size():
		var poly: PackedVector2Array = plots[i]["poly"]
		if Geometry2D.is_point_in_polygon(Vector2.ZERO, poly):
			return i
		for k in poly.size():
			var d := Geometry2D.get_closest_point_to_segment(Vector2.ZERO, poly[k],
				poly[(k + 1) % poly.size()]).length()
			if d < best_d:
				best_d = d
				best = i
	return best


# a saved v2 area (small plots along every frontage) re-parcelled into v3 lots in place: v2 kept
# the blocks and the roads, which is all the lots need; the rest of the file stays as it was
static func upgrade(old: Dictionary) -> Dictionary:
	var blocks: Array[Dictionary] = []
	for b: Dictionary in old.get("blocks", []):
		blocks.append({"id": b["id"], "zone": b.get("zone", "residential"),
			"poly": _pts(b["poly"])})
	var roads: Array[Dictionary] = []
	for r: Dictionary in old.get("roads", []):
		roads.append({"name": r.get("name", ""), "ref": r.get("ref", ""), "kind": r["kind"],
			"width": float(r["width"]), "line": _pts(r["line"]), "major": r["kind"] in MAJOR})
	var c: Dictionary = old.get("center", {"lat": 0.0, "lon": 0.0})
	var parcel := parcel(blocks, roads, float(old["radius_m"]),
		"%.4f%.4f" % [float(c["lat"]), float(c["lon"])])
	var lots: Array[Dictionary] = parcel["lots"]
	var out := old.duplicate()
	out["format_version"] = VERSION
	out["upgraded_from"] = int(old.get("format_version", 0))
	out["plots"] = lots.map(_lot_out)
	out["courts"] = (parcel["courts"] as Array[Dictionary]).map(_area_out)
	out["office_plot"] = lots[parcel["office"]]["id"] if int(parcel["office"]) >= 0 else ""
	var st: Dictionary = old.get("stats", {}).duplicate()
	st["plots"] = lots.size()
	st["lots"] = lots.size()
	st["built"] = parcel["built"]
	out["stats"] = st
	return out


static func _road_out(r: Dictionary) -> Dictionary:
	var out := {"name": r["name"], "ref": r["ref"], "kind": r["kind"], "width": r["width"],
		"line": _ring(r["line"])}
	if r.has("oneway"):
		out["oneway"] = r["oneway"]
	return out


static func _lot_out(p: Dictionary) -> Dictionary:
	var out := p.duplicate()
	out["poly"] = _ring(p["poly"])
	return out


static func _pts(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in raw:
		out.append(Vector2(q[0], q[1]))
	return out


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


# snapped to the 10 cm the file keeps, then made drawable again (snapping can fold a sliver);
# empty when nothing drawable is left
static func _tidy(poly: PackedVector2Array) -> PackedVector2Array:
	var out := poly
	# a repair can hand back off-grid points, so snap and check again, a couple of times at most
	for _try in 3:
		var snapped := PackedVector2Array()
		for p in out:
			# rounded in double precision exactly as the file will hold it, then stored back in
			# float32 as a load would: one ulp is enough to turn a sliver inside out
			snapped.append(Vector2(snappedf(p.x, 0.1), snappedf(p.y, 0.1)))
		snapped = Geo.weld(snapped)
		if snapped.size() >= 3 and not Geometry2D.triangulate_polygon(snapped).is_empty():
			return snapped if absf(Geo.area(snapped)) >= 1.0 else PackedVector2Array()
		out = Geo.repair(snapped)
		if out.size() < 3:
			break
	return PackedVector2Array()


static func _ring(poly: PackedVector2Array) -> Array:
	var out := []
	for p in poly:
		out.append([snappedf(p.x, 0.1), snappedf(p.y, 0.1)])
	return out


static func _area_out(a: Dictionary) -> Dictionary:
	return {"kind": a["kind"], "poly": _ring(a["poly"])}


static func _h01(key: String) -> float:
	return float(key.hash() & 0xFFFF) / 65536.0
