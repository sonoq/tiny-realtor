class_name BlockView
extends Node2D

# Draws one baked block file (the format of data/sample_block.json) as isometric pixel art, once.
# Ground coordinates are metres, x east and y north, already turned so the streets run along the
# axes. The drawing is meant for a low-res SubViewport that the caller scales up with nearest
# filtering, so every primitive here is plain and unsmoothed.

# low-res pixels per metre; the prototype found this shows about one and a half manzanas in 600 px
const SCALE := 1.35
# a touch below SCALE, so towers read tall without looking stretched
const RISE := SCALE * 0.95
const PAD := 10.0
# how deep the earth slab under the block goes, in metres, for the floating-diorama look
const SLAB_DEPTH := 9.0
const FLOOR_M := 3.2
const WINDOW_EVERY_M := 3.6
const LIT_SHARE := 0.12
# walls facing the viewer's right get full light, the ones facing left this much of it
const SHADE_LEFT := 0.78

const PAVING := Color("#cfc6b4")
const PAVING_DOT := Color("#c4bba8")
const CURB := Color("#a39a88")
const ASPHALT := Color("#5b5d66")
const MARK := Color("#e8e2cf")
const GREEN := Color("#6f9e4c")
const GREEN_EDGE := Color("#5d8a40")
const DIRT := Color("#b08d5e")
const DIRT_EDGE := Color("#9f7e52")
const EARTH_LIT := Color("#7a5a3c")
const EARTH_DARK := Color("#5e4530")
const GLASS := Color("#3d4a63")
const GLASS_LIT := Color("#ffd98a")
const SHOP := Color("#2f3442")
const SIGN := Color("#e8d44d")
const POST := Color("#6b4a2f")
const SHADOW := Color(0.16, 0.13, 0.22, 0.28)
const PROP_WALL := Color("#d9d2c4")
const PROP_ROOF := Color("#bdb5a6")
# roof and facade colours by plot category, so the type of each plot reads at a glance
const ROOF := {
	"residential": ["#c9714b", "#d08355", "#bd6644"], "commercial": ["#4f86b8", "#5a93c4"],
	"office": ["#7d8aa3", "#8a97ae"], "hotel": ["#9a6bb0"], "civic": ["#d9c27a"],
}
const FACADE := {
	"residential": ["#e6d3ad", "#dcc39a", "#e9c9a4", "#d8b892", "#e3dccb", "#d9a98a"],
	"commercial": ["#c9d3dc", "#b9c6d2"], "office": ["#aeb7c4", "#c0c6cf"], "hotel": ["#e2d2e6"],
	"civic": ["#e4d7b0"],
}

# pixel size of the whole drawing, for the SubViewport that holds it
var size := Vector2.ZERO
# where ground point (0, 0) lands in the drawing, so the caller can centre the view on it
var focus := Vector2.ZERO

var _block: Dictionary = {}
var _origin := Vector2.ZERO
var _slab := Rect2()


func load_block(path: String) -> bool:
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		push_error("BlockView: cannot read block file " + path)
		return false
	_block = parsed
	# the slab is the box the street centre lines span; streets end exactly on its edges
	var ends := PackedVector2Array()
	for road: Dictionary in _block["roads"]:
		ends.append_array(_points(road["line"]))
	_slab = Rect2(ends[0], Vector2.ZERO)
	for p: Vector2 in ends:
		_slab = _slab.expand(p)
	var tallest := 0.0
	for plot: Dictionary in _block["plots"]:
		tallest = maxf(tallest, float(plot["height_m"]) + 3.0)
	var box := Rect2(_raw(_slab.position.x, _slab.position.y, 0.0), Vector2.ZERO)
	for c: Vector2 in _corners():
		box = box.expand(_raw(c.x, c.y, 0.0)).expand(_raw(c.x, c.y, tallest))
		box = box.expand(_raw(c.x, c.y, -SLAB_DEPTH))
	_origin = Vector2(PAD, PAD) - box.position
	size = (box.size + Vector2(PAD, PAD) * 2.0).ceil()
	focus = _p(0.0, 0.0, 0.0)
	queue_redraw()
	return true


func _draw() -> void:
	if _block.is_empty():
		return
	_draw_ground()
	for road: Dictionary in _block["roads"]:
		_fill(_road_quad(road), ASPHALT, CURB)
	_draw_marks()
	for green: Dictionary in _block["greens"]:
		_fill(_ground(green["poly"]), GREEN, GREEN_EDGE)
	var buildings: Array[Dictionary] = []
	for plot: Dictionary in _block["plots"]:
		if plot["cat"] == "empty" or float(plot["height_m"]) <= 0.0:
			_draw_lot(plot)
		else:
			buildings.append(plot)
	for plot in buildings:
		_draw_shadow(plot)
	# painter's order: the far side (small u + v) first; footprints never overlap, so this is close
	# enough for a sanity view
	buildings.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _depth(a) < _depth(b))
	for plot in buildings:
		_draw_building(plot)


# --- ground ------------------------------------------------------------------------------------

func _draw_ground() -> void:
	var c := _corners()
	# the two earth faces the viewer can see: the +u side (x max) and the +v side (y min)
	_quad(c[1], c[2], 0.0, -SLAB_DEPTH, EARTH_LIT)
	_quad(c[0], c[1], 0.0, -SLAB_DEPTH, EARTH_DARK)
	_fill(_ground_pts(c), PAVING, Color(0, 0, 0, 0))
	# a sparse dot pattern on the pavement, so big plazas do not read as flat colour
	var y := _slab.position.y + 2.0
	while y < _slab.end.y:
		var x := _slab.position.x + fmod(y, 4.0)
		while x < _slab.end.x:
			draw_rect(Rect2(_p(x, y, 0.0).floor(), Vector2.ONE), PAVING_DOT)
			x += 4.0
		y += 3.0


func _road_quad(road: Dictionary) -> PackedVector2Array:
	var line := _points(road["line"])
	var a := line[0]
	var b := line[line.size() - 1]
	var side := (b - a).normalized().orthogonal() * float(road["width"]) * 0.5
	return _ground_pts(PackedVector2Array([a + side, b + side, b - side, a - side]))


# lane dashes down each street, left out where another street crosses
func _draw_marks() -> void:
	var roads: Array = _block["roads"]
	for road: Dictionary in roads:
		var line := _points(road["line"])
		var a := line[0]
		var b := line[line.size() - 1]
		var step := (b - a).normalized()
		var d := 0.0
		while d < a.distance_to(b) - 3.0:
			var p := a + step * d
			var clear := true
			for other: Dictionary in roads:
				if other == road:
					continue
				var o := _points(other["line"])
				var near := Geometry2D.get_closest_point_to_segment(p, o[0], o[o.size() - 1])
				if near.distance_to(p) < float(other["width"]) * 0.5 + 3.0:
					clear = false
					break
			if clear:
				var q := p + step * 3.0
				draw_line(_p(p.x, p.y, 0.0), _p(q.x, q.y, 0.0), MARK)
			d += 8.0


# an empty plot: bare dirt with a yellow "for sale" sign in the middle
func _draw_lot(plot: Dictionary) -> void:
	var poly := _points(plot["poly"])
	_fill(_ground_pts(poly), DIRT, DIRT_EDGE)
	var mid := _centre(poly)
	var foot := _p(mid.x, mid.y, 0.0).floor()
	draw_rect(Rect2(foot + Vector2(0, -5), Vector2(1, 5)), POST)
	draw_rect(Rect2(foot + Vector2(-3, -9), Vector2(7, 4)), SIGN)


# a cheap cast shadow: the footprint slid toward the viewer's left, in see-through dark
func _draw_shadow(plot: Dictionary) -> void:
	var reach := float(plot["height_m"]) * 0.35
	var pts := PackedVector2Array()
	for p: Vector2 in _points(plot["poly"]):
		pts.append(_p(p.x - reach, p.y + reach * 0.2, 0.0))
	_fill(pts, SHADOW, Color(0, 0, 0, 0))


# --- buildings ---------------------------------------------------------------------------------

func _draw_building(plot: Dictionary) -> void:
	var id: String = plot["id"]
	var cat: String = plot["cat"]
	var poly := _points(plot["poly"])
	var top := float(plot["height_m"])
	var floors := maxi(1, int(plot["levels"]))
	var facades: Array = FACADE.get(cat, FACADE["residential"])
	var roofs: Array = ROOF.get(cat, ROOF["residential"])
	var wall := Color(facades[int(_h01(id + "f") * facades.size())])
	var roof := Color(roofs[int(_h01(id + "r") * roofs.size())])
	_extrude(poly, 0.0, top, wall, roof, id, floors, cat)
	# one or two stairwell huts on bigger roofs, like the Eixample's rooftop "casetes"
	var area := absf(_area(poly))
	if area < 140.0:
		return
	var mid := _centre(poly)
	var spread := minf(10.0, sqrt(area) * 0.4)
	for k in 1 + int(_h01(id + "n") * 2.0):
		var at := mid + Vector2(_h01(id + "x%d" % k) - 0.5, _h01(id + "y%d" % k) - 0.5) * spread
		var half := 1.25 + _h01(id + "w%d" % k) * 1.25
		var hut := PackedVector2Array([at + Vector2(-half, -half), at + Vector2(half, -half),
			at + Vector2(half, half), at + Vector2(-half, half)])
		var inside := true
		for c: Vector2 in hut:
			inside = inside and Geometry2D.is_point_in_polygon(c, poly)
		if inside:
			_extrude(hut, top, top + 2.2, PROP_WALL, PROP_ROOF, "", 0, "")


# walls that face the viewer, shaded by which way they face, with a window grid on real
# buildings (floors > 0), then the flat roof with a darker parapet line
func _extrude(poly: PackedVector2Array, z0: float, z1: float, wall: Color, roof: Color,
		id: String, floors: int, cat: String) -> void:
	var ccw := _area(poly) > 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		# outward normal in (u, v) = (x, -y) space; the viewer sits toward +u +v
		var du := b.x - a.x
		var dv := -(b.y - a.y)
		var n := (Vector2(dv, -du) if ccw else Vector2(-dv, du)).normalized()
		if n.x + n.y <= 0.001:
			continue
		var light := lerpf(SHADE_LEFT, 1.0, clampf((n.x - n.y + 1.0) * 0.5, 0.0, 1.0))
		var face := _lit(wall, light)
		_quad(a, b, z1, z0, face)
		draw_line(_p(a.x, a.y, z0), _p(b.x, b.y, z0), _lit(face, 0.55))
		if floors > 0:
			_windows(a, b, z0, z1, floors, light, id + str(i), cat)
			draw_line(_p(a.x, a.y, z1 - 0.6), _p(b.x, b.y, z1 - 0.6), _lit(face, 0.82))
	var lid := PackedVector2Array()
	for p: Vector2 in poly:
		lid.append(_p(p.x, p.y, z1))
	_fill(lid, roof, _lit(roof, 0.72))


func _windows(a: Vector2, b: Vector2, z0: float, z1: float, floors: int, light: float,
		seed: String, cat: String) -> void:
	var length := a.distance_to(b)
	var tall := (z1 - z0) / floors
	if length < 3.0 or tall * RISE < 2.0:
		return
	var count := maxi(1, int(length / WINDOW_EVERY_M))
	# shops and homes get dark shop fronts at street level, offices and civic buildings glass
	var street := SHOP if cat in ["commercial", "residential", "hotel"] else GLASS
	for f in floors:
		var z := z0 + f * tall + tall * 0.35
		for k in count:
			var at := a.lerp(b, (k + 0.5) / count)
			var spot := _p(at.x, at.y, z).floor()
			if f == 0:
				var h := maxf(1.0, floorf(tall * RISE * 0.75))
				draw_rect(Rect2(spot - Vector2(0, h), Vector2(2, h)), _lit(street, light))
			else:
				var h := maxf(1.0, floorf(tall * RISE * 0.6))
				var glass := GLASS_LIT if _h01(seed + "%d_%d" % [f, k]) < LIT_SHARE else GLASS
				draw_rect(Rect2(spot - Vector2(0, h), Vector2(1, h)), _lit(glass, light))


# --- helpers -----------------------------------------------------------------------------------

# the iso projection: u = x, v = -y; +u goes right-down on screen, +v left-down, z straight up
func _raw(x: float, y: float, z: float) -> Vector2:
	var u := x
	var v := -y
	return Vector2((u - v) * SCALE, (u + v) * SCALE * 0.5 - z * RISE)


func _p(x: float, y: float, z: float) -> Vector2:
	return _raw(x, y, z) + _origin


func _depth(plot: Dictionary) -> float:
	var c := _centre(_points(plot["poly"]))
	return c.x - c.y


func _corners() -> PackedVector2Array:
	var s := _slab
	return PackedVector2Array([s.position, Vector2(s.end.x, s.position.y), s.end,
		Vector2(s.position.x, s.end.y)])


func _points(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Array in raw:
		out.append(Vector2(p[0], p[1]))
	return out


func _ground(raw: Array) -> PackedVector2Array:
	return _ground_pts(_points(raw))


func _ground_pts(poly: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector2 in poly:
		out.append(_p(p.x, p.y, 0.0))
	return out


# a vertical face between two ground points, from height z_top down to z_bottom
func _quad(a: Vector2, b: Vector2, z_top: float, z_bottom: float, color: Color) -> void:
	_fill(PackedVector2Array([_p(a.x, a.y, z_bottom), _p(b.x, b.y, z_bottom), _p(b.x, b.y, z_top),
		_p(a.x, a.y, z_top)]), color, Color(0, 0, 0, 0))


# a filled polygon with an optional 1 px edge; skips shapes that collapse to nothing on screen,
# because Godot reports an error for a polygon it cannot triangulate
func _fill(pts: PackedVector2Array, color: Color, edge: Color) -> void:
	if pts.size() < 3 or Geometry2D.triangulate_polygon(pts).is_empty():
		return
	draw_colored_polygon(pts, color)
	if edge.a > 0.0:
		var ring := pts.duplicate()
		ring.append(pts[0])
		draw_polyline(ring, edge)


func _area(poly: PackedVector2Array) -> float:
	var sum := 0.0
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		sum += a.x * -b.y - b.x * -a.y
	return sum * 0.5


func _centre(poly: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for p: Vector2 in poly:
		sum += p
	return sum / poly.size()


func _lit(color: Color, light: float) -> Color:
	return Color(color.r * light, color.g * light, color.b * light, color.a)


# a stable 0..1 hash, so the same plot always gets the same colours and lit windows
func _h01(key: String) -> float:
	return float(key.hash() & 0xFFFF) / 65536.0
