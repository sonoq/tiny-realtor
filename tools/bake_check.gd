extends SceneTree

# Bakes office areas and city maps without the game and checks the result: every lot, green and
# water polygon must triangulate and sit inside the disc, every lot must face a street (its
# `fronts` sides lie along one), the lot count must stay in LOTS (a 500 m area is a few hundred
# lots, not thousands), and the file must round-trip through JSON. By default it uses the made-up
# fixtures (no network). With a raw Overpass file it bakes that; with a saved v2 area it checks
# the v2 -> v3 upgrade:
#
#   godot --headless --path . --script res://tools/bake_check.gd
#   godot --headless --path . --script res://tools/bake_check.gd -- --raw=/abs/area.json \
#       --lat=41.3925 --lon=2.1640 [--radius=500] [--city]
#   godot --headless --path . --script res://tools/bake_check.gd -- --upgrade=/abs/office_v2.json
#
# Prints PASS and exits 0, or prints what failed and exits 1.

const RADIUS := 500.0
# lots a 500 m area may hold (scaled by the disc's area for other radii)
const LOTS := Vector2i(20, 600)
# the middle of a lot's street side must lie within this (m) of a street's kerb line
const FRONT_REACH := BlockBaker.PAVEMENT + BlockBaker.FRONT_TOL + 0.5

var _bad := 0


func _init() -> void:
	var raw_path := ""
	var lat := 0.0
	var lon := 0.0
	var radius := RADIUS
	var as_city := false
	var upgrade := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--raw="):
			raw_path = arg.substr(6)
		elif arg.begins_with("--lat="):
			lat = arg.substr(6).to_float()
		elif arg.begins_with("--lon="):
			lon = arg.substr(6).to_float()
		elif arg.begins_with("--radius="):
			radius = arg.substr(9).to_float()
		elif arg == "--city":
			as_city = true
		elif arg.begins_with("--upgrade="):
			upgrade = arg.substr(10)
	if upgrade != "":
		var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(upgrade))
		if not old is Dictionary or int(old.get("format_version", 0)) != 2:
			_fail("not a v2 area: " + upgrade)
		else:
			var before: int = old["plots"].size()
			var block := BlockBaker.upgrade(old)
			print("%s: v2 %d plots -> v%d %d lots" % [upgrade.get_file(), before,
				block["format_version"], block["plots"].size()])
			_check_block(block, "upgrade " + upgrade.get_file(), float(block["radius_m"]))
	elif raw_path != "":
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(raw_path))
		if not raw is Dictionary:
			_fail("cannot parse " + raw_path)
		elif as_city:
			_check_city(CityBaker.bake(raw, lat, lon), raw_path)
		else:
			_check_block(BlockBaker.bake(raw, lat, lon, radius), raw_path, radius)
	else:
		for c: Dictionary in [CityDb.get_city("barcelona"), CityDb.get_city("tokyo"),
				CityDb.get_city("warszawa")]:
			_check_city(CityBaker.bake(Fixture.city(c), c["lat"], c["lon"]), "fixture " + c["id"])
		for at: Vector2 in [Vector2(41.3925, 2.1640), Vector2(35.6595, 139.7005),
				Vector2(52.2297, 21.0122)]:
			_check_block(BlockBaker.bake(Fixture.area(at.x, at.y, radius), at.x, at.y, radius),
				"fixture %s" % at, radius)
	if _bad == 0:
		print("PASS bake_check")
		quit(0)
	else:
		print("FAIL bake_check: %d problems" % _bad)
		quit(1)


func _check_block(block: Dictionary, label: String, radius: float) -> void:
	var text := JSON.stringify(block)
	var st: Dictionary = block["stats"]
	var lots: Array = block["plots"]
	var named := 0
	var near := 0
	var areas: Array[float] = []
	for p: Dictionary in lots:
		if p["street"] != "":
			named += 1
		var poly := _poly(p["poly"])
		if Geo.centre(poly).length() <= Rules.active_radius(1):
			near += 1
		areas.append(float(p["area_m2"]))
	areas.sort()
	var mid := areas[areas.size() / 2] if not areas.is_empty() else 0.0
	print("%s: %d roads, %d blocks -> %d lots (%d built, %d named, %d within %d m), " % [label,
		st["roads"], st["blocks"], lots.size(), st["built"], named, near,
		roundi(Rules.active_radius(1))] + "lot m2 median %d max %d, %d gardens, " % [
		roundi(mid), roundi(areas[-1]) if not areas.is_empty() else 0, block["courts"].size()] \
		+ "rot %.1f, office %s, bake %d ms, %d KB" % [block["rotation_deg"], block["office_plot"],
		st["bake_ms"], text.length() / 1024])
	var scale := (radius / RADIUS) ** 2
	if lots.size() < roundi(LOTS.x * scale) or lots.size() > roundi(LOTS.y * scale):
		_fail("%s has %d lots, outside %d..%d" % [label, lots.size(), roundi(LOTS.x * scale),
			roundi(LOTS.y * scale)])
	if block["office_plot"] == "":
		_fail(label + " has no office lot")
	for key in ["plots", "blocks", "greens", "courts", "water", "land"]:
		for item: Dictionary in block[key]:
			_check_poly(item["poly"], "%s %s %s" % [label, key, item.get("id", item.get("kind"))],
				radius)
	var kerbs := _kerbs(block["roads"])
	for p: Dictionary in lots:
		_check_fronts(p, kerbs, "%s lot %s" % [label, p["id"]])
	for road: Dictionary in block["roads"]:
		if road["line"].size() < 2:
			_fail("%s road with %d points" % [label, road["line"].size()])
	if JSON.parse_string(text) == null:
		_fail(label + " does not round-trip through JSON")


# every lot names at least one street side, and each named side runs along a street's kerb
func _check_fronts(lot: Dictionary, kerbs: Array, what: String) -> void:
	var poly := _poly(lot["poly"])
	var fronts: Array = lot.get("fronts", [])
	if fronts.is_empty():
		_fail(what + " faces no street")
		return
	for i: Variant in fronts:
		var k := int(i)
		if k < 0 or k >= poly.size():
			_fail("%s names side %d of %d" % [what, k, poly.size()])
			return
		var mid := (poly[k] + poly[(k + 1) % poly.size()]) * 0.5
		var best := INF
		for seg: Array in kerbs:
			var d := Geometry2D.get_closest_point_to_segment(mid, seg[0], seg[1]).distance_to(mid)
			best = minf(best, d - float(seg[2]))
		if best > FRONT_REACH:
			_fail("%s side %d is %.1f m from any kerb" % [what, k, best])
			return


# every street segment with half its width
func _kerbs(roads: Array) -> Array:
	var out: Array = []
	for r: Dictionary in roads:
		var line := _poly(r["line"])
		for i in range(1, line.size()):
			out.append([line[i - 1], line[i], float(r["width"]) * 0.5])
	return out


func _poly(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Array in raw:
		out.append(Vector2(p[0], p[1]))
	return out


func _check_city(city: Dictionary, label: String) -> void:
	var st: Dictionary = city["stats"]
	print("%s: %d roads, %d places, %d sea, %d water, %d parks, bake %d ms, %d KB" % [label,
		st["roads"], st["places"], city["sea"].size(), city["water"].size(), city["parks"].size(),
		st["bake_ms"], JSON.stringify(city).length() / 1024])


func _check_poly(raw: Array, what: String, radius: float) -> void:
	var poly := PackedVector2Array()
	for p: Array in raw:
		poly.append(Vector2(p[0], p[1]))
	if poly.size() < 3 or Geometry2D.triangulate_polygon(poly).is_empty():
		_fail(what + " does not triangulate")
	for p in poly:
		if p.length() > radius + 1.0:
			_fail("%s sticks out of the disc (%.1f m)" % [what, p.length()])
			return


func _fail(why: String) -> void:
	_bad += 1
	if _bad <= 20:
		printerr("FAIL: " + why)
