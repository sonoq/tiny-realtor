extends RefCounted

# The office areas the traffic and walker checks drive on: the three made-up fixture areas, one
# real area baked from a saved Overpass answer (Valencia, around the Gran Via de Ferran el
# Catòlic, where a side street joins the avenue inside its queue) and any saved office files.
# Preloaded by the checks (no class_name: the game never needs it).

# the real sample: OpenStreetMap data (ODbL, © OpenStreetMap contributors), fetched 2026-07-24
const REAL := "res://tools/data/valencia_overpass.json"
const REAL_AT := Vector2(39.473269, -0.387657)


# [[block, label], ...] (block null when it cannot be read); files: absolute paths of saved
# office areas (v2 files are upgraded)
static func load_all(files: Array[String]) -> Array:
	var areas: Array = []
	var cities: Array[String] = ["barcelona", "tokyo", "warszawa"]
	for at: Vector2 in [Vector2(41.3925, 2.1640), Vector2(35.6595, 139.7005),
			Vector2(52.2297, 21.0122)]:
		var block := BlockBaker.bake(Fixture.area(at.x, at.y, 500.0), at.x, at.y, 500.0)
		block["office"] = {"id": "fixture_%d" % areas.size(), "city": cities[areas.size()]}
		areas.append([block, "fixture %s" % block["office"]["city"]])
	# a missing or broken sample is a failure, not a skipped area
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(REAL)) \
		if FileAccess.file_exists(REAL) else null
	if raw is Dictionary:
		var block := BlockBaker.bake(raw, REAL_AT.x, REAL_AT.y, Rules.MAX_RADIUS)
		block["office"] = {"id": "valencia_sample", "city": "valencia"}
		areas.append([block, "osm valencia"])
	else:
		areas.append([null, REAL])
	for f in files:
		var block: Variant = Store.read_json(f)
		if not block is Dictionary:
			areas.append([null, f.get_file()])
			continue
		if int(block.get("format_version", 0)) == 2:
			block = BlockBaker.upgrade(block)
		areas.append([block, f.get_file()])
	return areas
