class_name CarSprites
extends RefCounted

# The moving cars' sprites, drawn once per session by the same painter, facade shader and ink
# outline as the parked cars in the drawing (AreaBuilder._car), so both look alike: each kind of
# vehicle in HEADINGS directions, with and without its brake lights, packed into one atlas of
# palette indices (red = index, alpha = drawn) that Traffic's shader reads with texelFetch.

const HEADINGS := 16
const CELL := Vector2i(28, 24)
# the car's middle, on the ground, inside its cell
const ANCHOR := Vector2i(14, 15)
# kind, body tint (Pal.CAR_TINTS) and length in metres
const VARIANTS: Array[Dictionary] = [
	{"kind": "car", "tint": "RED", "len": 4.4},
	{"kind": "car", "tint": "CREAM", "len": 4.4},
	{"kind": "car", "tint": "CYAN_M", "len": 4.4},
	{"kind": "car", "tint": "GOLD", "len": 4.4},
	{"kind": "car", "tint": "SL5", "len": 4.4},
	{"kind": "taxi", "tint": "SL1", "len": 4.4},
	{"kind": "van", "tint": "CREAM", "len": 5.4},
	{"kind": "van", "tint": "CYAN_M", "len": 5.4},
	{"kind": "bus", "tint": "RED", "len": 10.0},
]
const BUS := 8
const TAXI := 5
const VANS: Array[int] = [6, 7]

# the atlas and, per sprite (see sprite()), its rect in the atlas and its top-left corner
# relative to the car's middle; null until built
static var atlas: ImageTexture
static var rects: Array[Rect2] = []
static var offsets := PackedVector2Array()
static var _busy := false


# sprite number of a variant, heading and brake state
static func sprite(variant: int, heading: int, braking: bool) -> int:
	return (variant * 2 + (1 if braking else 0)) * HEADINGS + heading


# the heading number of a direction on the ground
static func heading(dir: Vector2) -> int:
	return posmod(roundi(atan2(dir.y, dir.x) / TAU * HEADINGS), HEADINGS)


# draws the atlas on the GPU under `host` (once per session; later calls return at once)
static func build(host: Node) -> void:
	while _busy:
		await host.get_tree().process_frame
	if atlas != null:
		return
	_busy = true
	var rows := VARIANTS.size() * 2
	var size := Vector2i(CELL.x * HEADINGS, CELL.y * rows)
	var cam := Iso.new()
	var pt := Painter.new(cam)
	var area := AreaBuilder.new(cam, {"radius_m": 1.0}, 0.0)
	for v in VARIANTS.size():
		for b in 2:
			for h in HEADINGS:
				var cell := Vector2i(h, v * 2 + b) * CELL
				cam.origin = Vector2(cell + ANCHOR)
				var a := TAU * h / HEADINGS
				var ops := pt.begin("car%d" % v)
				_recipe(pt, VARIANTS[v], Vector2(cos(a), sin(a)), b == 1)
				area.objects.append({"ops": ops, "outline": true, "fade": false})
	var canvas := BlockView.Canvas.new()
	canvas.mode = BlockView.MODE_WORLD
	canvas.area = area
	canvas.material = WorldShader.facade_material(Sprites.atlas())
	var vp := SubViewport.new()
	vp.disable_3d = true
	vp.transparent_bg = true
	vp.size = size
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.add_child(canvas)
	# under the root, so the screen that asked can close meanwhile
	host.get_tree().root.add_child(vp)
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	vp.queue_free()
	_index(img, rows)
	_busy = false


# colours back to palette indices, and each sprite's tight box
static func _index(img: Image, rows: int) -> void:
	var lookup := {}
	for k in Pal.NAMES.size():
		lookup[Pal.color(k).to_rgba32() | 0xFF] = k
	img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var src := img.get_data()
	var out := PackedByteArray()
	out.resize(src.size())
	var lo: Array[Vector2i] = []
	var hi: Array[Vector2i] = []
	lo.resize(rows * HEADINGS)
	hi.resize(rows * HEADINGS)
	lo.fill(Vector2i(9999, 9999))
	hi.fill(Vector2i(-1, -1))
	var miss := 0
	for y in img.get_height():
		for x in w:
			var k := (y * w + x) * 4
			if src[k + 3] < 128:
				continue
			var rgba := (src[k] << 24) | (src[k + 1] << 16) | (src[k + 2] << 8) | 0xFF
			if not lookup.has(rgba):
				miss += 1
			out[k] = int(lookup.get(rgba, 0))
			out[k + 3] = 255
			var cell := (y / CELL.y) * HEADINGS + x / CELL.x
			lo[cell] = lo[cell].min(Vector2i(x, y))
			hi[cell] = hi[cell].max(Vector2i(x, y))
	if miss > 0:
		push_error("CarSprites: %d pixels off the palette" % miss)
	rects.clear()
	offsets.clear()
	for cell in rows * HEADINGS:
		var corner := Vector2i(cell % HEADINGS, cell / HEADINGS) * CELL + ANCHOR
		if hi[cell].x < 0:
			rects.append(Rect2())
			offsets.append(Vector2.ZERO)
			continue
		rects.append(Rect2(lo[cell], hi[cell] - lo[cell] + Vector2i.ONE))
		offsets.append(Vector2(lo[cell] - corner))
	atlas = ImageTexture.create_from_image(Image.create_from_data(w, img.get_height(), false,
		Image.FORMAT_RGBA8, out))


# one vehicle facing `dir`, its middle at ground (0, 0): the parked car's recipe for cars and
# taxis, a delivery van with a tall box behind its cab, a bus with a band of windows
static func _recipe(pt: Painter, v: Dictionary, dir: Vector2, braking: bool) -> void:
	var side := dir.orthogonal()
	var tint: String = v["tint"]
	var body := Pal.car_ramp(Pal.CAR_TINTS.find(tint))
	var half := float(v["len"]) * 0.5
	match v["kind"]:
		"car", "taxi":
			var foot := _box(dir, side, -half, half, 1.0)
			var top := Pal.car_ramp(Pal.CAR_TINTS.find("GOLD")) if v["kind"] == "taxi" else body
			pt.prism(foot, 0.0, 2.0, WorldShader.STYLE_PLAIN, body, body, false)
			var cab := Iso.offset(foot, -0.45)
			if cab.size() >= 3:
				pt.prism(cab, 2.0, 3.0, WorldShader.STYLE_CAB, body, top, false)
		"van":
			pt.prism(_box(dir, side, -half, half, 1.05), 0.0, 2.0, WorldShader.STYLE_PLAIN, body,
				body, false)
			pt.prism(_box(dir, side, -half, half - 1.6, 1.05), 2.0, 4.0, WorldShader.STYLE_PLAIN,
				body, body, false)
			pt.prism(_box(dir, side, half - 1.6, half - 0.3, 0.95), 2.0, 3.0,
				WorldShader.STYLE_CAB, body, body, false)
		"bus":
			var foot := _box(dir, side, -half, half, 1.25)
			pt.prism(foot, 0.0, 2.0, WorldShader.STYLE_PLAIN, body, body, false)
			pt.prism(foot, 2.0, 4.0, WorldShader.STYLE_CAB, body, body, false)
			pt.prism(foot, 4.0, 5.0, WorldShader.STYLE_PLAIN, body, Pal.car_ramp(
				Pal.CAR_TINTS.find("CREAM")), false)
	# brake lights: two red dots low on the back, when the back faces the viewer
	if braking and dir.y - dir.x > 0.05:
		var w := 1.05 if v["kind"] != "bus" else 1.3
		for k: float in [-0.6, 0.6]:
			var q := -dir * half + side * w * k
			pt.dot(pt.iso.pi(q.x, q.y, 1.0), Pal.i("RED"))


static func _box(dir: Vector2, side: Vector2, back: float, front: float,
		half_w: float) -> PackedVector2Array:
	return Iso.clean(PackedVector2Array([dir * back - side * half_w, dir * front - side * half_w,
		dir * front + side * half_w, dir * back + side * half_w]))
