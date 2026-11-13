extends SceneTree

# Dev only: files a raw Overpass answer under the name the game's --raw-cache looks for, so the
# real flow (city map, office download, bake, view) can run on real OSM data taken from an
# extract when the Overpass servers cannot be reached (as in the cloud container).
#
#   godot --headless --path . --script res://tools/seed_cache.gd -- --dir=/abs/cache \
#       --city=helsinki [--city-raw=/abs/city.json] [--lat=60.17 --lon=24.944 --raw=/abs/area.json]


func _init() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var kv := arg.trim_prefix("--").split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var dir: String = args.get("dir", "")
	var city := CityDb.get_city(args.get("city", ""))
	if dir == "" or city.is_empty():
		printerr("seed_cache: need --dir and a known --city")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(dir)
	if args.has("city-raw"):
		_file(dir, CityBaker.query(city["lat"], city["lon"]), args["city-raw"])
	if args.has("raw"):
		var q := BlockBaker.query(float(args["lat"]), float(args["lon"]), Rules.MAX_RADIUS)
		_file(dir, q, args["raw"])
	quit(0)


func _file(dir: String, query: String, src: String) -> void:
	var dst := dir.path_join(query.md5_text() + ".json")
	DirAccess.copy_absolute(src, dst)
	print("seed_cache: %s -> %s" % [src.get_file(), dst])
