class_name BlockView
extends Node2D

# Draws one baked office area (format tiny-realestate-block v2, see BlockBaker) as isometric
# pixel art, once: a round diorama of the real streets, with the city blocks between them cut
# into plots. Empty plots are bare lots; pre-built ones get procedural buildings by tier and
# zone (never real footprints). Ground coordinates are metres, x east and y north, already
# turned so the streets run along the axes. The drawing is meant for a low-res SubViewport that
# the caller scales up with nearest filtering, so every primitive here is plain and unsmoothed.
# When `active_radius` is set, everything outside it is dimmed and a gold ring marks the edge:
# the part of the download the office can use yet.

# low-res pixels per metre; the prototype found this shows about one and a half manzanas in 600 px
const SCALE := 1.35
# a touch below SCALE, so towers read tall without looking stretched
const RISE := SCALE * 0.95
const PAD := 10.0
# how deep the earth slab under the block goes, in metres, for the floating-diorama look
const SLAB_DEPTH := 9.0
const DISC_SIDES := 96
const FLOOR_M := 3.2
const WINDOW_EVERY_M := 3.6
const LIT_SHARE := 0.12
# walls facing the viewer's right get full light, the ones facing left this much of it
const SHADE_LEFT := 0.78
# how close (m) a lane dash may come to a junction
const DASH_CLEAR := 14.0

const PAVING := Color("#cfc6b4")
const PAVING_DOT := Color("#c4bba8")
const PLAZA := Color("#ddd3bf")
const CURB := Color("#a39a88")
const ASPHALT := Color("#5b5d66")
const ASPHALT_MINOR := Color("#6c6e77")
const MARK := Color("#e8e2cf")
const GREEN := Color("#6f9e4c")
const GREEN_EDGE := Color("#5d8a40")
const PITCH := Color("#7fb35a")
const WOOD := Color("#4f8040")
const SAND := Color("#e3d29a")
const WATER := Color("#4d86b8")
const WATER_EDGE := Color("#3d6f9c")
const DIRT := Color("#b08d5e")
const DIRT_EDGE := Color("#9f7e52")
const BLOCK := Color("#a99f78")
const COURT := Color("#86a85a")
const RAIL_BED := Color("#8a7f73")
const RAIL := Color("#3c3a40")
# empty lots by zone: dirt for homes, sand for shops, gravel for industry
const LOT := {"residential": Color("#b8936a"), "commercial": Color("#cdb685"),
	"industrial": Color("#9c968a")}
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
const OFFICE_WALL := Color("#f4f1ea")
const OFFICE_ROOF := Color("#f0b429")
const OFFICE_FLAG := Color("#e5534b")
# the share of empty plots with a "for sale" sign: enough to read as buildable, not a forest
const SIGN_EVERY := 0.18
# a building stands this far (m) inside its plot's edges
const SETBACK := 1.2
const RING := Color("#ffd84a")
# outside the active radius: ground under a dark veil, buildings faded toward this haze
const VEIL := Color(0.08, 0.07, 0.16, 0.42)
const HAZE := Color("#6d6a80")
const HAZE_MIX := 0.55
# roof and facade colours by plot category, so the type of each plot reads at a glance
const ROOF := {
	"residential": ["#c9714b", "#d08355", "#bd6644"], "commercial": ["#4f86b8", "#5a93c4"],
	"office": ["#7d8aa3", "#8a97ae"], "hotel": ["#9a6bb0"], "civic": ["#d9c27a"],
	"industrial": ["#8f9499", "#9aa0a4"], "utility": ["#a8a29a"],
}
const FACADE := {
	"residential": ["#e6d3ad", "#dcc39a", "#e9c9a4", "#d8b892", "#e3dccb", "#d9a98a"],
	"commercial": ["#c9d3dc", "#b9c6d2"], "office": ["#aeb7c4", "#c0c6cf"], "hotel": ["#e2d2e6"],
	"civic": ["#e4d7b0"], "industrial": ["#b9b6ae", "#c4c0b6"], "utility": ["#cfc9be"],
}
const GREEN_TONE := {"pitch": PITCH, "playground": PITCH, "golf_course": PITCH, "forest": WOOD,
	"wood": WOOD, "scrub": WOOD, "sand": SAND}

# pixel size of the whole drawing, for the SubViewport that holds it
var size := Vector2.ZERO
# where ground point (0, 0) lands in the drawing, so the caller can centre the view on it
var focus := Vector2.ZERO
# metres around (0, 0) the office can use; 0 draws everything at full colour
var active_radius := 0.0

var _block: Dictionary = {}
var _origin := Vector2.ZERO
var _slab := Rect2()
var _radius := 0.0
# set per building while it draws: how far it is faded toward HAZE
var _haze := 0.0


func load_block(path: String) -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("BlockView: cannot read block file " + path)
		return false
	return set_block(parsed)


func set_block(block: Dictionary) -> bool:
	if int(block.get("format_version", 0)) < 2:
		push_error("BlockView: only format v2 blocks are drawn")
		return false
	_block = block
	_radius = float(_block["radius_m"])
	_slab = Rect2(-_radius, -_radius, _radius * 2.0, _radius * 2.0)
	var edge := Geo.circle(_radius, DISC_SIDES)
	var tallest := 12.0
	for plot: Dictionary in _block["plots"]:
		tallest = maxf(tallest, _height(plot) + 30.0)
	var box := Rect2(_raw(edge[0].x, edge[0].y, 0.0), Vector2.ZERO)
	for c: Vector2 in edge:
		box = box.expand(_raw(c.x, c.y, 0.0)).expand(_raw(c.x, c.y, tallest))
		box = box.expand(_raw(c.x, c.y, -SLAB_DEPTH))
	_origin = (Vector2(PAD, PAD) - box.position).round()
	size = (box.size + Vector2(PAD, PAD) * 2.0).ceil()
	focus = _p(0.0, 0.0, 0.0)
	queue_redraw()
	return true


# where a ground point (metres) lands in the drawing, for labels drawn over it
func project(m: Vector2) -> Vector2:
	return _p(m.x, m.y, 0.0)


# street name labels: for each name, spots on its longest straight stretches at least 160 m
# apart, with the on-screen direction of the street there; the caller drops the overlaps
func street_labels() -> Array[Dictionary]:
	var by_name := {}
	for road: Dictionary in _block["roads"]:
		var name: String = road["name"] if road["name"] != "" else road.get("ref", "")
		if name == "" or road["kind"] in ["motorway", "trunk"] and road["name"] == "":
			continue
		var line := _points(road["line"])
		for i in range(1, line.size()):
			if not by_name.has(name):
				by_name[name] = []
			by_name[name].append([line[i - 1], line[i]])
	var out: Array[Dictionary] = []
	for name: String in by_name:
		var segs: Array = by_name[name]
		segs.sort_custom(func(a: Array, b: Array) -> bool:
			return a[0].distance_to(a[1]) > b[0].distance_to(b[1]))
		var spots := PackedVector2Array()
		for seg: Array in segs:
			var a: Vector2 = seg[0]
			var b: Vector2 = seg[1]
			if a.distance_to(b) < 35.0:
				break
			var mid := (a + b) * 0.5
			if mid.length() > _radius - 15.0:
				continue
			var far := true
			for q in spots:
				far = far and q.distance_to(mid) > 160.0
			if not far:
				continue
			spots.append(mid)
			var d := project(b) - project(a)
			var angle := d.angle()
			if angle > PI * 0.5:
				angle -= PI
			elif angle < -PI * 0.5:
				angle += PI
			out.append({"text": name, "at": project(mid), "angle": angle,
				"room": project(a).distance_to(project(b))})
	return out


func _draw() -> void:
	if _block.is_empty():
		return
	_draw_ground()
	for w: Dictionary in _block["water"]:
		_fill(_ground(w["poly"]), WATER, WATER_EDGE)
	for l: Dictionary in _block["land"]:
		_fill(_ground(l["poly"]), PAVING, CURB)
	# parks first: a street through a park is drawn over it
	for green: Dictionary in _block["greens"]:
		var tone: Color = GREEN_TONE.get(green["kind"], GREEN)
		_fill(_ground(green["poly"]), tone, tone.darkened(0.15))
	_draw_roads()
	_draw_rails()
	for b: Dictionary in _block["blocks"]:
		_fill(_ground(b["poly"]), BLOCK, BLOCK.darkened(0.12))
	for c: Dictionary in _block["courts"]:
		_fill(_ground(c["poly"]), COURT, COURT.darkened(0.1))
	var office: String = _block.get("office_plot", "")
	var built: Array[Dictionary] = []
	for plot: Dictionary in _block["plots"]:
		if int(plot["built_tier"]) > 0 or plot["id"] == office:
			built.append(plot)
		_draw_lot(plot)
	for plot in built:
		_draw_shadow(plot)
	if active_radius > 0.0:
		_draw_veil()
	# painter's order: the far side (small u + v) first; plots never overlap, so this is close
	# enough
	built.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _depth(a) < _depth(b))
	var has_office := false
	for plot in built:
		var mid := _centre(_points(plot["poly"]))
		_haze = HAZE_MIX if active_radius > 0.0 and mid.length() > active_radius else 0.0
		if plot["id"] == office:
			_draw_office(plot)
			has_office = true
		else:
			_draw_building(plot)
	_haze = 0.0
	if not has_office:
		_draw_kiosk()


func _height(plot: Dictionary) -> float:
	var levels := int(plot.get("levels", 0))
	return levels * FLOOR_M + 1.0 if levels > 0 else 0.0


# a plot's building footprint: the plot pulled in by the setback (the biggest piece left)
func _footprint(plot: Dictionary) -> PackedVector2Array:
	var poly := _points(plot["poly"])
	var best := PackedVector2Array()
	for part: PackedVector2Array in Geometry2D.offset_polygon(poly, -SETBACK):
		if absf(_area(part)) > absf(_area(best)):
			best = part
	return best if best.size() >= 3 else poly


# --- ground ------------------------------------------------------------------------------------

func _draw_ground() -> void:
	var edge := Geo.circle(_radius, DISC_SIDES)
	# the earth faces the viewer can see, shaded like walls
	for i in edge.size():
		var a := edge[i]
		var b := edge[(i + 1) % edge.size()]
		var nu := Vector2(b.y - a.y, b.x - a.x).normalized()
		if nu.x + nu.y <= 0.0:
			continue
		var light := clampf((nu.x - nu.y + 1.0) * 0.5, 0.0, 1.0)
		_quad(a, b, 0.0, -SLAB_DEPTH, EARTH_DARK.lerp(EARTH_LIT, light))
	_fill(_ground_pts(edge), PAVING, Color(0, 0, 0, 0))
	# a sparse dot pattern on the pavement, so big plazas do not read as flat colour
	var r2 := _radius * _radius
	var y := _slab.position.y + 2.0
	while y < _slab.end.y:
		var x := _slab.position.x + fmod(absf(y), 4.0)
		while x < _slab.end.x:
			if x * x + y * y < r2:
				draw_rect(Rect2(_p(x, y, 0.0).floor(), Vector2.ONE), PAVING_DOT)
			x += 4.0
		y += 3.0


# curbs first (each road a little wider, in curb colour), then all the asphalt over them, so
# junctions merge cleanly; then lane dashes on the wide roads
func _draw_roads() -> void:
	var roads: Array = _block["roads"]
	var order := roads.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _road_rank(a) < _road_rank(b))
	for road: Dictionary in order:
		_road_shape(road, float(road["width"]) * 0.5 + 0.8, CURB)
	for road: Dictionary in order:
		var kind: String = road["kind"]
		var tone := PLAZA if kind == "pedestrian" else (ASPHALT_MINOR
			if kind in ["service", "living_street"] else ASPHALT)
		_road_shape(road, float(road["width"]) * 0.5, tone)
	_draw_marks(roads)


func _road_rank(road: Dictionary) -> int:
	match road["kind"]:
		"pedestrian":
			return 0
		"service", "living_street":
			return 1
	return 2


# a road's centre line widened by `half` metres; a closed loop (a roundabout) comes back with
# its hole, which is painted back as pavement
func _road_shape(road: Dictionary, half: float, color: Color) -> void:
	var line := _points(road["line"])
	if line.size() < 2:
		return
	var parts := Geometry2D.offset_polyline(line, half, Geometry2D.JOIN_ROUND,
		Geometry2D.END_ROUND)
	if parts.is_empty():
		return
	var outer_cw := Geometry2D.is_polygon_clockwise(parts[0])
	var biggest := 0.0
	for part: PackedVector2Array in parts:
		var a := absf(Geo.area(part))
		if a > biggest:
			biggest = a
			outer_cw = Geometry2D.is_polygon_clockwise(part)
	var holes: Array[PackedVector2Array] = []
	for part: PackedVector2Array in parts:
		if Geometry2D.is_polygon_clockwise(part) != outer_cw:
			holes.append(part)
			continue
		for piece in _in_disc(part):
			_fill(_ground_pts(piece), color, Color(0, 0, 0, 0))
	for hole in holes:
		_fill(_ground_pts(hole), PAVING, Color(0, 0, 0, 0))


# lane dashes down each wide street, left out near junctions (vertices two roads share)
func _draw_marks(roads: Array) -> void:
	var seen := {}
	for road: Dictionary in roads:
		var mine := {}
		for p: Vector2 in _points(road["line"]):
			mine[Vector2i(roundi(p.x * 2.0), roundi(p.y * 2.0))] = p
		for key: Vector2i in mine:
			seen[key] = seen.get(key, 0) + 1
	var junctions := {}
	for key: Vector2i in seen:
		if seen[key] >= 2:
			var p := Vector2(key) * 0.5
			var cell := Vector2i(floori(p.x / 16.0), floori(p.y / 16.0))
			if not junctions.has(cell):
				junctions[cell] = PackedVector2Array()
			junctions[cell].append(p)
	for road: Dictionary in roads:
		if float(road["width"]) < 12.0 or road["kind"] == "pedestrian":
			continue
		var line := _points(road["line"])
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			var step := (b - a).normalized()
			var d := 2.0
			while d < a.distance_to(b) - 3.0:
				var p := a + step * d
				d += 8.0
				if _radius > 0.0 and p.length() > _radius - 4.0:
					continue
				if _near_junction(p, junctions):
					continue
				var q := p + step * 3.0
				draw_line(_p(p.x, p.y, 0.0), _p(q.x, q.y, 0.0), MARK)


func _near_junction(p: Vector2, junctions: Dictionary) -> bool:
	var cell := Vector2i(floori(p.x / 16.0), floori(p.y / 16.0))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for j: Vector2 in junctions.get(cell + Vector2i(dx, dy), PackedVector2Array()):
				if j.distance_to(p) < DASH_CLEAR:
					return true
	return false


# every plot's ground: an empty one is a bare lot (some with a "for sale" sign), a built one
# the same ground its building stands on
func _draw_lot(plot: Dictionary) -> void:
	var poly := _points(plot["poly"])
	var tone: Color = LOT.get(plot["zone"], DIRT)
	_fill(_ground_pts(poly), tone, tone.darkened(0.13))
	if int(plot["built_tier"]) > 0 or _h01(plot["id"] + "sign") > SIGN_EVERY:
		return
	var mid := _centre(poly)
	if active_radius > 0.0 and mid.length() > active_radius:
		return
	var foot := _p(mid.x, mid.y, 0.0).floor()
	draw_rect(Rect2(foot + Vector2(0, -5), Vector2(1, 5)), POST)
	draw_rect(Rect2(foot + Vector2(-3, -9), Vector2(7, 4)), SIGN)


# a cheap cast shadow: the footprint slid toward the viewer's left, in see-through dark
func _draw_shadow(plot: Dictionary) -> void:
	var reach := minf(_height(plot) * 0.35, 40.0)
	var pts := PackedVector2Array()
	for p: Vector2 in _footprint(plot):
		pts.append(_p(p.x - reach, p.y + reach * 0.2, 0.0))
	_fill(pts, SHADOW, Color(0, 0, 0, 0))


# railways: a gravel bed with the track down the middle and a sleeper every few metres
func _draw_rails() -> void:
	for rail: Dictionary in _block["rails"]:
		var line := _points(rail["line"])
		var tram: bool = rail["kind"] == "tram"
		if not tram:
			for part: PackedVector2Array in Geometry2D.offset_polyline(line, 3.0):
				for piece in _in_disc(part):
					_fill(_ground_pts(piece), RAIL_BED, Color(0, 0, 0, 0))
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			draw_line(_p(a.x, a.y, 0.0), _p(b.x, b.y, 0.0), RAIL)
			if tram:
				continue
			var side := (b - a).normalized().orthogonal() * 1.6
			var d := 0.0
			while d < a.distance_to(b):
				var c := a.lerp(b, d / a.distance_to(b))
				draw_line(_p(c.x - side.x, c.y - side.y, 0.0), _p(c.x + side.x, c.y + side.y, 0.0),
					RAIL)
				d += 3.0


# the ground outside the active radius under a dark veil, and a dashed gold ring on its edge
func _draw_veil() -> void:
	var inner := Geo.circle(active_radius, DISC_SIDES)
	var outer := Geo.circle(_radius + 1.0, DISC_SIDES)
	for i in DISC_SIDES:
		var j := (i + 1) % DISC_SIDES
		_fill(_ground_pts(PackedVector2Array([outer[i], outer[j], inner[j], inner[i]])), VEIL,
			Color(0, 0, 0, 0))
	for i in DISC_SIDES:
		if i % 2 == 0:
			var a := inner[i]
			var b := inner[(i + 1) % DISC_SIDES]
			draw_line(_p(a.x, a.y, 0.0), _p(b.x, b.y, 0.0), RING, 2.0)


# --- buildings ---------------------------------------------------------------------------------

func _draw_building(plot: Dictionary) -> void:
	var id: String = plot["id"]
	var cat: String = plot["zone"]
	var poly := _footprint(plot)
	var top := _height(plot)
	var floors := maxi(1, int(plot["levels"]))
	var facades: Array = FACADE.get(cat, FACADE["residential"])
	var roofs: Array = ROOF.get(cat, ROOF["residential"])
	var wall := Color(facades[int(_h01(id + "f") * facades.size())])
	var roof := Color(roofs[int(_h01(id + "r") * roofs.size())])
	_extrude(poly, 0.0, top, wall, roof, id, floors, cat)
	# one or two stairwell huts on bigger roofs, like the Eixample's rooftop "casetes"
	var area := absf(_area(poly))
	if area < 140.0 or area > 4000.0:
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


# the player's office: white walls, a gold roof, and a red flag with a gold pin floating above,
# so it is the first thing the eye finds
func _draw_office(plot: Dictionary) -> void:
	var poly := _footprint(plot)
	var top := _height(plot)
	_extrude(poly, 0.0, top, OFFICE_WALL, OFFICE_ROOF, plot["id"], maxi(1, int(plot["levels"])),
		"office")
	var mid := _centre(poly)
	_flag(_p(mid.x, mid.y, top))


# when the clicked spot has no building near it, a small kiosk stands in for the office
func _draw_kiosk() -> void:
	var hut := PackedVector2Array([Vector2(-4, -4), Vector2(4, -4), Vector2(4, 4), Vector2(-4, 4)])
	_extrude(hut, 0.0, 7.4, OFFICE_WALL, OFFICE_ROOF, "kiosk", 2, "office")
	_flag(_p(0.0, 0.0, 7.4))


func _flag(at: Vector2) -> void:
	var foot := at.floor()
	draw_rect(Rect2(foot + Vector2(0, -16), Vector2(1, 16)), POST)
	draw_rect(Rect2(foot + Vector2(1, -16), Vector2(9, 6)), OFFICE_FLAG)
	draw_rect(Rect2(foot + Vector2(1, -16), Vector2(9, 6)), OFFICE_FLAG.darkened(0.3), false)
	# the pin: a gold arrow pointing down at the building
	var tip := foot + Vector2(0, -21)
	draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-6, -8), tip + Vector2(6, -8)]),
		RING)
	draw_polyline(PackedVector2Array([tip, tip + Vector2(-6, -8), tip + Vector2(6, -8), tip]),
		RING.darkened(0.45))


# walls that face the viewer, shaded by which way they face, with a window grid on real
# buildings (floors > 0), then the flat roof with a darker parapet line
func _extrude(poly: PackedVector2Array, z0: float, z1: float, wall: Color, roof: Color,
		id: String, floors: int, cat: String) -> void:
	# counter-clockwise in (u, v) space, which flips y, is clockwise in ground metres
	var ccw := _area(poly) < 0.0
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
		draw_line(_p(a.x, a.y, z0), _p(b.x, b.y, z0), _lit(wall, light * 0.55))
		if floors > 0:
			_windows(a, b, z0, z1, floors, light, id + str(i), cat)
			draw_line(_p(a.x, a.y, z1 - 0.6), _p(b.x, b.y, z1 - 0.6), _lit(wall, light * 0.82))
	var lid := PackedVector2Array()
	for p: Vector2 in poly:
		lid.append(_p(p.x, p.y, z1))
	_fill(lid, _lit(roof, 1.0), _lit(roof, 0.72))


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
				var lit := _haze == 0.0 and _h01(seed + "%d_%d" % [f, k]) < LIT_SHARE
				draw_rect(Rect2(spot - Vector2(0, h), Vector2(1, h)),
					_lit(GLASS_LIT if lit else GLASS, light))


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


# a ground polygon cut to the disc (roads stick out by half their width at the edge)
func _in_disc(poly: PackedVector2Array) -> Array[PackedVector2Array]:
	var r2 := _radius * _radius
	for p in poly:
		if p.length_squared() > r2:
			return Geo.clip(poly, Geo.circle(_radius, DISC_SIDES))
	return [poly]


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
	return Geo.area(poly)


func _centre(poly: PackedVector2Array) -> Vector2:
	return Geo.centre(poly)


# a colour in a given light, faded toward the haze for buildings outside the active radius
func _lit(color: Color, light: float) -> Color:
	var c := Color(color.r * light, color.g * light, color.b * light, color.a)
	return c.lerp(Color(HAZE, c.a), _haze) if _haze > 0.0 else c


# a stable 0..1 hash, so the same plot always gets the same colours and lit windows
func _h01(key: String) -> float:
	return float(key.hash() & 0xFFFF) / 65536.0
