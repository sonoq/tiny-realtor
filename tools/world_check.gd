extends SceneTree

# Checks the world map without drawing it: the baked pictures are there at World.art_size, only
# in palette colours; every shipped city falls on land (or its coast) in the sharpest picture;
# the projection goes there and back; and at every zoom step every city is in exactly one
# group, no two groups' hit boxes overlap and each is at least Ui.MIN_HIT. Prints the groups at
# each step (how many, the biggest).
#
#   godot --headless --path . --script res://tools/world_check.gd

var _bad := 0


func _init() -> void:
	# the land's colours in tools/build_world.gd: fill, dither and border, coast rim
	var land: Array[Color] = [Pal.color(Pal.i("SL2")), Pal.color(Pal.i("SL1")),
		Pal.color(Pal.i("SL3"))]
	var palette := {}
	for k in Pal.NAMES.size():
		palette[Pal.color(k).to_html(false)] = true
	var sharp: Image
	for level in World.LEVELS:
		var path := ProjectSettings.globalize_path(World.PATH % level)
		var img := Image.load_from_file(path)
		if img == null or img.get_size() != World.art_size(level):
			_fail("level %d: missing or not %s" % [level, World.art_size(level)])
			continue
		var seen := {}
		for y in range(0, img.get_height(), 3):
			for x in img.get_width():
				seen[img.get_pixel(x, y).to_html(false)] = true
		for c: String in seen:
			if not palette.has(c):
				_fail("level %d: colour #%s is not in the palette" % [level, c])
		sharp = img
	for city in CityDb.all():
		var u := World.unit(city["lat"], city["lon"])
		if absf(World.lat_at(u.y) - float(city["lat"])) > 1e-3 \
				or absf(World.lon_at(u.x) - float(city["lon"])) > 1e-3:
			_fail("%s: the projection does not come back" % city["id"])
		if sharp == null:
			continue
		var p := Vector2i(u * Vector2(sharp.get_size()))
		var on_land := false
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var q := (p + Vector2i(dx, dy)).clamp(Vector2i.ZERO,
					sharp.get_size() - Vector2i.ONE)
				var c := sharp.get_pixelv(q)
				for l in land:
					if c.is_equal_approx(l):
						on_land = true
		if not on_land:
			_fail("%s is in the sea" % city["id"])
	if WorldMap.HIT < Ui.MIN_HIT:
		_fail("the markers' hit box is under MIN_HIT")
	for step in World.STEPS:
		var pts := PackedVector2Array()
		for city in CityDb.all():
			pts.append(World.unit(city["lat"], city["lon"]) * World.screen_size(step))
		var groups := World.clusters(pts, WorldMap.HIT)
		var count := {}
		var biggest := 0
		for g: Dictionary in groups:
			biggest = maxi(biggest, (g["members"] as Array).size())
			for m: int in g["members"]:
				count[m] = int(count.get(m, 0)) + 1
		for i in pts.size():
			if int(count.get(i, 0)) != 1:
				_fail("step %d: city %d is in %d groups" % [step, i, int(count.get(i, 0))])
		for a in groups.size():
			for b in range(a + 1, groups.size()):
				var d: Vector2 = (groups[a]["at"] as Vector2) - (groups[b]["at"] as Vector2)
				if absf(d.x) < WorldMap.HIT and absf(d.y) < WorldMap.HIT:
					_fail("step %d: two groups' hit boxes overlap" % step)
		print("world_check: x%d %d groups, the biggest %d cities" % [1 << step, groups.size(),
			biggest])
	if _bad > 0:
		printerr("FAIL world_check: %d problems" % _bad)
		quit(1)
		return
	print("PASS world_check")
	quit(0)


func _fail(why: String) -> void:
	_bad += 1
	printerr("world_check: " + why)
