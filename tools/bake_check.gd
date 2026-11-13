extends SceneTree

# Bakes office areas and city maps without the game and checks the result: every plot, green and
# water polygon must triangulate, sit inside the disc, and the file must round-trip through JSON.
# By default it uses the made-up fixtures (no network). With a raw Overpass file it bakes that:
#
#   godot --headless --path . --script res://tools/bake_check.gd
#   godot --headless --path . --script res://tools/bake_check.gd -- --raw=/abs/area.json \
#       --lat=41.3925 --lon=2.1640 [--radius=500] [--city]
#
# Prints PASS and exits 0, or prints what failed and exits 1.

const RADIUS := 500.0

var _bad := 0


func _init() -> void:
	var raw_path := ""
	var lat := 0.0
	var lon := 0.0
	var radius := RADIUS
	var as_city := false
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
	if raw_path != "":
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
	var named := 0
	for p: Dictionary in block["plots"]:
		if p["street"] != "":
			named += 1
	print("%s: %d roads, %d faces -> %d blocks -> %d plots (%d built, %d with a street name), " \
		% [label, st["roads"], st["faces"], st["blocks"], st["plots"], st["built"], named] \
		+ "%d greens, %d water, rot %.1f, office %s, graph %d ms, bake %d ms, %d KB" % [
		st["greens"], st["water"], block["rotation_deg"], block["office_plot"], st["graph_ms"],
		st["bake_ms"], text.length() / 1024])
	if block["plots"].is_empty():
		_fail(label + " has no plots")
	for key in ["plots", "blocks", "greens", "courts", "water", "land"]:
		for item: Dictionary in block[key]:
			_check_poly(item["poly"], "%s %s %s" % [label, key, item.get("id", item.get("kind"))],
				radius)
	for road: Dictionary in block["roads"]:
		if road["line"].size() < 2:
			_fail("%s road with %d points" % [label, road["line"].size()])
	if JSON.parse_string(text) == null:
		_fail(label + " does not round-trip through JSON")


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
