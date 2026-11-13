extends SceneTree

# Checks that real map downloads work on this machine: one small Overpass query (the streets
# within 150 m of a point, the same kind of query an office makes) through the game's own
# downloader, then the bake. Prints the server that answered, size, time, what came back and what
# the bake made of it. Touches nothing under user://.
#
#   godot --headless --path . --script res://tools/net_check.gd
#   godot --headless --path . --script res://tools/net_check.gd -- --lat=35.6595 --lon=139.7005
#
# Prints PASS and exits 0, or prints why it failed and exits 1. With every server busy it can
# take a few minutes (it retries politely).

const RADIUS := 150.0

var _lat := 41.3925
var _lon := 2.1640
var _net: Overpass


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lat="):
			_lat = arg.substr(6).to_float()
		elif arg.begins_with("--lon="):
			_lon = arg.substr(6).to_float()
	Overpass.read_flags()
	if Overpass.fixture_mode:
		printerr("FAIL net_check: fixture mode is on, this check needs the real network")
		quit(1)
		return
	print("net_check: asking Overpass for the streets within %d m of %.5f, %.5f" % [
		roundi(RADIUS), _lat, _lon])
	print("net_check: proxy %s" % (OS.get_environment("HTTPS_PROXY") if
		OS.get_environment("HTTPS_PROXY") != "" else "none (direct)"))
	_net = Overpass.new()
	_net.status.connect(func(text: String) -> void: print("  ", text))
	_net.finished.connect(_on_done)
	_net.failed.connect(func(reason: String) -> void:
		printerr("FAIL net_check: " + reason)
		quit(1))
	root.add_child.call_deferred(_net)
	_start.call_deferred()


func _start() -> void:
	_net.fetch(BlockBaker.query(_lat, _lon, RADIUS), Callable())


func _on_done(body: PackedByteArray, info: Dictionary) -> void:
	print("net_check: %s answered %d bytes in %.1f s (try %d)" % [info.get("mirror", "?"),
		info["bytes"], info["ms"] / 1000.0, info.get("tries", 1)])
	var raw: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not raw is Dictionary:
		printerr("FAIL net_check: not JSON: " + body.slice(0, 200).get_string_from_utf8())
		quit(1)
		return
	var counts := {}
	for e: Dictionary in raw.get("elements", []):
		var tags: Dictionary = e.get("tags", {})
		var kind := "other"
		for key in ["highway", "railway", "landuse", "leisure", "natural", "waterway"]:
			if tags.has(key):
				kind = key
				break
		counts[kind] = counts.get(kind, 0) + 1
	print("net_check: %d elements %s" % [raw.get("elements", []).size(), counts])
	var named := {}
	for e: Dictionary in raw.get("elements", []):
		var name: String = e.get("tags", {}).get("name", "")
		if name != "" and e.get("tags", {}).has("highway"):
			named[name] = true
	print("net_check: streets: %s" % ", ".join(named.keys().slice(0, 8)))
	var block := BlockBaker.bake(raw, _lat, _lon, RADIUS)
	var st: Dictionary = block["stats"]
	print("net_check: bake %d ms: %d roads, %d blocks, %d plots (%d built)" % [st["bake_ms"],
		st["roads"], st["blocks"], st["plots"], st["built"]])
	if st["roads"] == 0:
		printerr("FAIL net_check: no streets came back (is the point in the sea?)")
		quit(1)
		return
	print("PASS net_check")
	quit(0)
