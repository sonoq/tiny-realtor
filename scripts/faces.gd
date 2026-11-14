class_name Faces
extends RefCounted

# Manager portraits: a 16x16 pixel bust made with maths from a seed (skin, hair style and
# colour, eyes, glasses, moustache, suit and tie or blouse), every pixel a palette colour with a
# one-pixel ink rim, drawn as px x px blocks (x3 in lists, x5 on the manager's card), so they
# stay crisp at any whole zoom and readable when the window is shrunk.

const SIZE := 16
# skin and its shade
const SKINS: Array = [["SKIN", "TER1"], ["SAL0", "SAL1"], ["TER0", "TER1"], ["OCH2", "OCH3"],
	["TER2", "TER3"], ["DIRT_D", "TRUNK"]]
const HAIRS: Array[String] = ["INK", "TRUNK", "DIRT_D", "GOLD", "SL4", "RED_M", "STN1", "OCH1"]
const SUITS: Array[String] = ["SL2", "CYAN_D", "RED_M", "GRN_M", "TEAL3", "GLS3", "SL3", "TIL3"]
const TIES: Array[String] = ["RED", "GOLD", "CYAN", "MINT", "CREAM"]
# the frame colour of each rarity: common, rare, epic, legendary
const RARITY_INK: Array[Color] = [Color("7d8fa6"), Color("3fe0ff"), Color("62f08a"),
	Color("ffc94a")]

static var _cache := {}


# the portrait's pixels as runs [x, y, width, palette index], built once per seed
static func runs(seed: int) -> Array:
	if _cache.has(seed):
		return _cache[seed]
	var g := _grid(seed)
	var out: Array = []
	for y in SIZE:
		var x := 0
		while x < SIZE:
			var idx: int = g[y * SIZE + x]
			if idx < 0:
				x += 1
				continue
			var w := 1
			while x + w < SIZE and g[y * SIZE + x + w] == idx:
				w += 1
			out.append([x, y, w, idx])
			x += w
	_cache[seed] = out
	return out


static func draw(c: CanvasItem, at: Vector2, px: float, seed: int) -> void:
	for r: Array in runs(seed):
		c.draw_rect(Rect2(at + Vector2(r[0], r[1]) * px, Vector2(float(r[2]) * px, px)),
			Pal.color(r[3]))


# a portrait in a dark square framed in its rarity's colour, `box` on screen
static func badge(c: CanvasItem, box: Rect2, seed: int, rarity: int) -> void:
	c.draw_rect(box, Ui.VOID)
	c.draw_rect(box.grow(-2.0), Ui.SL1)
	c.draw_rect(box.grow(-1.0), RARITY_INK[clampi(rarity, 0, 3)], false, 2.0)
	var px := floorf((minf(box.size.x, box.size.y) - 8.0) / SIZE)
	var size := Vector2.ONE * px * SIZE
	draw(c, (box.get_center() - size * 0.5).round(), px, seed)


static func _grid(seed: int) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var g := PackedInt32Array()
	g.resize(SIZE * SIZE)
	g.fill(-1)
	var skin: Array = SKINS[rng.randi() % SKINS.size()]
	var sk := Pal.i(skin[0])
	var sd := Pal.i(skin[1])
	var hair := Pal.i(HAIRS[rng.randi() % HAIRS.size()])
	var suit := Pal.i(SUITS[rng.randi() % SUITS.size()])
	var tie := Pal.i(TIES[rng.randi() % TIES.size()])
	var style := rng.randi() % 6
	var glasses := rng.randf() < 0.3
	var tash := rng.randf() < 0.25 and style != 1
	var blouse := rng.randf() < 0.4
	var put := func(x: int, y: int, idx: int) -> void:
		if x >= 0 and y >= 0 and x < SIZE and y < SIZE:
			g[y * SIZE + x] = idx
	var fill := func(x0: int, y0: int, x1: int, y1: int, idx: int) -> void:
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				put.call(x, y, idx)
	# shoulders and suit, shirt and tie (or a blouse with a gold pendant)
	fill.call(2, 13, 13, 15, suit)
	fill.call(3, 12, 5, 12, suit)
	fill.call(10, 12, 12, 12, suit)
	fill.call(6, 12, 9, 12, sd)
	if blouse:
		fill.call(6, 13, 9, 15, Pal.i("CREAM"))
		put.call(7, 13, Pal.i("GOLD"))
	else:
		fill.call(6, 13, 9, 13, Pal.i("CREAM"))
		put.call(6, 14, Pal.i("CREAM"))
		put.call(9, 14, Pal.i("CREAM"))
		fill.call(7, 13, 8, 15, tie)
	# the head, its shaded side and the ears
	fill.call(5, 3, 10, 3, sk)
	fill.call(4, 4, 11, 10, sk)
	fill.call(5, 11, 10, 11, sk)
	fill.call(11, 5, 11, 10, sd)
	put.call(10, 11, sd)
	for y: int in [7, 8]:
		put.call(3, y, sk)
		put.call(12, y, sd)
	# hair
	match style:
		0:
			fill.call(4, 2, 11, 3, hair)
			fill.call(4, 4, 11, 4, hair)
			put.call(4, 5, hair)
			put.call(11, 5, hair)
		1:
			fill.call(5, 2, 10, 2, hair)
			fill.call(4, 3, 11, 4, hair)
			fill.call(3, 4, 4, 12, hair)
			fill.call(11, 4, 12, 12, hair)
		2:
			fill.call(4, 6, 4, 8, hair)
			fill.call(11, 6, 11, 8, hair)
			put.call(6, 3, Pal.i("CREAM") if sk == Pal.i("SAL0") else Pal.i("SAL0"))
		3:
			fill.call(6, 1, 9, 2, hair)
			fill.call(4, 3, 11, 4, hair)
			put.call(4, 5, hair)
			put.call(11, 5, hair)
		4:
			fill.call(4, 1, 11, 4, hair)
			fill.call(3, 2, 3, 9, hair)
			fill.call(12, 2, 12, 9, hair)
			put.call(4, 1, -1)
			put.call(11, 1, -1)
			put.call(7, 1, -1)
		_:
			fill.call(4, 2, 11, 3, hair)
			fill.call(4, 4, 8, 4, hair)
			fill.call(4, 5, 5, 5, hair)
			put.call(11, 4, hair)
	# brows, eyes, nose, mouth
	if style != 4:
		put.call(6, 6, hair if hair != sk else Pal.i("INK"))
		put.call(9, 6, hair if hair != sk else Pal.i("INK"))
	put.call(6, 7, Pal.i("INK"))
	put.call(9, 7, Pal.i("INK"))
	put.call(8, 8, sd)
	put.call(7, 10, Pal.i("RED_M"))
	put.call(8, 10, Pal.i("RED_M"))
	if tash:
		fill.call(6, 9, 9, 9, hair)
	if glasses:
		for x: int in [5, 7, 8, 10]:
			put.call(x, 7, Pal.i("INK"))
		put.call(6, 7, Pal.i("CYAN_D"))
		put.call(9, 7, Pal.i("CYAN_D"))
	elif rng.randf() < 0.5:
		put.call(5, 9, Pal.i("SAL1"))
		put.call(10, 9, Pal.i("SAL1"))
	# the ink rim round the silhouette (not under the shoulders, which run off the bottom)
	var rim := g.duplicate()
	for y in SIZE:
		for x in SIZE:
			if g[y * SIZE + x] >= 0:
				continue
			for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var q := Vector2i(x, y) + d
				if q.x >= 0 and q.y >= 0 and q.x < SIZE and q.y < SIZE \
						and g[q.y * SIZE + q.x] >= 0:
					rim[y * SIZE + x] = Pal.i("INK")
					break
	return rim
