extends SceneTree

# Dev only: bakes the world map's pictures, res://assets/world/world_<level>.png (World.LEVELS
# of them, World.art_size(level) each), from Natural Earth's public-domain 1:50m vectors
# (docs/NATURAL_EARTH.md). Run it again only to change the look; the game never downloads.
#
#   bash tools/fetch_natural_earth.sh /abs/ne        # once: the three GeoJSON files (~3.3 MB)
#   godot --headless --path . --script res://tools/build_world.gd -- --src=/abs/ne
#   godot --headless --path . --import               # then commit the PNGs and their .import
#
# Every pixel is a colour of the game's palette (Pal), in the city map's night look: slate land
# with a faint dither and a lighter coast rim, deep teal sea with a lighter ring along the
# shore, dotted country borders on the land (from level 1), and a faint dotted graticule every
# 30 degrees on the open sea. Land is filled where a pixel's middle falls inside a polygon (even-
# odd over its rings), lakes are cut back out; a lake of one pixel is dropped. Deterministic.

const FILES := {
	"land": "ne_50m_land.geojson",
	"lakes": "ne_50m_lakes.geojson",
	"borders": "ne_50m_admin_0_boundary_lines_land.geojson",
}
const OUT := "res://assets/world"
enum { SEA, LAND }
const SEA_C := "CYAN_DD"
const SHORE_C := "TEAL3"
const GRID_C := "TEAL3"
const LAND_C := "SL2"
const DOT_C := "SL1"
const COAST_C := "SL3"
const BORDER_C := "SL1"
const GRID_DEG := 30.0

var _src := ""


func _init() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--src="):
			_src = arg.substr(6)
	if _src == "":
		printerr("build_world: need --src=/abs/dir with the Natural Earth GeoJSON files")
		quit(1)
		return
	var data := {}
	for k: String in FILES:
		var path := _src.path_join(FILES[k])
		var json: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		if not json is Dictionary:
			printerr("build_world: cannot read " + path)
			quit(1)
			return
		data[k] = json["features"]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	for level in World.LEVELS:
		var t0 := Time.get_ticks_msec()
		var img := _bake(level, data)
		var path := ProjectSettings.globalize_path("%s/world_%d.png" % [OUT, level])
		if img.save_png(path) != OK:
			printerr("build_world: cannot write " + path)
			quit(1)
			return
		print("build_world: level %d %dx%d in %d ms, %d B" % [level, img.get_width(),
			img.get_height(), Time.get_ticks_msec() - t0, FileAccess.get_file_as_bytes(path).size()])
	print("PASS build_world")
	quit(0)


func _bake(level: int, data: Dictionary) -> Image:
	var size := World.art_size(level)
	var w := size.x
	var h := size.y
	var grid := PackedByteArray()
	grid.resize(w * h)
	for f: Dictionary in data["land"]:
		for poly: Array in _polys(f["geometry"]):
			_fill(grid, w, h, poly, LAND)
	for f: Dictionary in data["lakes"]:
		for poly: Array in _polys(f["geometry"]):
			_fill(grid, w, h, poly, SEA)
	# a lake of one pixel reads as a speck of dirt, not water
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var i := y * w + x
			if grid[i] == SEA and grid[i - 1] == LAND and grid[i + 1] == LAND \
					and grid[i - w] == LAND and grid[i + w] == LAND:
				grid[i] = LAND
	var border := PackedByteArray()
	border.resize(w * h)
	if level >= 1:
		for f: Dictionary in data["borders"]:
			for line: Array in _lines(f["geometry"]):
				_stroke(border, w, h, line)
	var rgb := PackedByteArray()
	rgb.resize(w * h * 3)
	var sea := _rgb(SEA_C)
	var shore := _rgb(SHORE_C)
	var grid_c := _rgb(GRID_C)
	var land := _rgb(LAND_C)
	var dot := _rgb(DOT_C)
	var coast := _rgb(COAST_C)
	var line_c := _rgb(BORDER_C)
	var lines := _graticule(w, h)
	for y in h:
		for x in w:
			var i := y * w + x
			var c := sea
			if grid[i] == LAND:
				if _touches(grid, w, h, x, y, SEA):
					c = coast
				elif border[i] == 1:
					c = line_c
				elif y % 3 == 0 and (x + (y / 3) * 3) % 6 == 0:
					c = dot
				else:
					c = land
			elif _touches(grid, w, h, x, y, LAND):
				c = shore
			elif lines.has(i) and (x + y) % 3 == 0:
				c = grid_c
			rgb[i * 3] = c[0]
			rgb[i * 3 + 1] = c[1]
			rgb[i * 3 + 2] = c[2]
	return Image.create_from_data(w, h, false, Image.FORMAT_RGB8, rgb)


static func _rgb(name: String) -> PackedByteArray:
	var c := Pal.color(Pal.i(name))
	return PackedByteArray([c.r8, c.g8, c.b8])


static func _touches(grid: PackedByteArray, w: int, h: int, x: int, y: int, kind: int) -> bool:
	return (x > 0 and grid[y * w + x - 1] == kind) or (x < w - 1 and grid[y * w + x + 1] == kind) \
		or (y > 0 and grid[(y - 1) * w + x] == kind) or (y < h - 1 and grid[(y + 1) * w + x] == kind)


# the pixels of the 30-degree meridians and parallels (the open sea shows them dotted)
static func _graticule(w: int, h: int) -> Dictionary:
	var out := {}
	var lon := -180.0 + GRID_DEG
	while lon < 180.0:
		var x := floori(World.unit(0.0, lon).x * w)
		for y in h:
			out[y * w + x] = true
		lon += GRID_DEG
	var lat := -30.0
	while lat < World.LAT_N:
		var y := floori(World.unit(lat, 0.0).y * h)
		if y >= 0 and y < h:
			for x in w:
				out[y * w + x] = true
		lat += GRID_DEG
	return out


static func _polys(g: Dictionary) -> Array:
	if g["type"] == "Polygon":
		return [g["coordinates"]]
	if g["type"] == "MultiPolygon":
		return g["coordinates"]
	return []


static func _lines(g: Dictionary) -> Array:
	if g["type"] == "LineString":
		return [g["coordinates"]]
	if g["type"] == "MultiLineString":
		return g["coordinates"]
	return []


# fills the pixels whose middle lies inside the polygon (its rings even-odd: holes stay out)
static func _fill(grid: PackedByteArray, w: int, h: int, rings: Array, kind: int) -> void:
	# packed arrays are copied out of a dictionary, so the crossings are kept in plain arrays
	var rows := {}
	for ring: Array in rings:
		var pts := PackedVector2Array()
		for q: Array in ring:
			var u := World.unit(float(q[1]), float(q[0]))
			pts.append(Vector2(u.x * w, u.y * h))
		for k in pts.size():
			var a := pts[k]
			var b := pts[(k + 1) % pts.size()]
			if a.y == b.y:
				continue
			var lo := minf(a.y, b.y)
			var hi := maxf(a.y, b.y)
			# rows whose middle (row + 0.5) is in [lo, hi)
			var r0 := maxi(0, ceili(lo - 0.5))
			var r1 := mini(h - 1, ceili(hi - 0.5) - 1)
			for r in range(r0, r1 + 1):
				var yc := r + 0.5
				var x := a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y)
				if not rows.has(r):
					rows[r] = []
				(rows[r] as Array).append(x)
	for r: int in rows:
		var xs: Array = rows[r]
		xs.sort()
		for k in range(0, xs.size() - 1, 2):
			var c0 := maxi(0, ceili(float(xs[k]) - 0.5))
			var c1 := mini(w - 1, ceili(float(xs[k + 1]) - 0.5) - 1)
			for c in range(c0, c1 + 1):
				grid[r * w + c] = kind


# a dotted line: every other pixel of a Bresenham walk along each segment
static func _stroke(mask: PackedByteArray, w: int, h: int, line: Array) -> void:
	var prev := Vector2i(-1, -1)
	var step := 0
	for q: Array in line:
		var u := World.unit(float(q[1]), float(q[0]))
		var p := Vector2i(floori(u.x * w), floori(u.y * h))
		if prev.x >= 0:
			var d := (p - prev).abs()
			var s := Vector2i(signi(p.x - prev.x), signi(p.y - prev.y))
			var err := d.x - d.y
			var c := prev
			while c != p:
				var e2 := err * 2
				if e2 > -d.y:
					err -= d.y
					c.x += s.x
				if e2 < d.x:
					err += d.x
					c.y += s.y
				step += 1
				if step % 2 == 0 and c.x >= 0 and c.x < w and c.y >= 0 and c.y < h:
					mask[c.y * w + c.x] = 1
		prev = p
