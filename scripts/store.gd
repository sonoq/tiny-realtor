class_name Store
extends RefCounted

# Everything the game keeps on disk, under user://. Downloads are kept forever and never
# refreshed (docs/DESIGN.md): a city map is fetched once per city, an office area once per office.
#   user://cities/<city>.json        baked city map (roads, water, neighbourhood names)
#   user://offices/index.json        {"offices": [office meta, ...]}
#   user://offices/<office>.json     baked block (format tiny-realestate-block v2) + "office" meta

const CITIES := "user://cities"
const OFFICES := "user://offices"
const INDEX := "user://offices/index.json"

static var _offices: Array[Dictionary] = []
static var _loaded := false


static func read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


# writes through a temp file, so a crash mid-write never leaves half a save behind
static func write_json(path: String, data: Variant) -> int:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("Store: cannot write " + tmp)
		return -1
	f.store_string(JSON.stringify(data))
	var size := f.get_length()
	f.close()
	DirAccess.rename_absolute(tmp, path)
	return size


static func city_path(city_id: String) -> String:
	return "%s/%s.json" % [CITIES, city_id]


static func office_path(office_id: String) -> String:
	return "%s/%s.json" % [OFFICES, office_id]


static func offices() -> Array[Dictionary]:
	if not _loaded:
		_loaded = true
		_offices.clear()
		var data: Variant = read_json(INDEX)
		if data is Dictionary:
			for o: Variant in data.get("offices", []):
				# an index entry whose area file is gone is dropped, so it can be placed again
				if not o is Dictionary or not FileAccess.file_exists(office_path(o.get("id", ""))):
					continue
				# offices made of test data live apart from real ones, never on the same map
				if (o.get("source") == "fixture") == Overpass.fixture_mode:
					_offices.append(o)
	return _offices


static func offices_in(city_id: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for o in offices():
		if o["city"] == city_id:
			out.append(o)
	return out


static func add_office(meta: Dictionary) -> void:
	offices().append(meta)
	# the file keeps every office, the test-data ones too, whatever this run shows
	var all: Array = []
	var data: Variant = read_json(INDEX)
	if data is Dictionary:
		all = data.get("offices", [])
	all.append(meta)
	write_json(INDEX, {"offices": all})


# forget the in-memory index, for tools that change user:// behind the game's back
static func reload() -> void:
	_loaded = false
