class_name WalkerSprites
extends RefCounted

# The walkers' sprites: tiny pixel people in the drawing's style (the static people AreaBuilder
# stands on the pavements of one-off drawings: a one-pixel column of legs, shirt and face), now
# with hair, a hand, shoes and a three-frame walk (stride, feet together, the other stride) in four
# headings (towards or away from the viewer, to the right or left), some walking a dog or
# pushing a pram. Painted pixel by pixel from the palette, packed into one atlas of palette
# indices (red = index, alpha = drawn) like CarSprites', which Traffic's shader reads.

# screen quadrants: towards the viewer right / left, away right / left
const HEADINGS := 4
# stride, legs together, the other stride
const FRAMES := 3
# alone, with a dog, with a pram
const KINDS := 3
const DOG := 1
const PRAM := 2
const CELL := Vector2i(14, 10)
# the feet, inside a cell
const ANCHOR := Vector2i(6, 7)
# shirt, trousers, hair, skin: four names a look
const LOOKS: Array[String] = [
	"RED", "SL2", "INK", "SKIN", "CYAN_M", "SL1", "TRUNK", "TER1",
	"GOLD", "CYAN_D", "WOOD", "SKIN", "CREAM", "SL3", "INK", "TER0",
	"GRN_M", "SL1", "GOLD_M", "SKIN", "SL4", "INK", "STN1", "SKIN",
	"TEAL1", "SL2", "INK", "WOOD", "SAL1", "CYAN_D", "TRUNK", "TER0",
	"TIL1", "SL1", "INK", "TER1", "CON0", "SL3", "WOOD", "SKIN",
	"OCH1", "SL2", "INK", "TRUNK", "GLS2", "STN2", "GOLD_M", "SKIN",
	"RED_M", "SL1", "DIRT_D", "TER0", "MINT", "SL2", "INK", "SKIN",
	"CYAN", "SL1", "TRUNK", "WOOD", "CRM2", "CYAN_D", "STN1", "TER1",
]
const LOOK_COUNT := 16
const DOGS: Array[String] = ["WOOD", "CREAM", "INK", "DIRT", "SL5"]
const PRAMS: Array[String] = ["CYAN_M", "RED", "SL4", "TEAL1"]

static var atlas: ImageTexture
static var image: Image
static var rects: Array[Rect2] = []
static var offsets := PackedVector2Array()


static func sprite(look: int, kind: int, heading: int, frame: int) -> int:
	return ((look * KINDS + kind) * HEADINGS + heading) * FRAMES + frame


# the heading of a direction on the ground: which way it goes on screen
static func heading(dir: Vector2) -> int:
	var right := dir.x + dir.y >= 0.0
	var front := dir.x - dir.y > 0.0
	return (0 if front else 2) + (0 if right else 1)


static func build() -> void:
	if atlas != null:
		return
	var per_row := HEADINGS * FRAMES
	var rows := LOOK_COUNT * KINDS
	image = Image.create(CELL.x * per_row, CELL.y * rows, false, Image.FORMAT_RGBA8)
	rects.clear()
	offsets.clear()
	for look in LOOK_COUNT:
		for kind in KINDS:
			for h in HEADINGS:
				for f in FRAMES:
					var px := {}
					_person(px, look, kind, h, f)
					var cell := Vector2i((h * FRAMES + f) * CELL.x, (look * KINDS + kind) * CELL.y)
					var lo := Vector2i(1 << 20, 1 << 20)
					var hi := -lo
					for q: Vector2i in px:
						var at := cell + ANCHOR + q
						image.set_pixelv(at, Pal.code(px[q]))
						lo = lo.min(at)
						hi = hi.max(at)
					rects.append(Rect2(Vector2(lo), Vector2(hi - lo + Vector2i.ONE)))
					offsets.append(Vector2(lo - cell - ANCHOR))
	atlas = ImageTexture.create_from_image(image)


# one figure: facing right, mirrored for the left; x right, y up from the feet (negative)
static func _person(px: Dictionary, look: int, kind: int, h: int, f: int) -> void:
	var shirt := Pal.i(LOOKS[look * 4])
	var legs := Pal.i(LOOKS[look * 4 + 1])
	var hair := Pal.i(LOOKS[look * 4 + 2])
	var skin := Pal.i(LOOKS[look * 4 + 3])
	var front := h < 2
	var mirror := -1 if h % 2 == 1 else 1
	# what walks ahead of the figure: drawn under it going away, over it coming towards us
	var extra := {}
	if kind == DOG:
		var dog := Pal.i(DOGS[look % DOGS.size()])
		var dark := Pal.darker(dog, 0.6)
		var ox := 2
		var oy := 1 if front else -1
		extra[Vector2i(ox + 3, oy - 2)] = dog
		extra[Vector2i(ox, oy - 2)] = dark
		for x in range(1, 4):
			extra[Vector2i(ox + x, oy - 1)] = dog
		extra[Vector2i(ox + (1 if f == 1 else 0), oy)] = dark
		extra[Vector2i(ox + (3 if f == 1 else 2), oy)] = dark
	elif kind == PRAM:
		var hood := Pal.i(PRAMS[look % PRAMS.size()])
		var low := Pal.darker(hood, 0.7)
		var ox := 2
		var oy := 1 if front else 0
		extra[Vector2i(ox, oy - 3)] = hood
		extra[Vector2i(ox + 1, oy - 3)] = hood
		extra[Vector2i(ox, oy - 2)] = hood
		extra[Vector2i(ox + 1, oy - 2)] = Pal.i("CREAM")
		extra[Vector2i(ox + 2, oy - 2)] = Pal.i("CREAM")
		for x in 3:
			extra[Vector2i(ox + x, oy - 1)] = low
		extra[Vector2i(ox, oy)] = Pal.i("INK")
		extra[Vector2i(ox + 2, oy)] = Pal.i("INK")
	# head: the face towards us, the back of the head away
	var fig := {}
	fig[Vector2i(0, -5)] = hair
	fig[Vector2i(0, -4)] = skin if front else hair
	fig[Vector2i(0, -3)] = shirt
	fig[Vector2i(0, -2)] = shirt
	fig[Vector2i(0, -1)] = legs
	# a hand swinging forward, or both on the pram's handle
	if kind == PRAM or f == 0:
		fig[Vector2i(1, -2)] = skin
	elif f == 2:
		fig[Vector2i(-1, -2)] = skin
	# shoes: together, or a stride apart
	var shoe := Pal.i("INK")
	if f == 1:
		fig[Vector2i(0, 0)] = shoe
	else:
		fig[Vector2i(-1, 0)] = shoe
		fig[Vector2i(1, 0)] = shoe
	var out := {}
	var layers: Array[Dictionary] = [extra, fig]
	if front:
		layers = [fig, extra]
	for layer in layers:
		for q: Vector2i in layer:
			out[Vector2i(q.x * mirror, q.y)] = layer[q]
	for q: Vector2i in out:
		px[q] = out[q]
