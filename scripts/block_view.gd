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
# In `live` mode (the game's office view) the builder and the finished image are kept, and
# `redraw_lot` lays one lot out again and redraws only the rectangle it touches (old and new
# buildings, their shadows, a margin), in small throwaway viewports, then pastes it into the
# image, the texture and the pick image: buying or building never redraws the whole area.

signal drawn
# a lot's redraw is on screen (and in the pick image)
signal redrawn(lot: int)

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
# the office's pin in the drawing (with a margin), which labels keep clear of
var sign_box := Rect2()
# the office's pin in the drawing
var mark_box := Rect2()
# the lots as AreaBuilder laid them out ("data", "poly", "screen", "box", "active")
var lots: Array[Dictionary] = []
# the pick pass: which lot each pixel of the drawing shows, null until `drawn`
var pick: Image
# milliseconds spent building the ops and on the GPU passes, for the logs
var build_ms := 0
var draw_ms := 0
# keep what a lot redraw needs (the game); off for one-off renders
var live := false
# the last lot redraw: milliseconds of main-thread work (lay out, sort, record, paste) and wall
# time until it was on screen, and the size of the rectangle redrawn
var redraw_ms := 0
var redraw_wall_ms := 0
var redraw_px := Vector2i.ZERO
var busy := false
# the depth pass and the cast-shadow mask, for what is drawn live over the drawing; null until
# `drawn`
var depth_tex: Texture2D
var shade_tex: Texture2D

var _block: Dictionary = {}
var _radius := 0.0
var _iso: Iso
var _area: AreaBuilder
var _pick_bytes := PackedByteArray()
var _image: Image
# the depth and shadow images behind depth_tex / shade_tex, kept so a lot redraw can patch them
var _depth_img: Image
var _shade_img: Image
var _queue: Array[int] = []
# the depth code of the office's pin
var _mark_code := 0
# boxes of the ground, shadow and pre ops (built on the first lot redraw)
var _boxes := {}
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
	# in the game any lot may become a skyscraper later; leave room for the tallest one
	if live:
		tallest = maxf(tallest, AreaBuilder.top_of(5, 35) + 30.0)
	var box := Rect2(_iso.p(_radius, 0.0), Vector2.ZERO)
	for c: Vector2 in Geo.circle(_radius, 96):
		box = box.expand(_iso.p(c.x, c.y, tallest)).expand(_iso.p(c.x, c.y,
			-AreaBuilder.SLAB_DEPTH - 2.0))
	_iso.origin = (Vector2(PAD, PAD) - box.position).round()
	size = (box.size + Vector2(PAD, PAD) * 2.0).ceil()
	focus = _iso.p(0.0, 0.0)
	_area = AreaBuilder.new(_iso, block, active_radius)
	_area.tags = not live
	_area.people = not live
	_area.build()
	_area.objects = DepthSort.order(_area.objects)
	pops = _area.pops
	lots = _area.lots
	if not _area.keep_clear.is_empty():
		sign_box = _area.keep_clear[0]
	mark_box = _area.mark_box
	_mark_code = depth_code(Iso.depth(_area.mark))
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
	var depth_img := d.get_texture().get_image()
	depth_tex = ImageTexture.create_from_image(depth_img)
	shade_tex = shade
	if live:
		_depth_img = depth_img
		_shade_img = s.get_texture().get_image()
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
	_image = w.get_texture().get_image()
	texture = ImageTexture.create_from_image(_image)
	w.queue_free()
	if not live:
		_area = null
		_image = null
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


func _canvas(mode: int, region: Rect2i = Rect2i(), objs: Array = []) -> Canvas:
	var c := Canvas.new()
	c.mode = mode
	c.area = _area
	if region.size != Vector2i.ZERO:
		c.region = Rect2(region)
		c.objs = objs
		c.boxes = _boxes
		c.position = -Vector2(region.position)
	return c


# --- one lot at a time (live mode) -----------------------------------------------------------------

# lays lot `lot` out again from its plot (the caller has changed the plot: owned, tier, works)
# and redraws it; requests queue up and run one after another
func redraw_lot(lot: int) -> void:
	if _area == null or lot < 0 or lot >= lots.size():
		return
	if not lot in _queue:
		_queue.append(lot)
	if busy or texture == null:
		return
	busy = true
	while not _queue.is_empty():
		await _redraw(_queue.pop_front())
	busy = false


static func _ri(r: Rect2) -> Rect2i:
	var a := Vector2i(floori(r.position.x), floori(r.position.y))
	var b := Vector2i(ceili(r.end.x), ceili(r.end.y))
	return Rect2i(a, b - a)


# the drawing pixels a lot covers: its ground, its objects and their shadows
func _reach(lot: int) -> Rect2:
	var box: Rect2 = lots[lot]["box"]
	for pts: PackedVector2Array in _area.lot_shadows[lot]:
		for q in pts:
			box = box.expand(q)
	return box


func _redraw(lot: int) -> void:
	var t0 := Time.get_ticks_msec()
	if _boxes.is_empty():
		_boxes = Canvas.op_boxes(_area)
	var before := _reach(lot)
	_area.rebuild_lot(lot)
	var full := Rect2i(Vector2i.ZERO, Vector2i(size))
	# what changed, and a margin around it so kerbs and outlines at the edge see their neighbours
	var inner := _ri(before.merge(_reach(lot)).grow(3.0)).intersection(full)
	var region := inner.grow(4).intersection(full)
	if inner.size.x <= 0 or inner.size.y <= 0:
		return
	var objs: Array = []
	var area_r := Rect2(region)
	for o: Dictionary in _area.objects:
		if (o["rect"] as Rect2).intersects(area_r):
			objs.append(o)
	objs = DepthSort.order(objs)
	var g := _viewport(region.size, _canvas(MODE_GROUND, region, objs))
	var s := _viewport(region.size, _canvas(MODE_SHADOW, region, objs))
	var p := _viewport(region.size, _canvas(MODE_PICK, region, objs))
	var dc := _canvas(MODE_DEPTH, region, objs)
	dc.material = _depth_material()
	var dv := _viewport(region.size, dc)
	var spent := Time.get_ticks_msec() - t0
	await RenderingServer.frame_post_draw
	var t1 := Time.get_ticks_msec()
	var ground := ImageTexture.create_from_image(g.get_texture().get_image())
	var shade := ImageTexture.create_from_image(s.get_texture().get_image())
	var pick_part := p.get_texture().get_image()
	var depth_part := dv.get_texture().get_image()
	var shade_part := s.get_texture().get_image()
	g.queue_free()
	s.queue_free()
	p.queue_free()
	dv.queue_free()
	var under := Sprite2D.new()
	under.centered = false
	under.texture = ground
	under.material = WorldShader.ground_material(ground, shade, focus - Vector2(region.position),
		Iso.S, active_radius if active_radius > 0.0 else 1.0e9, region.position)
	var world := _canvas(MODE_WORLD, region, objs)
	world.material = WorldShader.facade_material(Sprites.atlas())
	var w := _viewport(region.size, under)
	w.add_child(world)
	spent += Time.get_ticks_msec() - t1
	await RenderingServer.frame_post_draw
	var t2 := Time.get_ticks_msec()
	var part := w.get_texture().get_image()
	w.queue_free()
	var src := Rect2i(inner.position - region.position, inner.size)
	_image.blit_rect(part, src, inner.position)
	(texture as ImageTexture).update(_image)
	pick.blit_rect(pick_part, src, inner.position)
	_pick_bytes = pick.get_data()
	# what Traffic hides its cars behind, and the shadows it darkens them in
	if _depth_img != null:
		_depth_img.blit_rect(depth_part, src, inner.position)
		(depth_tex as ImageTexture).update(_depth_img)
		_shade_img.blit_rect(shade_part, src, inner.position)
		(shade_tex as ImageTexture).update(_shade_img)
	_outlines.clear()
	spent += Time.get_ticks_msec() - t2
	redraw_ms = spent
	redraw_wall_ms = Time.get_ticks_msec() - t0
	redraw_px = inner.size
	redrawn.emit(lot)


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


# true when a drawing pixel within `grow` of the office's pin shows the pin or something behind
# it (bare ground, a building farther back), not something standing in front of it
func points_at_mark(px: Vector2, grow: float) -> bool:
	if mark_box.size == Vector2.ZERO or not mark_box.grow(grow).has_point(px):
		return false
	if _depth_img == null:
		return true
	var q := Vector2i(px.floor())
	if q.x < 0 or q.y < 0 or q.x >= _depth_img.get_width() or q.y >= _depth_img.get_height():
		return false
	var c := _depth_img.get_pixelv(q)
	return (c.r8 | (c.g8 << 8)) <= _mark_code


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


# one pass of the drawing: plays the builder's ops back in the pass's colours
class Canvas:
	extends Node2D

	var mode := 0
	var area: AreaBuilder
	# a lot redraw: only this rectangle of the drawing, with these objects (in painter's order)
	var region := Rect2()
	var objs: Array = []
	var boxes := {}

	# the drawing boxes of the ground, shadow and pre ops, so a region skips what it cannot see
	static func op_boxes(a: AreaBuilder) -> Dictionary:
		var out := {"ground": [], "shadows": [], "pre": []}
		for op: Array in a.ground:
			out["ground"].append(_box_of(op))
		for pts: PackedVector2Array in a.shadows:
			out["shadows"].append(_pts_box(pts))
		for op: Array in a.pre:
			out["pre"].append(_box_of(op))
		return out

	static func _box_of(op: Array) -> Rect2:
		match op[0]:
			Painter.OP_POLY, Painter.OP_WALL:
				return _pts_box(op[1]).grow(3.0)
			Painter.OP_RECT:
				return op[1]
		return Rect2(-1e6, -1e6, 2e6, 2e6)

	static func _pts_box(pts: PackedVector2Array) -> Rect2:
		if pts.is_empty():
			return Rect2()
		var r := Rect2(pts[0], Vector2.ZERO)
		for q in pts:
			r = r.expand(q)
		return r

	func _sees(r: Rect2) -> bool:
		return region.size == Vector2.ZERO or r.intersects(region)

	func _lot_seen(i: int) -> bool:
		return region.size == Vector2.ZERO or (area.lots[i]["box"] as Rect2).intersects(region) \
			or _pts_box(area.lots[i]["screen"]).intersects(region)

	func _draw() -> void:
		var whole := region.size == Vector2.ZERO
		match mode:
			MODE_GROUND:
				for k in area.ground.size():
					if whole or _sees(boxes["ground"][k]):
						_op(area.ground[k], Vector2.ZERO, 0)
				for i in area.lot_ground.size():
					if _lot_seen(i):
						for op: Array in area.lot_ground[i]:
							_op(op, Vector2.ZERO, 0)
			MODE_SHADOW:
				for k in area.shadows.size():
					if whole or _sees(boxes["shadows"][k]):
						_shadow_poly(area.shadows[k])
				for list: Array in area.lot_shadows:
					for pts: PackedVector2Array in list:
						if whole or _sees(_pts_box(pts)):
							_shadow_poly(pts)
			MODE_WORLD:
				for k in area.pre.size():
					if whole or _sees(boxes["pre"][k]):
						_op(area.pre[k], Vector2.ZERO, 1)
				for obj: Dictionary in (area.objects if whole else objs):
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
					if not _lot_seen(i):
						continue
					if pts.size() >= 3 and not Geometry2D.triangulate_polygon(pts).is_empty():
						draw_colored_polygon(pts, _lot_code(i))
				for obj: Dictionary in (area.objects if whole else objs):
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
				for obj: Dictionary in (area.objects if whole else objs):
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

	func _shadow_poly(pts: PackedVector2Array) -> void:
		if not Geometry2D.triangulate_polygon(pts).is_empty():
			draw_colored_polygon(pts, Color.WHITE)

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
				# a sprite's ink copy (Painter.ink_under) is ink whatever the pass draws
				var code := Color8(3 if op.size() > 3 else how, 0, 0)
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
