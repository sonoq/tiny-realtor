class_name Fixture
extends RefCounted

# Made-up test data in the exact shape Overpass answers with, for working without a network
# (debug flag --fixture; see Overpass). Nothing here is real: the game shows DATOS DE PRUEBA on
# every map screen while it is used. An office placed within 1.5 km of the prototype's sample (a
# hand-made Eixample) gets that sample slid under it; anywhere else a generated street grid.

const SAMPLE := "res://docs/prototype/data/block_raw_overpass.json"
const SAMPLE_AT := Vector2(41.3957, 2.1623)
const COASTAL := ["barcelona", "valencia", "malaga", "lisboa", "newyork", "sanfrancisco",
	"sydney", "tokyo", "istanbul", "buenosaires", "singapore", "dubai", "lima", "chicago"]

static var _next_id := 1


# a city box: a rotated grid of avenues, a ring road, a river, maybe a coast, test place names
static func city(city: Dictionary) -> Dictionary:
	var lat0: float = city["lat"]
	var lon0: float = city["lon"]
	var key: String = city["id"]
	var k := Geo.scale_at(lat0)
	var half := CityBaker.HALF * 1.2
	var els: Array = []
	var turn := (_h01(key + "rot") - 0.5) * 0.9
	var step := 650.0 + _h01(key + "step") * 300.0
	var sea_dir := Vector2.RIGHT.rotated(_h01(key + "sea") * TAU)
	var coastal: bool = key in COASTAL
	var shore := 2200.0 + _h01(key + "shore") * 1200.0
	var n := int(half / step)
	for axis in 2:
		for i in range(-n, n + 1):
			var kind := "primary" if i % 3 == 0 else "secondary"
			var pts := PackedVector2Array()
			for j in range(-20, 21):
				var t := j * half / 20.0
				var p := Vector2(i * step, t) if axis == 0 else Vector2(t, i * step)
				p = p.rotated(turn)
				if coastal and p.dot(sea_dir) > shore:
					continue
				pts.append(p)
			if pts.size() > 1:
				els.append(_way({"highway": kind, "name": "Avenida %d" % (i + n)}, pts, lat0, lon0, k))
	# a ring motorway and a river, so the map has more than a grid
	var ring := PackedVector2Array()
	for j in 49:
		var p := Vector2(cos(TAU * j / 48.0), sin(TAU * j / 48.0)) * 3300.0
		if not (coastal and p.dot(sea_dir) > shore):
			ring.append(p)
	els.append(_way({"highway": "motorway"}, ring, lat0, lon0, k))
	var river := PackedVector2Array()
	for j in range(-12, 13):
		var t := j * half / 12.0
		river.append(Vector2(t, sin(t / 900.0) * 400.0 - 1500.0).rotated(-turn * 0.5))
	els.append(_way({"waterway": "river"}, river, lat0, lon0, k))
	if coastal:
		# coastline with land on its left: walking along `dir`, the sea (sea_dir) is to the right
		var dir := Vector2(-sea_dir.y, sea_dir.x)
		var coast := PackedVector2Array()
		for j in range(-10, 11):
			var t := j * half * 0.2
			coast.append(sea_dir * (shore + sin(t / 700.0) * 250.0) + dir * t)
		els.append(_way({"natural": "coastline"}, coast, lat0, lon0, k))
	for j in 3:
		var c := Vector2(_h01(key + "pk%d" % j) - 0.5, _h01(key + "pq%d" % j) - 0.5) * 5000.0
		var park := PackedVector2Array()
		for q in 4:
			park.append(c + Vector2(cos(TAU * q / 4.0 + turn), sin(TAU * q / 4.0 + turn)) * 260.0)
		park.append(park[0])
		els.append(_way({"leisure": "park"}, park, lat0, lon0, k))
	var names := ["Norte", "Sur", "Este", "Oeste", "Centro", "Puerto", "Alto", "Bajo", "Nuevo",
		"Viejo", "Jardines", "Mercado", "Estación", "Ribera", "Colina", "Plaza"]
	var i := 0
	for gy in range(-2, 3):
		for gx in range(-2, 3):
			var p := Vector2(gx * 1500.0, gy * 1500.0).rotated(turn) \
				+ Vector2(_h01(key + "x%d" % i) - 0.5, _h01(key + "y%d" % i) - 0.5) * 600.0
			if coastal and p.dot(sea_dir) > shore - 200.0:
				i += 1
				continue
			var ll := Geo.to_latlon(p, lat0, lon0, k)
			els.append({"type": "node", "id": _id(), "lat": ll.x, "lon": ll.y, "tags": {
				"place": "suburb" if (gx + gy) % 2 == 0 else "neighbourhood",
				"name": "Barrio %s" % names[i % names.size()]}})
			i += 1
	return {"version": 0.6, "generator": "Tiny Realtor fixture (made-up test data)",
		"elements": els}


# an office area: the prototype sample near it, else a generated grid of perimeter blocks
static func area(lat0: float, lon0: float, radius: float) -> Dictionary:
	if Geo.distance(lat0, lon0, SAMPLE_AT.x, SAMPLE_AT.y) < 1500.0 and FileAccess.file_exists(SAMPLE):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(SAMPLE))
		if parsed is Dictionary:
			var shift := Vector2(lat0, lon0) - SAMPLE_AT
			var kept: Array = []
			for e: Dictionary in parsed.get("elements", []):
				# the game no longer downloads buildings, so neither does the test data
				if e.get("tags", {}).has("building"):
					continue
				for g: Dictionary in e.get("geometry", []):
					g["lat"] = float(g["lat"]) + shift.x
					g["lon"] = float(g["lon"]) + shift.y
				kept.append(e)
			parsed["elements"] = kept
			return parsed
	var key := "%.4f,%.4f" % [lat0, lon0]
	var k := Geo.scale_at(lat0)
	var turn := _h01(key + "rot") * PI * 0.5
	var block := 70.0 + _h01(key + "blk") * 60.0
	var street := 10.0 + _h01(key + "st") * 6.0
	var pitch := block + street
	var els: Array = []
	var n := int(radius * 1.1 / pitch) + 1
	for axis in 2:
		for i in range(-n, n + 1):
			var avenue := i % 4 == 0
			var a := Vector2(i * pitch, -radius * 1.1)
			var b := Vector2(i * pitch, radius * 1.1)
			if axis == 1:
				a = Vector2(a.y, a.x)
				b = Vector2(b.y, b.x)
			var tags := {"highway": "primary" if avenue else "residential",
				"name": "Calle de prueba %d" % i}
			if avenue:
				tags["width"] = str(street + 10.0)
			els.append(_way(tags, PackedVector2Array([a.rotated(turn), b.rotated(turn)]), lat0,
				lon0, k))
	# a few parks, one commercial and one industrial zone, and a railway on a diagonal
	for gx in range(-n, n):
		for gy in range(-n, n):
			var lo := Vector2(gx, gy) * pitch + Vector2.ONE * (street * 0.5 + 3.0)
			var hi := Vector2(gx + 1, gy + 1) * pitch - Vector2.ONE * (street * 0.5 + 3.0)
			var near := ((lo + hi) * 0.5).length() < radius + pitch
			if near and _h01(key + "b%d_%d" % [gx, gy]) < 0.07:
				els.append(_way({"leisure": "park"}, _rect(lo, hi, turn), lat0, lon0, k))
	var shop := Vector2(_h01(key + "cx") - 0.5, _h01(key + "cy") - 0.5) * radius
	els.append(_way({"landuse": "commercial"}, _rect(shop - Vector2.ONE * 160.0,
		shop + Vector2.ONE * 160.0, turn), lat0, lon0, k))
	var works := -shop.normalized() * radius * 0.7
	els.append(_way({"landuse": "industrial"}, _rect(works - Vector2.ONE * 130.0,
		works + Vector2.ONE * 130.0, turn), lat0, lon0, k))
	var track := Vector2.RIGHT.rotated(turn + 0.6)
	els.append(_way({"railway": "rail"}, PackedVector2Array([track * -radius * 1.2,
		track * radius * 1.2]), lat0, lon0, k))
	return {"version": 0.6, "generator": "Tiny Realtor fixture (made-up test data)",
		"elements": els}


static func _rect(lo: Vector2, hi: Vector2, turn: float) -> PackedVector2Array:
	var pts := PackedVector2Array([lo, Vector2(hi.x, lo.y), hi, Vector2(lo.x, hi.y), lo])
	for i in pts.size():
		pts[i] = pts[i].rotated(turn)
	return pts


static func _way(tags: Dictionary, pts: PackedVector2Array, lat0: float, lon0: float,
		k: Vector2) -> Dictionary:
	var geometry := []
	for p in pts:
		var ll := Geo.to_latlon(p, lat0, lon0, k)
		geometry.append({"lat": snappedf(ll.x, 0.0000001), "lon": snappedf(ll.y, 0.0000001)})
	return {"type": "way", "id": _id(), "tags": tags, "geometry": geometry}


static func _id() -> int:
	_next_id += 1
	return 900000000 + _next_id


static func _h01(key: String) -> float:
	return float(key.md5_text().left(8).hex_to_int()) / 4294967296.0
