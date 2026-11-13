class_name BlockView
extends Node2D

# Draws one baked office area (format tiny-realestate-block v2, see BlockBaker) once, as style A
# isometric pixel art (docs/style_mockups/a_battlegrounds), into `texture`; `drawn` fires when it
# is ready. The caller shows the texture scaled up with nearest filtering and pans it; nothing is
# redrawn per frame. AreaBuilder turns the area into ops in low-res pixels (Iso.S per metre),
# then three passes on the GPU, each read back once:
#   1. ground: palette indices of everything flat, and the cast-shadow mask
#   2. world:  the ground through WorldShader's ground shader (pavement tiles, kerbs, shadows, the
#              dim outside the active radius), the slab and the gold ring, then every object in
#              DepthSort's painter order, each outlined in ink, faded when outside the radius,
#              walls painted by the facade shader; price tags on top
# Every pixel is a palette colour: no blending anywhere (render_mode blend_disabled).

signal drawn

const PAD := 12.0
const DIRS: Array[Vector2] = [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]
enum { MODE_GROUND, MODE_SHADOW, MODE_WORLD }

# pixel size of the whole drawing
var size := Vector2.ZERO
# where ground point (0, 0), the office, lands in the drawing
var focus := Vector2.ZERO
# metres around (0, 0) the office can use; 0 draws everything at full colour
var active_radius := 0.0
# the finished drawing, null until `drawn`
var texture: Texture2D
# milliseconds spent building the ops and on the GPU passes, for the logs
var build_ms := 0
var draw_ms := 0

var _block: Dictionary = {}
var _radius := 0.0
var _iso: Iso
var _area: AreaBuilder


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
	await RenderingServer.frame_post_draw
	var ground := ImageTexture.create_from_image(g.get_texture().get_image())
	var shade := ImageTexture.create_from_image(s.get_texture().get_image())
	g.queue_free()
	s.queue_free()
	var under := Sprite2D.new()
	under.centered = false
	under.texture = ground
	under.material = WorldShader.ground_material(ground, shade, focus, Iso.S,
		active_radius if active_radius > 0.0 else 1.0e9)
	var world := _canvas(MODE_WORLD)
	world.material = WorldShader.facade_material()
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


func _canvas(mode: int) -> Canvas:
	var c := Canvas.new()
	c.mode = mode
	c.area = _area
	return c


# where a ground point (metres) lands in the drawing, for labels drawn over it
func project(m: Vector2) -> Vector2:
	return _iso.p(m.x, m.y)


# street name labels: for each name, spots on its longest straight stretches at least 160 m
# apart, with the on-screen direction of the street there; the caller drops the overlaps
func street_labels() -> Array[Dictionary]:
	var by_name := {}
	for road: Dictionary in _block["roads"]:
		var name: String = road["name"] if road["name"] != "" else road.get("ref", "")
		if name == "" or road["kind"] in ["motorway", "trunk"] and road["name"] == "":
			continue
		var line := AreaBuilder._pts(road["line"])
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
				"room": project(a).distance_to(project(b)), "metres": mid})
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
				var sp := Sprites.get_sprite(op[1])
				var tex: Texture2D = sp[0]
				if how == 2:
					tex = sp[1]
				elif how == 3:
					tex = sp[2]
				draw_texture(tex, op[2] + sp[3] + off)

	static func _tone(idx: int, how: int) -> Color:
		match how:
			0:
				return Pal.code(idx)
			2:
				return Pal.color(Pal.fade(idx))
			3:
				return Pal.c("INK")
		return Pal.color(idx)
