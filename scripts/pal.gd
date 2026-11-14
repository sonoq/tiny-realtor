class_name Pal
extends RefCounted

# The one fixed palette of style A ("sibling of Tiny Battlegrounds"), straight from the mockup
# (docs/style_mockups/a_battlegrounds/gen_battlegrounds.py): the UI slate and accents lifted from
# Battlegrounds plus the city ramps. Every pixel of the office view is one of these colours; the
# world is drawn in palette indices where it has to be remapped (shadow, dim, fade) and the
# remaps are tables over the same palette, so nothing ever blends to an off-palette colour.

const NAMES: Array[String] = [
	"INK", "SL0", "SL1", "SL2", "SL3", "SL4", "SL5", "CREAM",
	"GOLD", "GOLD_M", "GOLD_D", "CYAN", "CYAN_M", "CYAN_D", "CYAN_DD",
	"MINT", "GRN_M", "GRN_D", "RED", "RED_M", "RED_D",
	"PAVE_L", "PAVE", "PAVE_D", "PAVE_S", "ASPH_L", "ASPH", "ASPH_S",
	"GRASS_L", "GRASS", "GRASS_D", "GRASS_DD", "DIRT_L", "DIRT", "DIRT_D", "TRUNK",
	"CRM0", "CRM1", "CRM2", "CRM3", "OCH0", "OCH1", "OCH2", "OCH3",
	"SAL0", "SAL1", "SAL2", "SAL3", "STN0", "STN1", "STN2", "STN3",
	"TER0", "TER1", "TER2", "TER3", "TIL0", "TIL1", "TIL2", "TIL3",
	"TEAL0", "TEAL1", "TEAL2", "TEAL3", "GLS0", "GLS1", "GLS2", "GLS3",
	"CON0", "CON1", "CON2", "CON3", "WOOD", "SKIN",
]
const HEX: Array[String] = [
	"0b0e14", "12151b", "1d232d", "2c3543", "45546e", "7d8fa6", "c3cdd8", "f0e6d2",
	"ffc94a", "c99e3a", "3d3012", "3fe0ff", "1fa3c4", "16607e", "0f2f40",
	"62f08a", "2b693c", "09160c", "ca473b", "6f2720", "2a0d0b",
	"efe2c2", "dccaa3", "c4ae88", "9a8b84", "5c6377", "4a5063", "363b4b",
	"a8d468", "74b04c", "4b8743", "2f5c3c", "d6a86c", "b4814f", "85593b", "5a3829",
	"fbf1da", "eed8ae", "c9a98a", "987b73", "f8d495", "e5b26d", "b98657", "875f50",
	"f6bc9c", "e19676", "b26b5e", "7f4f52", "ece6dc", "d2cabf", "a69ea0", "767287",
	"eab38c", "d4906b", "ad6c58", "7a4a48", "e57f57", "c75f40", "9b4636", "6a3234",
	"9cf0f4", "4ec6dc", "2c8db0", "1d5b7e", "c4ecf4", "7ab8d8", "4b7aaa", "2c4a72",
	"f4f2ec", "d8dadb", "a5abb8", "727b8f", "8c5a3c", "ecb48c",
]
# four-colour ramps (hi, lit, mid, dark) for walls and roofs; the facade shader reads them by
# number from the lookup texture, so their order is part of the shader's contract
const RAMPS: Array[String] = ["CRM", "OCH", "SAL", "STN", "TER", "TIL", "TEAL", "GLS", "CON"]
# car bodies: each tint makes a ramp of its own, lighter and darker by the mockup's factors
const CAR_TINTS: Array[String] = ["RED", "CREAM", "CYAN_M", "GOLD", "SL5", "SL1"]
# more ramps made of palette colours (hi, lit, mid, dark), after the car tints so those keep their
# numbers: gold trim, dark steel, and cyan, green and bronze glass for the top tiers
const EXTRA: Array[String] = ["GLD", "STL", "CYN", "GRN", "BRZ"]
const _EXTRA_OF := {"GLD": ["GOLD", "GOLD", "GOLD_M", "GOLD_D"], "STL": ["SL4", "SL3", "SL2", "SL1"],
	"CYN": ["CYAN", "CYAN_M", "CYAN_D", "CYAN_DD"], "GRN": ["TEAL0", "MINT", "GRASS_D", "GRASS_DD"],
	"BRZ": ["GOLD_M", "OCH2", "OCH3", "TRUNK"]}
# rows of the lookup texture: colour, shadow index, dim index, fade index, ramps
const ROW_COLOR := 0
const ROW_SHADOW := 1
const ROW_DIM := 2
const ROW_FADE := 3
const ROW_RAMP := 4
const LUT_W := 128

static var _rgb: Array[Vector3i] = []
static var _index := {}
static var _shadow: PackedInt32Array
static var _dim: PackedInt32Array
static var _fade: PackedInt32Array
static var _ramps: Array[PackedInt32Array] = []
static var _lut: ImageTexture


static func _ensure() -> void:
	if not _rgb.is_empty():
		return
	for k in NAMES.size():
		var c := Color(HEX[k])
		_rgb.append(Vector3i(roundi(c.r8), c.g8, c.b8))
		_index[NAMES[k]] = k
	for r in RAMPS:
		_ramps.append(PackedInt32Array([i(r + "0"), i(r + "1"), i(r + "2"), i(r + "3")]))
	for t in CAR_TINTS:
		var b := _rgb[i(t)]
		var ramp := PackedInt32Array()
		for f: float in [1.15, 1.0, 0.75, 0.55]:
			ramp.append(_nearest(Vector3(mini(255, int(b.x * f)), mini(255, int(b.y * f)),
				mini(255, int(b.z * f))), []))
		_ramps.append(ramp)
	for e in EXTRA:
		var names: Array = _EXTRA_OF[e]
		_ramps.append(PackedInt32Array([i(names[0]), i(names[1]), i(names[2]), i(names[3])]))
	_build_remaps()


static func i(name: String) -> int:
	_ensure()
	return _index[name]


static func color(idx: int) -> Color:
	_ensure()
	var c := _rgb[idx]
	return Color8(c.x, c.y, c.z)


static func c(name: String) -> Color:
	return color(i(name))


# the colour a ground pass writes for a palette index: the index itself in red, read back by the
# ground shader
static func code(idx: int) -> Color:
	return Color8(idx, 0, 0)


# a palette colour scaled by f, snapped back to the palette
static func darker(idx: int, f: float) -> int:
	_ensure()
	var c := _rgb[idx]
	return _nearest(Vector3(int(c.x * f), int(c.y * f), int(c.z * f)), [])


# the palette entry closest to any colour
static func nearest(col: Color) -> int:
	_ensure()
	return _nearest(Vector3(col.r8, col.g8, col.b8), [])


static func ramp(n: int) -> PackedInt32Array:
	_ensure()
	return _ramps[n]


static func ramp_of(prefix: String) -> int:
	var k := RAMPS.find(prefix)
	if k < 0 and EXTRA.has(prefix):
		return RAMPS.size() + CAR_TINTS.size() + EXTRA.find(prefix)
	return k


static func car_ramp(tint: int) -> int:
	return RAMPS.size() + tint


static func shadow(idx: int) -> int:
	_ensure()
	return _shadow[idx]


static func dim(idx: int) -> int:
	_ensure()
	return _dim[idx]


static func fade(idx: int) -> int:
	_ensure()
	return _fade[idx]


# the palette and its remaps as one small texture for the shaders (index = x, table = y)
static func lut() -> ImageTexture:
	_ensure()
	if _lut != null:
		return _lut
	var img := Image.create(LUT_W, ROW_RAMP + 1, false, Image.FORMAT_RGBA8)
	for k in _rgb.size():
		img.set_pixel(k, ROW_COLOR, color(k))
		img.set_pixel(k, ROW_SHADOW, code(_shadow[k]))
		img.set_pixel(k, ROW_DIM, code(_dim[k]))
		img.set_pixel(k, ROW_FADE, code(_fade[k]))
	for r in _ramps.size():
		for s in 4:
			img.set_pixel(r * 4 + s, ROW_RAMP, code(_ramps[r][s]))
	_lut = ImageTexture.create_from_image(img)
	return _lut


# the shader's names for palette entries, so its code reads like the mockup's
static func shader_consts() -> String:
	_ensure()
	var out := ""
	for k in NAMES.size():
		out += "const int %s = %d;\n" % [NAMES[k], k]
	return out


# --- remaps, as in the mockup: shadow on the ground, dim ground and faded buildings outside the
# active radius; each one snaps to the nearest palette colour, with hand-picked fixes

static func _build_remaps() -> void:
	var n := _rgb.size()
	_shadow.resize(n)
	_dim.resize(n)
	_fade.resize(n)
	var shadow_fix := {"PAVE": "PAVE_S", "PAVE_D": "PAVE_S", "PAVE_L": "PAVE_D", "ASPH": "ASPH_S",
		"ASPH_L": "ASPH", "GRASS": "GRASS_D", "GRASS_L": "GRASS", "GRASS_D": "GRASS_DD",
		"CREAM": "SL4", "DIRT": "DIRT_D", "DIRT_L": "DIRT"}
	var dim_fix := {"GRASS_L": "GRASS_D", "GRASS": "GRASS_DD", "GRASS_D": "GRASS_DD",
		"GRASS_DD": "SL2"}
	var no_dim: Array[int] = []
	for s: String in ["GOLD", "CYAN", "MINT", "TEAL0", "GOLD_M"]:
		no_dim.append(_index[s])
	var no_fade: Array[int] = []
	for s: String in ["GOLD", "CYAN", "MINT", "TEAL0", "TEAL1", "GOLD_M", "RED", "GLS0", "GLS1"]:
		no_fade.append(_index[s])
	var all: Array[int] = []
	for k in n:
		all.append(k)
	for k in n:
		var col := Vector3(_rgb[k])
		var name := NAMES[k]
		if shadow_fix.has(name):
			_shadow[k] = _index[shadow_fix[name]]
		else:
			_shadow[k] = _nearest(Vector3(col.x * 0.62, col.y * 0.64, col.z * 0.78), all)
		var lum := col.x * 0.3 + col.y * 0.55 + col.z * 0.15
		if dim_fix.has(name):
			_dim[k] = _index[dim_fix[name]]
			_fade[k] = _index[dim_fix[name]]
			continue
		_dim[k] = _nearest(Vector3(col.x * 0.42 + lum * 0.16 + 18, col.y * 0.42 + lum * 0.16 + 22,
			col.z * 0.46 + lum * 0.18 + 32), _without(no_dim))
		_fade[k] = _nearest(Vector3(col.x * 0.30 + lum * 0.42 + 6, col.y * 0.30 + lum * 0.42 + 12,
			col.z * 0.32 + lum * 0.46 + 30), _without(no_fade))


static func _without(skip: Array[int]) -> Array[int]:
	var out: Array[int] = []
	for k in _rgb.size():
		if not k in skip:
			out.append(k)
	return out


# the palette entry closest to a colour (squared RGB distance); empty `among` = all of them
static func _nearest(col: Vector3, among: Array) -> int:
	var best := 0
	var best_d := INF
	var pool: Array = among
	if pool.is_empty():
		for k in _rgb.size():
			pool.append(k)
	for k: int in pool:
		var d := (Vector3(_rgb[k]) - col).length_squared()
		if d < best_d:
			best_d = d
			best = k
	return best
