class_name CityBaker
extends RefCounted

# Turns the raw Overpass answer for a city box into the small city map the player places offices
# on: main roads, sea (from coastlines), lakes and rivers, big parks and neighbourhood names.
# North stays up here (no turning: this is a map, not the isometric block). Format
# "tiny-realtor-city" v1, coordinates in metres from the city centre, x east, y north.
# Pure data: safe to run on a worker thread.

const FORMAT := "tiny-realtor-city"
const VERSION := 1
# half the side of the city box in metres; 8 km fits a downtown and its districts
const HALF := 4000.0
const ROAD_TOL := 5.0
const AREA_TOL := 8.0
# parks smaller than this vanish at map scale (and Tokyo has thousands of pocket parks)
const MIN_PARK := 15000.0
const MIN_WATER := 3000.0
const PLACE_RANK := {"borough": 0, "suburb": 1, "quarter": 2, "neighbourhood": 3}


static func query(lat: float, lon: float) -> String:
	var k := Geo.scale_at(lat)
	var b := "(%.5f,%.5f,%.5f,%.5f)" % [lat - HALF / k.y, lon - HALF / k.x, lat + HALF / k.y,
		lon + HALF / k.x]
	var parts: Array[String] = [
		'way["highway"~"^(motorway|trunk|primary|secondary)$"]' + b,
		'node["place"~"^(borough|suburb|quarter|neighbourhood)$"]' + b,
		'way["natural"="coastline"]' + b,
		'way["natural"="water"]' + b,
		'relation["natural"="water"]' + b,
		'way["waterway"="riverbank"]' + b,
		'way["waterway"="river"]' + b,
		'way["leisure"="park"]' + b,
	]
	return Overpass.compose("[out:json][timeout:120][maxsize:268435456];", parts)


static func bake(raw: Dictionary, lat0: float, lon0: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var k := Geo.scale_at(lat0)
	var box := PackedVector2Array([Vector2(-HALF, -HALF), Vector2(HALF, -HALF),
		Vector2(HALF, HALF), Vector2(-HALF, HALF)])
	var roads: Array = []
	var water: Array = []
	var rivers: Array = []
	var parks: Array = []
	var places: Array[Dictionary] = []
	var coast: Array[PackedVector2Array] = []
	var els: Array = raw.get("elements", [])
	for e: Dictionary in els:
		var tags: Dictionary = e.get("tags", {})
		if e["type"] == "node":
			var name := pick_name(tags)
			if name != "" and PLACE_RANK.has(tags.get("place")):
				var p := Geo.to_local(e["lat"], e["lon"], lat0, lon0, k)
				places.append({"name": name, "kind": tags["place"],
					"rank": PLACE_RANK[tags["place"]], "x": snappedf(p.x, 1.0),
					"y": snappedf(p.y, 1.0)})
			continue
		var lines: Array[PackedVector2Array] = []
		if e["type"] == "way":
			lines = BlockBaker._runs(e.get("geometry", []), lat0, lon0, k)
		else:
			var outer: Array[PackedVector2Array] = []
			for m: Dictionary in e.get("members", []):
				if m.get("type") == "way" and m.get("role", "outer") in ["outer", ""]:
					outer.append_array(BlockBaker._runs(m.get("geometry", []), lat0, lon0, k))
			lines = Geo.rings(outer)
		if tags.has("highway"):
			if tags.get("tunnel", "no") != "no":
				continue
			for line in lines:
				for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(
						line, box):
					roads.append({"kind": tags["highway"],
						"line": _pts(Geo.simplify(piece, ROAD_TOL))})
		elif tags.get("natural") == "coastline":
			coast.append_array(lines)
		elif tags.get("waterway") == "river":
			for line in lines:
				for piece: PackedVector2Array in Geometry2D.intersect_polyline_with_polygon(
						line, box):
					rivers.append(_pts(Geo.simplify(piece, AREA_TOL)))
		else:
			var is_park: bool = tags.get("leisure") == "park"
			for line in lines:
				_add_area(parks if is_park else water, line, box,
					MIN_PARK if is_park else MIN_WATER)
	var sea := Geo.sea(coast, box)
	var sea_out: Array = []
	for poly: PackedVector2Array in sea["water"]:
		sea_out.append(_pts(Geo.simplify(poly, AREA_TOL)))
	var land: Array = []
	for poly: PackedVector2Array in sea["islands"]:
		_add_area(land, poly, box, 0.0)
	# the same name twice within a kilometre is one place tagged twice
	places.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["rank"] < b["rank"])
	var kept: Array[Dictionary] = []
	for p in places:
		var dup := false
		for q in kept:
			if q["name"] == p["name"] and Vector2(q["x"], q["y"]).distance_to(
					Vector2(p["x"], p["y"])) < 1000.0:
				dup = true
				break
		if not dup:
			kept.append(p)
	return {
		"format": FORMAT, "format_version": VERSION,
		"source": "OpenStreetMap via Overpass API",
		"attribution": "© OpenStreetMap contributors (ODbL)",
		"center": {"lat": lat0, "lon": lon0}, "half_m": HALF,
		"roads": roads, "sea": sea_out, "land": land, "water": water, "rivers": rivers,
		"parks": parks, "places": kept,
		"stats": {"elements": els.size(), "roads": roads.size(), "places": kept.size(),
			"bake_ms": Time.get_ticks_msec() - t0},
	}


# a name the game's Latin font can draw: the local one when it is Latin, else a romanised one
# (Tokyo's names are Japanese in `name`; name:en is the usual romanisation there), else Spanish
static func pick_name(tags: Dictionary) -> String:
	for key in ["name", "name:en", "name:ja-Latn", "name:ja_rm", "name:latin", "name:es",
			"int_name"]:
		var s: String = tags.get(key, "")
		if s != "" and is_latin(s):
			return s
	return ""


static func is_latin(s: String) -> bool:
	for i in s.length():
		if s.unicode_at(i) > 0x24F and s.unicode_at(i) != 0x2019:
			return false
	return true


static func _add_area(into: Array, line: PackedVector2Array, box: PackedVector2Array,
		min_area: float) -> void:
	var poly := Geo.repair(line)
	if poly.size() < 3 or absf(Geo.area(poly)) < min_area:
		return
	for piece in Geo.clip(poly, box):
		var simple := Geo.simplify(piece, AREA_TOL)
		if simple.size() >= 3:
			into.append(_pts(simple))


static func _pts(line: PackedVector2Array) -> Array:
	var out := []
	for p in line:
		out.append([snappedf(p.x, 1.0), snappedf(p.y, 1.0)])
	return out
