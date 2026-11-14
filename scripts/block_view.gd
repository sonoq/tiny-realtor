class_name BlockView
extends Node2D

# Draws one baked office area (format tiny-realestate-block v3, see BlockBaker) once, as style A
# isometric pixel art (docs/style_mockups/a_battlegrounds), into `texture`; `drawn` fires when it
# is ready. The caller shows the texture scaled up with nearest filtering and pans it; nothing is
# redrawn per frame. AreaBuilder turns the area into ops in low-res pixels (Iso.S per metre),
# then three passes on the GPU, each read back once:
#   1. ground: palette indices of everything flat, and the cast-shadow mask
#   2. world:  the ground through WorldShader's ground shader (pavement tiles, kerbs, shadows, the
#              dim outside the active radius), the slab and the gold ring, then every object in
#              DepthSort's painter order, each outlined in ink, faded when outside the radius,
#              walls painted by the facade shader; price tags on top
#   3. pick:   alongside the ground pass, each lot's ground and then its buildings in painter's
#              order, all in the lot's number (red + green * 256 = lot + 1), kept as an Image:
#              what the player points at is whatever lot is drawn there, a tower's roof included
#   4. depth:  alongside too, every object in painter's order again, each pixel holding the depth
#              (x - y of the ground point under it, see depth_code) of what is drawn there, and
#              price tags as nearest of all; kept as `depth_tex` with the shadow mask
#              (`shade_tex`), so Traffic's moving cars hide behind whatever stands in front
# Every pixel is a palette colour: no blending anywhere (render_mode blend_disabled).

signal drawn

const PAD := 12.0
const DIRS: Array[Vector2] = [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]
enum { MODE_GROUND, MODE_SHADOW, MODE_WORLD, MODE_PICK, MODE_DEPTH }
# the depth image's code: (depth + DEPTH_BIAS) * DEPTH_K in red + green * 256; 0 = bare ground,
# DEPTH_TOP = in front of everything (price tags)
const DEPTH_BIAS := 1024.0
const DEPTH_K := 16.0
const DEPTH_TOP := 65535
# the depth handed to the depth pass for what stands in front of everything
const DEPTH_FRONT := 1.0e5

# pixel size of the whole drawing
var size := Vector2.ZERO
# where ground point (0, 0), the office, lands in the drawing
var focus := Vector2.ZERO
# metres around (0, 0) the office can use; 0 draws everything at full colour
var active_radius := 0.0
# the finished drawing, null until `drawn`
var texture: Texture2D
# drawing positions over the roofs the player owns, for income pops
var pops: Array[Vector2] = []
# the office's REALTOR sign in the drawing, which labels keep clear of
var sign_box := Rect2()
# the lots as AreaBuilder laid them out ("data", "poly", "screen", "box", "active")
var lots: Array[Dictionary] = []
# the pick pass: which lot each pixel of the drawing shows, null until `drawn`
var pick: Image
# milliseconds spent building the ops and on the GPU passes, for the logs
var build_ms := 0
var draw_ms := 0
# the depth pass and the cast-shadow mask, for what is drawn live over the drawing; null until
# `drawn`
var depth_tex: Texture2D
var shade_tex: Texture2D

var _block: Dictionary = {}
var _radius := 0.0
var _iso: Iso
var _area: AreaBuilder
var _pick_bytes := PackedByteArray()
# lot -> its outline as runs of drawing pixels: [next to it, one further out]
var _outlines := {}


func load_block(path: String) -> bool:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not parsed is Dictionary:
		push_error("BlockView: cannot read block file " + path)
		return false
	return set_block(parsed)


func set_block(block: Dictionary) -> bool:
	if int(block.get("format_version", 0)) < 3:
		push_error("BlockView: only format v3 areas are drawn (BlockBaker.upgrade older ones)")
		return false
	var t0 := Time.get_ticks_msec()
	_block = block
	_radius = float(block["radius_m"])
	_iso = Iso.new()
	# the bounds need the tallest building before anything is placed
	var tallest := 60.0
	for plot: Dictionary in block["plots"]:
		tallest = maxf(tallest, AreaBuilder.top_of(int(plot["built_tier"]),
			int(plot.get("levels", 0))))
	var box := Rect2(_iso.p(_radius, 0.0), Vector2.ZERO)
	for c: Vector2 in Geo.circle(_radius, 96):
		box = box.expand(_iso.p(c.x, c.y, tallest)).expand(_iso.p(c.x, c.y,
			-AreaBuilder.SLAB_DEPTH - 2.0))
	_iso.origin = (Vector2(PAD, PAD) - box.position).round()
	size = (box.size + Vector2(PAD, PAD) * 2.0).ceil()
	focus = _iso.p(0.0, 0.0)
	_area = AreaBuilder.new(_iso, block, active_radius)
	_area.build()
	_area.objects = DepthSort.order(_area.objects)
	pops = _area.pops
	lots = _area.lots
	if not _area.keep_clear.is_empty():
		sign_box = _area.keep_clear[0]
	build_ms = Time.get_ticks_msec() - t0
	return true


func _ready() -> void:
	if _area != null:
		_render()


func _render() -> void:
	var t0 := Time.get_ticks_msec()
	var vs := Vector2i(size)
	var g := _viewport(vs, _canvas(MODE_GROUND))
	var s := _viewport(vs, _canvas(MODE_SHADOW))
	var p := _viewport(vs, _canvas(MODE_PICK))
	var depth := _canvas(MODE_DEPTH)
	depth.material = _depth_material()
	var d := _viewport(vs, depth)
	await RenderingServer.frame_post_draw
	var ground := ImageTexture.create_from_image(g.get_texture().get_image())
	var shade := ImageTexture.create_from_image(s.get_texture().get_image())
	pick = p.get_texture().get_image()
	_pick_bytes = pick.get_data()
	depth_tex = ImageTexture.create_from_image(d.get_texture().get_image())
	shade_tex = shade
	g.queue_free()
	s.queue_free()
	p.queue_free()
	d.queue_free()
	var under := Sprite2D.new()
	under.centered = false
	under.texture = ground
	under.material = WorldShader.ground_material(ground, shade, focus, Iso.S,
		active_radius if active_radius > 0.0 else 1.0e9)
	var world := _canvas(MODE_WORLD)
	world.material = WorldShader.facade_material(Sprites.atlas())
	var w := _viewport(vs, under)
	w.add_child(world)
	await RenderingServer.frame_post_draw
	texture = ImageTexture.create_from_image(w.get_texture().get_image())
	w.queue_free()
	_area = null
	draw_ms = Time.get_ticks_msec() - t0
	drawn.emit()


func _viewport(vs: Vector2i, child: Node) -> SubViewport:
	var vp := SubViewport.new()
	vp.disable_3d = true
	vp.transparent_bg = true
	vp.size = vs
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.add_child(child)
	add_child(vp)
	return vp


static var _depth_shader: Shader


# writes each pixel's depth code: from UV.x on polygons and walls, from the colour on sprites
# (whose clear pixels are skipped, as in the world pass)
static func _depth_material() -> ShaderMaterial:
	if _depth_shader == null:
		_depth_shader = Shader.new()
		_depth_shader.code = """shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D sprites : filter_nearest;
void fragment() {
	if (UV.x >= 4000.0 && UV.x < 8000.0) {
		if (texelFetch(sprites, ivec2(floor(UV - vec2(4096.0, 0.0))), 0).a < 0.5) discard;
		COLOR = vec4(COLOR.rgb, 1.0);
	} else {
		float q = clamp(floor((UV.x + %.1f) * %.1f + 0.5), 1.0, 65534.0);
		COLOR = vec4(mod(q, 256.0) / 255.0, floor(q / 256.0) / 255.0, 0.0, 1.0);
	}
}
""" % [DEPTH_BIAS, DEPTH_K]
	var m := ShaderMaterial.new()
	m.shader = _depth_shader
	m.set_shader_parameter("sprites", Sprites.atlas())
	return m


# a ground depth (x - y, metres) as the depth image codes it
static func depth_code(d: float) -> int:
	return clampi(floori((d + DEPTH_BIAS) * DEPTH_K + 0.5), 1, DEPTH_TOP - 1)


# the area's streets, for Traffic
func roads() -> Array:
	return _block.get("roads", [])


func _canvas(mode: int) -> Canvas:
	var c := Canvas.new()
	c.mode = mode
	c.area = _area
	return c


# where a ground point (metres) lands in the drawing, for labels drawn over it
func project(m: Vector2) -> Vector2:
	return _iso.p(m.x, m.y)


# the lot drawn at this drawing pixel, -1 for none (a street, a park, outside the drawing)
func lot_at(px: Vector2) -> int:
	if pick == null:
		return -1
	var x := floori(px.x)
	var y := floori(px.y)
	if x < 0 or y < 0 or x >= pick.get_width() or y >= pick.get_height():
		return -1
	var k := (y * pick.get_width() + x) * 4
	return (_pick_bytes[k] | (_pick_bytes[k + 1] << 8)) - 1


# the outline of everything a lot shows (its ground and buildings, where nothing stands in
# front), as horizontal runs of drawing pixels: [the ring just outside it, the ring outside that]
func outline(lot: int) -> Array:
	if _outlines.has(lot):
		return _outlines[lot]
	var out: Array = [[], []]
	if pick == null or lot < 0 or lot >= lots.size():
		return out
	var w := pick.get_width()
	var full := Rect2i(0, 0, w, pick.get_height())
	var box := Rect2i((lots[lot]["box"] as Rect2).grow(4.0)).intersection(full)
	var bw := box.size.x
	var bh := box.size.y
	if bw <= 0 or bh <= 0:
		return out
	# 1 the lot, 2 the ring next to it, 3 the ring after
	var cell := PackedByteArray()
	cell.resize(bw * bh)
	var want := lot + 1
	for y in bh:
		var row := ((box.position.y + y) * w + box.position.x) * 4
		for x in bw:
			var k := row + x * 4
			if (_pick_bytes[k] | (_pick_bytes[k + 1] << 8)) == want:
				cell[y * bw + x] = 1
	for ring: int in [2, 3]:
		var inner: int = ring - 1
		for y in bh:
			for x in bw:
				var i := y * bw + x
				if cell[i] != 0:
					continue
				if (x > 0 and cell[i - 1] == inner) or (x < bw - 1 and cell[i + 1] == inner) \
						or (y > 0 and cell[i - bw] == inner) \
						or (y < bh - 1 and cell[i + bw] == inner):
					cell[i] = ring
	for ring: int in [2, 3]:
		var runs: Array = out[ring - 2]
		for y in bh:
			var start := -1
			for x in bw + 1:
				var on: bool = x < bw and cell[y * bw + x] == ring
				if on and start < 0:
					start = x
				elif not on and start >= 0:
					runs.append(Rect2(box.position.x + start, box.position.y + y, x - start, 1))
					start = -1
	_outlines[lot] = out
	return out


# street name labels: for each name, spots along its straight stretches (every 60 m on a long
# one, so a name shows near the office too, never two of one name closer than 60 m), with the
# on-screen direction and the room the stretch offers; the caller drops the overlaps
func street_labels() -> Array[Dictionary]:
	var by_name := {}
	for road: Dictionary in _block["roads"]:
		var name: String = road["name"] if road["name"] != "" else road.get("ref", "")
		if name == "" or road["kind"] in ["motorway", "trunk"] and road["name"] == "":
			continue
		if not by_name.has(name):
			by_name[name] = []
		by_name[name].append_array(_straight_runs(AreaBuilder._pts(road["line"])))
	var out: Array[Dictionary] = []
	for name: String in by_name:
		var segs: Array = by_name[name]
		segs.sort_custom(func(a: Array, b: Array) -> bool:
			return a[0].distance_to(a[1]) > b[0].distance_to(b[1]))
		var spots := PackedVector2Array()
		for seg: Array in segs:
			var a: Vector2 = seg[0]
			var b: Vector2 = seg[1]
			var length := a.distance_to(b)
			if length < 25.0:
				break
			var d := project(b) - project(a)
			var angle := d.angle()
			if angle > PI * 0.5:
				angle -= PI
			elif angle < -PI * 0.5:
				angle += PI
			var n := maxi(1, int(length / 60.0))
			for k in n:
				var at := a.lerp(b, (k + 0.5) / n)
				if at.length() > _radius - 15.0:
					continue
				var far := true
				for q in spots:
					far = far and q.distance_to(at) > 60.0
				if not far:
					continue
				spots.append(at)
				out.append({"text": name, "at": project(at), "angle": angle,
					"room": project(a).distance_to(project(b)) / n, "metres": at})
	return out


# a polyline cut into nearly straight runs (bends under 12 degrees are ignored), so a street
# mapped as many short pieces still offers its long stretches for a name
static func _straight_runs(line: PackedVector2Array) -> Array:
	var out: Array = []
	if line.size() < 2:
		return out
	var start := line[0]
	var dir := (line[1] - line[0]).normalized()
	for i in range(1, line.size()):
		var d := (line[i] - line[i - 1]).normalized()
		if d.dot(dir) < cos(deg_to_rad(12.0)):
			out.append([start, line[i - 1]])
			start = line[i - 1]
			dir = d
	out.append([start, line[line.size() - 1]])
	return out


# one pass of the drawing: plays the builder's ops back in the pass's colours
class Canvas:
	extends Node2D

	var mode := 0
	var area: AreaBuilder

	func _draw() -> void:
		match mode:
			MODE_GROUND:
				for op: Array in area.ground:
					_op(op, Vector2.ZERO, 0)
			MODE_SHADOW:
				for pts: PackedVector2Array in area.shadows:
					if Geometry2D.triangulate_polygon(pts).is_empty():
						continue
					draw_colored_polygon(pts, Color.WHITE)
			MODE_WORLD:
				for op: Array in area.pre:
					_op(op, Vector2.ZERO, 1)
				for obj: Dictionary in area.objects:
					if obj["outline"]:
						for d in DIRS:
							for op: Array in obj["ops"]:
								_op(op, d, 3)
					var how := 2 if obj["fade"] else 1
					for op: Array in obj["ops"]:
						_op(op, Vector2.ZERO, how)
				for op: Array in area.post:
					_op(op, Vector2.ZERO, 1)
			MODE_PICK:
				for i in area.lots.size():
					var pts: PackedVector2Array = area.lots[i]["screen"]
					if pts.size() >= 3 and not Geometry2D.triangulate_polygon(pts).is_empty():
						draw_colored_polygon(pts, _lot_code(i))
				for obj: Dictionary in area.objects:
					var lot: int = obj["lot"]
					if lot < 0:
						continue
					var code := _lot_code(lot)
					var offs: Array[Vector2] = [Vector2.ZERO]
					if obj["outline"]:
						offs.append_array(DIRS)
					for d in offs:
						for op: Array in obj["ops"]:
							_pick_op(op, d, code)
			MODE_DEPTH:
				for obj: Dictionary in area.objects:
					var key: float = obj["key"]
					# loose pixels (roof lines, antennas) of a building take its walls' and
					# roofs' depth, which is exact; only a thing made of nothing else draws them
					var solid := false
					for op: Array in obj["ops"]:
						if op[0] == Painter.OP_POLY or op[0] == Painter.OP_WALL:
							solid = true
							break
					if obj["outline"]:
						for d in DIRS:
							for op: Array in obj["ops"]:
								_depth_op(op, d, key, solid, true)
					for op: Array in obj["ops"]:
						_depth_op(op, Vector2.ZERO, key, solid, false)
				for op: Array in area.post:
					_depth_op(op, Vector2.ZERO, DEPTH_FRONT, false, false)

	# how: 0 palette codes (ground pass), 1 colour, 2 faded, 3 ink silhouette
	func _op(op: Array, off: Vector2, how: int) -> void:
		match op[0]:
			Painter.OP_POLY:
				var pts: PackedVector2Array = op[1]
				if off != Vector2.ZERO:
					pts = Iso.moved(pts, off)
				draw_colored_polygon(pts, _tone(op[2], how))
			Painter.OP_RECT:
				var r: Rect2 = op[1]
				draw_rect(Rect2(r.position + off, r.size), _tone(op[2], how))
			Painter.OP_WALL:
				if how == 3 and op[4]:
					return
				var code: Color = op[3]
				if how == 3:
					code.r8 = (code.r8 & ~15) | WorldShader.STYLE_INK
				elif how == 2:
					code.r8 = code.r8 | 64
				var quad: PackedVector2Array = op[1]
				if off != Vector2.ZERO:
					quad = Iso.moved(quad, off)
				draw_polygon(quad, PackedColorArray([code, code, code, code]), op[2])
			Painter.OP_TEX:
				# a quad whose UVs point into the sprite atlas (offset so the shader knows)
				var sp := Sprites.get_sprite(op[1])
				var r := Rect2(op[2] + sp[1] + off, sp[2])
				var a := Rect2(Sprites.atlas_rect(op[1]))
				var base := Vector2(WorldShader.ATLAS_UV, 0)
				var code := Color8(how, 0, 0)
				draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y),
					r.end, Vector2(r.position.x, r.end.y)]), PackedColorArray([code, code, code,
					code]), PackedVector2Array([a.position + base, Vector2(a.end.x,
					a.position.y) + base, a.end + base, Vector2(a.position.x, a.end.y) + base]))

	# an op in one flat colour, for the pick pass; a wall's quad is trimmed to the wall itself
	func _pick_op(op: Array, off: Vector2, code: Color) -> void:
		match op[0]:
			Painter.OP_POLY:
				var pts: PackedVector2Array = op[1]
				draw_colored_polygon(Iso.moved(pts, off), code)
			Painter.OP_RECT:
				var r: Rect2 = op[1]
				draw_rect(Rect2(r.position + off, r.size), code)
			Painter.OP_WALL:
				var q: PackedVector2Array = op[1]
				var quad := PackedVector2Array([q[0] + Vector2(0, 2), q[1] + Vector2(0, 2),
					q[2] - Vector2(0, 2), q[3] - Vector2(0, 2)])
				if not Geometry2D.triangulate_polygon(Iso.moved(quad, off)).is_empty():
					draw_colored_polygon(Iso.moved(quad, off), code)
			Painter.OP_TEX:
				var sp := Sprites.get_sprite(op[1])
				draw_rect(Rect2(op[2] + sp[1] + off, sp[2]), code)

	# an op in the depth pass: polygons and walls carry their ground points' depth (Painter),
	# sprites and loose pixels use the object's middle (`key`); DEPTH_FRONT and beyond = in
	# front of everything
	func _depth_op(op: Array, off: Vector2, key: float, solid: bool, ink: bool) -> void:
		match op[0]:
			Painter.OP_POLY:
				var pts: PackedVector2Array = op[1]
				var uv := PackedVector2Array()
				uv.resize(pts.size())
				for i in pts.size():
					uv[i] = Vector2(op[3][i] if op.size() > 3 else key, 0.0)
				draw_polygon(Iso.moved(pts, off), PackedColorArray([Color.WHITE]), uv)
			Painter.OP_WALL:
				if ink and op[4]:
					return
				# the facade quad is padded 2 px above and below the wall itself
				var q: PackedVector2Array = op[1]
				var quad := PackedVector2Array([q[0] + Vector2(0, 1.5) + off,
					q[1] + Vector2(0, 1.5) + off, q[2] - Vector2(0, 1.5) + off,
					q[3] - Vector2(0, 1.5) + off])
				if Geometry2D.triangulate_polygon(quad).is_empty():
					return
				var ends: Vector2 = op[5] if op.size() > 5 else Vector2(key, key)
				draw_polygon(quad, PackedColorArray([Color.WHITE]), PackedVector2Array([
					Vector2(ends.x, 0), Vector2(ends.y, 0), Vector2(ends.y, 0),
					Vector2(ends.x, 0)]))
			Painter.OP_RECT:
				if solid:
					return
				var r: Rect2 = op[1]
				r.position += off
				var k := Vector2(key, 0)
				draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y),
					r.end, Vector2(r.position.x, r.end.y)]), PackedColorArray([Color.WHITE]),
					PackedVector2Array([k, k, k, k]))
			Painter.OP_TEX:
				var c := DEPTH_TOP if key >= DEPTH_FRONT else BlockView.depth_code(key)
				var sp := Sprites.get_sprite(op[1])
				var r := Rect2(op[2] + sp[1] + off, sp[2])
				var a := Rect2(Sprites.atlas_rect(op[1]))
				var base := Vector2(WorldShader.ATLAS_UV, 0)
				var code := Color8(c & 255, c >> 8, 0)
				draw_polygon(PackedVector2Array([r.position, Vector2(r.end.x, r.position.y),
					r.end, Vector2(r.position.x, r.end.y)]), PackedColorArray([code, code, code,
					code]), PackedVector2Array([a.position + base, Vector2(a.end.x,
					a.position.y) + base, a.end + base, Vector2(a.position.x, a.end.y) + base]))

	static func _lot_code(lot: int) -> Color:
		return Color8((lot + 1) & 255, ((lot + 1) >> 8) & 255, 0)

	static func _tone(idx: int, how: int) -> Color:
		match how:
			0:
				return Pal.code(idx)
			2:
				return Pal.color(Pal.fade(idx))
			3:
				return Pal.c("INK")
		return Pal.color(idx)
