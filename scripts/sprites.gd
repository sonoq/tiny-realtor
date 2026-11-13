class_name Sprites
extends RefCounted

# The office view's little pixel sprites, each drawn once into a texture in three versions: in
# colour, faded (outside the active radius) and as a solid ink silhouette (for the one-pixel
# outline pass). Recipes are the mockup's: trees, flags, the red "$" sale sign, street lamps,
# people, and the framed tags (price tags, the REALTOR billboard) with the 3x5 micro font.
# A sprite is placed by its anchor: the pixel its recipe calls (0, 0), usually the foot.

const MICRO := {
	"A": "010101111101101", "B": "110101110101110", "C": "011100100100011",
	"D": "110101101101110", "E": "111100110100111", "F": "111100110100100",
	"G": "011100101101011", "H": "101101111101101", "I": "111010010010111",
	"J": "001001001101010", "K": "101101110101101", "L": "100100100100111",
	"M": "101111111101101", "N": "110101101101101", "O": "010101101101010",
	"P": "110101110100100", "Q": "010101101110011", "R": "110101110101101",
	"S": "011100010001110", "T": "111010010010010", "U": "101101101101111",
	"V": "101101101101010", "W": "101101111111101", "X": "101101010101101",
	"Y": "101101010010010", "Z": "111001010100111", "0": "111101101101111",
	"1": "010110010010111", "2": "110001010100111", "3": "110001010001110",
	"4": "101101111001001", "5": "111100110001110", "6": "011100111101111",
	"7": "111001010010010", "8": "111101111101111", "9": "111101111001110",
	"$": "011110010011110", "+": "000010111010000", "/": "001001010100100",
	".": "000000000000010", ":": "000010000010000", "%": "101001010100101",
	"-": "000000111000000", " ": "000000000000000", "x": "000101010101000",
	",": "000000000010100",
	"©": "011110100101101001100101011110",
}

# name -> [colour texture, faded texture, ink texture, anchor offset]
static var _cache := {}


static func micro_w(s: String) -> int:
	var w := 0
	for ch in s:
		w += _gw(ch) + 1
	return maxi(0, w - 1)


static func _gw(ch: String) -> int:
	return 6 if ch == "©" else 3


# draws micro text into a pixel map (Vector2i -> palette index)
static func micro(px: Dictionary, x: int, y: int, s: String, idx: int) -> void:
	var cx := x
	for ch in s:
		var g: String = MICRO.get(ch, MICRO[" "])
		var w := _gw(ch)
		for j in 5 * w:
			if g[j] == "1":
				px[Vector2i(cx + j % w, y + j / w)] = idx
		cx += w + 1


# a Battlegrounds frame: 1 px border inset by one, filled, with hollow 3x3 corner studs
static func frame(px: Dictionary, x0: int, y0: int, x1: int, y1: int, border: int,
		fill: int = -1, studs: bool = true) -> void:
	if fill >= 0:
		for y in range(y0 + 1, y1):
			for x in range(x0 + 1, x1):
				px[Vector2i(x, y)] = fill
	for x in range(x0 + 1, x1):
		px[Vector2i(x, y0 + 1)] = border
		px[Vector2i(x, y1 - 1)] = border
	for y in range(y0 + 1, y1):
		px[Vector2i(x0 + 1, y)] = border
		px[Vector2i(x1 - 1, y)] = border
	if not studs:
		return
	for s: Vector2i in [Vector2i(x0 - 1, y0 - 1), Vector2i(x1 - 1, y0 - 1),
			Vector2i(x0 - 1, y1 - 1), Vector2i(x1 - 1, y1 - 1)]:
		for dy in 3:
			for dx in 3:
				px[s + Vector2i(dx, dy)] = Pal.i("INK") if dx == 1 and dy == 1 else border


# the sprite's three textures and its anchor, built on first use
static func get_sprite(key: String) -> Array:
	if _cache.has(key):
		return _cache[key]
	var px := {}
	var parts := key.split(":")
	match parts[0]:
		"tree":
			_tree(px, parts[1], parts[2] == "big")
		"flag":
			_flag(px, int(parts[1]), parts[2])
		"sale":
			_sale(px)
		"lamp":
			_lamp(px)
		"ped":
			_ped(px, int(parts[1]))
		"tag":
			_tag(px, parts[1])
		"billboard":
			_billboard(px)
		"pin":
			_pin(px)
	var out := _bake(px)
	_cache[key] = out
	return out


static func _bake(px: Dictionary) -> Array:
	if px.is_empty():
		px[Vector2i.ZERO] = Pal.i("INK")
	var lo := Vector2i(1 << 20, 1 << 20)
	var hi := -lo
	for q: Vector2i in px:
		lo = lo.min(q)
		hi = hi.max(q)
	var size := hi - lo + Vector2i.ONE
	var imgs: Array[Image] = []
	for _k in 3:
		imgs.append(Image.create(size.x, size.y, false, Image.FORMAT_RGBA8))
	var ink := Pal.color(Pal.i("INK"))
	for q: Vector2i in px:
		var idx: int = px[q]
		imgs[0].set_pixelv(q - lo, Pal.color(idx))
		imgs[1].set_pixelv(q - lo, Pal.color(Pal.fade(idx)))
		imgs[2].set_pixelv(q - lo, ink)
	return [ImageTexture.create_from_image(imgs[0]), ImageTexture.create_from_image(imgs[1]),
		ImageTexture.create_from_image(imgs[2]), Vector2(lo)]


static func _put(px: Dictionary, x: int, y: int, name: String) -> void:
	px[Vector2i(x, y)] = Pal.i(name)


static func _tree(px: Dictionary, seed: String, big: bool) -> void:
	var r := 4 if big else 3
	for k in 3:
		_put(px, 0, -k, "TRUNK")
	var cy := -2 - r
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var d2 := dx * dx + dy * dy
			if d2 > r * r + r * 0.8:
				continue
			var c := "GRASS_D"
			if dx + dy <= -r * 0.5:
				c = "GRASS"
			if dx + dy <= -r * 1.2 and d2 < r * r:
				c = "GRASS_L"
			if dx + dy >= r * 0.9:
				c = "GRASS_DD"
			if c == "GRASS_D" and Iso.h01("%s%d,%d" % [seed, dx, dy]) < 0.12:
				c = "GRASS"
			_put(px, dx, cy + dy, c)


# a flag pole of height h with a gold knob; cyan cloth for the player's, else the named colours
static func _flag(px: Dictionary, h: int, tone: String) -> void:
	for k in h:
		_put(px, 0, -k, "SL1")
	_put(px, 0, -h, "GOLD")
	var c1 := "CYAN" if tone == "cyan" else "RED"
	var c2 := "CYAN_M" if tone == "cyan" else "RED_M"
	for dx in range(1, 5):
		for dy in range(0, 3 if dx < 4 else 2):
			var last := 1 if dx == 4 else 0
			_put(px, dx, -h + 1 + dy + last, c1 if dy < 2 - last else c2)


static func _sale(px: Dictionary) -> void:
	for k in 6:
		_put(px, 0, -k, "WOOD")
	_put(px, 1, 0, "TRUNK")
	for dx in range(-4, 5):
		for dy in range(-12, -5):
			var edge := dy == -12 or dy == -6 or dx == -4 or dx == 4
			_put(px, dx, dy, "RED_M" if edge else "RED")
	var glyph: Array[String] = ["111", "100", "111", "001", "111"]
	for j in glyph.size():
		for i in 3:
			if glyph[j][i] == "1":
				_put(px, -1 + i, -11 + j, "CREAM")
	_put(px, 0, -12, "CREAM")
	_put(px, 0, -6, "CREAM")


static func _lamp(px: Dictionary) -> void:
	for k in 8:
		_put(px, 0, -k, "SL1")
	_put(px, -1, -8, "SL1")
	_put(px, 1, -8, "SL1")
	_put(px, -1, -9, "GOLD")
	_put(px, 1, -9, "GOLD")
	_put(px, 0, -9, "SL1")
	_put(px, 0, -10, "SL1")
	_put(px, -1, 0, "SL1")
	_put(px, 1, 0, "SL1")


static func _ped(px: Dictionary, j: int) -> void:
	var shirts: Array[String] = ["RED", "CYAN_M", "GOLD", "CREAM", "GRASS_D", "SL4"]
	var shirt := shirts[j % shirts.size()]
	_put(px, 0, 0, "SL1")
	_put(px, 0, -1, shirt)
	_put(px, 0, -2, shirt)
	_put(px, 0, -3, "SKIN")
	_put(px, 1, 0, "INK")


# a price tag on a pin, anchored at the lot's middle on the ground
static func _tag(px: Dictionary, text: String) -> void:
	var w := micro_w(text) + 6
	var x0 := -w / 2
	frame(px, x0, -25, x0 + w, -15, Pal.i("GOLD"), Pal.i("SL1"))
	micro(px, x0 + 3, -22, text, Pal.i("GOLD"))
	_put(px, 0, -14, "GOLD")
	_put(px, 0, -13, "GOLD_M")


# the office's rooftop sign: a Battlegrounds panel on two legs, anchored at the roof's middle
static func _billboard(px: Dictionary) -> void:
	var bw := 43
	var bh := 13
	var bx0 := -bw / 2
	var by0 := -bh - 7
	for lx: int in [bx0 + 5, bx0 + bw - 6]:
		for k in 8:
			_put(px, lx, by0 + bh + k - 1, "SL1")
	frame(px, bx0, by0, bx0 + bw, by0 + bh, Pal.i("GOLD"), Pal.i("SL1"))
	var icon: Array[String] = ["..1..", ".111.", "11111", ".1.1.", ".111."]
	for j in icon.size():
		for i in 5:
			if icon[j][i] == "1":
				_put(px, bx0 + 4 + i, by0 + 4 + j, "CYAN")
	micro(px, bx0 + 11, by0 + 4, "REALTOR", Pal.i("GOLD"))


# a gold arrow floating over the office, so it is found at a glance even zoomed out
static func _pin(px: Dictionary) -> void:
	var rows: Array[String] = [".1111111.", "122222221", ".1222221.", "..12221..", "...121...",
		"....1...."]
	for j in rows.size():
		for i in rows[j].length():
			var ch := rows[j][i]
			if ch == "1":
				_put(px, i - 4, j - 6, "GOLD_D")
			elif ch == "2":
				_put(px, i - 4, j - 6, "GOLD")
