class_name Ui
extends RefCounted

# Shared immediate-mode drawing for every screen, style A: the look of Tiny Battlegrounds (its
# UiKit mirrored here). Dark slate checker behind everything, Kenney nine-slice panels and
# buttons with corner studs (1:1 pixels, 16 px slices), bold TinyFont pixel text in capitals with
# a dark outline and a drop shadow, cyan / gold / mint accents. Every screen leaves by the same
# top-left back button with its title beside it; the footer keeps "© OpenStreetMap contributors"
# on screen (ODbL) in the mockup's 3x5 micro font. Pixel fonts are only drawn at whole multiples
# of their design size (12 -> 24, 36), so one font pixel is a 2x2 or 3x3 block like the art.
# Everything is in the fixed 600x600 canvas; anything clickable is at least MIN_HIT so it still
# works when the window is shrunk to 200 px.

const CANVAS := Vector2(600, 600)
# the header zone: the back button and the title; it is also the window's drag handle
const BAR_H := 76.0
const FOOT_H := 22.0
const MIN_HIT := 44.0
const BACK_RECT := Rect2(12, 12, 58, 58)
const HEAD_GAP := 12.0
const SLICE := 16.0
const CHIP_MIN := 48.0
const CHECK := 76.0

# text: sizes are whole multiples of each font's design size
const BIG := 36
const TEXT := 24
const SMALL := 20
const FONT_SIZE := TEXT
enum { BOLD, NARROW, TEN }
const _FONTS := ["res://fonts/tiny12_bold.ttf", "res://fonts/tiny_narrow_bold.ttf",
	"res://fonts/tiny10_bold.ttf"]
# cap height in design pixels per design size
const _CAP := [7.0 / 12.0, 7.0 / 12.0, 6.0 / 10.0]

# Battlegrounds' palette (UiKit) and the mockup's slate
const VOID := Color("0b0e14")
const SL0 := Color("12151b")
const SL1 := Color("1d232d")
const SL2 := Color("2c3543")
const SL3 := Color("45546e")
const PLATE := Color("161d2a")
const SHEET := Color("141b27")
const SUNKEN := Color("0d121b")
const STEEL := Color("31405a")
const RIM := Color("9db0c6")
const RIM_DIM := Color("46536b")
const BACK_FILL := Color(0.09, 0.12, 0.17, 1.0)
const CYAN := Color("3fe0ff")
const CYAN_D := Color("16607e")
const MINT := Color("62f08a")
const GOLD := Color("ffc94a")
const GOLD_M := Color("c99e3a")
const GOLD_D := Color("3d3012")
const CREAM := Color("f0e6d2")
const MUTED := Color("7d8fa6")
const RED := Color("ca473b")
const BLOOD := Color("ff5a4a")
const HOT_LIFT := 0.16
# old names some screens still use
const INK := CREAM
const DIM := MUTED
const GREEN := MINT
const BAR := VOID
const SHADE := Color(0.043, 0.055, 0.078, 0.88)

# OSM's licence (ODbL) asks for this line wherever its data is shown
const CREDIT := "© OPENSTREETMAP CONTRIBUTORS"
const TEST_TAG := "DATOS DE PRUEBA"
const _BACK_ICON: Array[String] = [
	"....1..........",
	"...11...11111..",
	"..111.......1..",
	".11111111...1..",
	"111111111...1..",
	".11111111...1..",
	"..111.......1..",
	"...11...11111..",
	"....1..........",
]
# letters the pixel fonts lack (Polish, Czech, romanised Japanese...) fall back to their base
const _FROM := "ĀāĂăĄąĆćĈĉĊċČčĎďĐđĒēĔĕĖėĘęĚěĜĝĞğĠġĢģĤĥĦħĨĩĪīĬĭĮįİıĴĵĶķĹĺĻļĽľĿŀŁłŃńŅņŇňŌōŎŏŐőŔŕŖŗŘřŚśŜŝŞşŠšŢţŤťŦŧŨũŪūŬŭŮůŰűŲųŴŵŶŷŹźŻżŽž’"
const _TO := "AaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIiJjKkLlLlLlLlLlNnNnNnOoOoOoRrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyZzZzZz'"

static var _font_cache := {}
static var _tex := {}


static func font(kind: int = BOLD) -> Font:
	if not _font_cache.has(kind):
		_font_cache[kind] = load(_FONTS[kind]) as Font
	return _font_cache[kind]


static func _texture(path: String) -> Texture2D:
	if not _tex.has(path):
		_tex[path] = load(path) as Texture2D
	return _tex[path]


# what the pixel fonts can draw: capitals, with missing letters swapped for their base letter
static func caps(s: String) -> String:
	var out := ""
	for ch in s:
		var k := _FROM.find(ch)
		out += _TO[k] if k >= 0 else ch
	return out.to_upper()


static func cap_h(size: int, kind: int = BOLD) -> float:
	return roundf(size * float(_CAP[kind]))


static func text_width(s: String, size: int, kind: int = BOLD) -> float:
	return font(kind).get_string_size(caps(s), HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


# pixel text in capitals, with the mockup's dark rim and a drop shadow one font pixel down;
# dark text (on a gold or cyan button) goes without either
static func text(c: CanvasItem, at: Vector2, s: String, size: int = TEXT,
		color: Color = CREAM, kind: int = BOLD, shadow: bool = true) -> void:
	var f := font(kind)
	var line := caps(s)
	var px := maxf(1.0, roundf(size / (12.0 if kind != TEN else 10.0)))
	var pos := at.round()
	var rim := Color(VOID, color.a)
	var dark := color.get_luminance() < 0.3
	if not dark:
		for o: Vector2 in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1),
				Vector2(-1, -1), Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1)]:
			c.draw_string(f, pos + o * px, line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, rim)
	if shadow and not dark:
		for o: Vector2 in [Vector2(0, 2), Vector2(1, 2), Vector2(-1, 2)]:
			c.draw_string(f, pos + o * px, line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, rim)
	c.draw_string(f, pos, line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


# text centred in a rect (by its cap height, so capitals sit in the middle)
static func text_in(c: CanvasItem, r: Rect2, s: String, size: int = TEXT,
		color: Color = CREAM, kind: int = BOLD, shadow: bool = true) -> void:
	var w := text_width(s, size, kind)
	var at := Vector2(r.position.x + (r.size.x - w) * 0.5,
		r.position.y + (r.size.y + cap_h(size, kind)) * 0.5)
	text(c, at, s, size, color, kind, shadow)


# right-aligned at x
static func text_right(c: CanvasItem, at: Vector2, s: String, size: int = TEXT,
		color: Color = CREAM, kind: int = BOLD) -> void:
	text(c, Vector2(at.x - text_width(s, size, kind), at.y), s, size, color, kind)


# kept for screens that label things over a map: the same outlined text
static func label(c: CanvasItem, at: Vector2, s: String, size: int, color: Color) -> void:
	text(c, at, s, size, color, NARROW, false)


# the mockup's 3x5 font, each pixel a px x px block (credits, tags)
static func micro(c: CanvasItem, at: Vector2, s: String, color: Color, px: float = 2.0,
		rim: bool = false) -> void:
	if rim:
		for o: Vector2 in [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]:
			micro(c, at + o * px, s, VOID, px)
	var x := at.x
	for ch in s.to_upper():
		var g: String = Sprites.MICRO.get(ch, Sprites.MICRO[" "])
		var w := 6 if ch == "©" else 3
		for j in 5 * w:
			if g[j] == "1":
				c.draw_rect(Rect2(x + (j % w) * px, at.y + (j / w) * px, px, px), color)
		x += (w + 1) * px


static func micro_width(s: String, px: float = 2.0) -> float:
	return Sprites.micro_w(s.to_upper()) * px


# --- panels and buttons (UiKit) ------------------------------------------------------------------

static func nine(c: CanvasItem, tex: Texture2D, rect: Rect2, tint: Color) -> void:
	if tex == null:
		return
	var ts := tex.get_size()
	var s := minf(SLICE, minf(rect.size.x, rect.size.y) * 0.5)
	var sx: Array[float] = [0.0, SLICE, ts.x - SLICE, ts.x]
	var sy: Array[float] = [0.0, SLICE, ts.y - SLICE, ts.y]
	var dx: Array[float] = [rect.position.x, rect.position.x + s, rect.end.x - s, rect.end.x]
	var dy: Array[float] = [rect.position.y, rect.position.y + s, rect.end.y - s, rect.end.y]
	for r in 3:
		for k in 3:
			var dst := Rect2(dx[k], dy[r], dx[k + 1] - dx[k], dy[r + 1] - dy[r])
			var src := Rect2(sx[k], sy[r], sx[k + 1] - sx[k], sy[r + 1] - sy[r])
			c.draw_texture_rect_region(tex, dst, src, tint)


static func chip(c: CanvasItem, rect: Rect2, back: Color, edge: Color) -> void:
	c.draw_rect(rect, back)
	c.draw_rect(rect.grow(-0.5), edge, false, 1.0)


# a Kenney panel (12 = studded, 13 = slot, 15 = plain button) in a fill and an edge colour;
# too small for the nine-slice, it falls back to a flat chip
static func plate(c: CanvasItem, rect: Rect2, back: Color, edge: Color, style: int = 12) -> void:
	if minf(rect.size.x, rect.size.y) < CHIP_MIN:
		chip(c, rect, back, edge)
		return
	nine(c, _texture("res://assets/ui/panel/panel-%03d.png" % style), rect, back)
	nine(c, _texture("res://assets/ui/border/panel-border-%03d.png" % style), rect, edge)


static func panel(c: CanvasItem, r: Rect2, edge: Color = RIM_DIM) -> void:
	plate(c, r, PLATE, edge, 12)


# a button: steel with a dim rim, cyan when hot; `accent` is the gold call to action
static func button(c: CanvasItem, r: Rect2, label: String, hot: Vector2,
		accent: bool = false, off: bool = false, kind: int = BOLD) -> void:
	var over := r.has_point(hot) and not off
	var back := STEEL
	var edge := RIM_DIM
	var ink := CREAM
	if accent:
		back = GOLD
		edge = CREAM
		ink = VOID
	elif over:
		edge = CYAN
	if over:
		back = back.lightened(HOT_LIFT)
	if off:
		back = SHEET
		edge = RIM_DIM
		ink = SL3
	plate(c, r, back, edge, 15)
	text_in(c, r, label, TEXT, ink, kind, not accent and not off)


# an arrow button (pager, zoom): cyan with a dark glyph, like Battlegrounds' settings arrows
static func arrow(c: CanvasItem, r: Rect2, glyph: String, hot: Vector2, off: bool = false) -> void:
	var over := r.has_point(hot) and not off
	var back := SHEET if off else (CYAN.lightened(HOT_LIFT) if over else CYAN)
	plate(c, r, back, RIM_DIM if off else CREAM, 15)
	text_in(c, r, glyph, BIG, SL3 if off else VOID, BOLD, false)


static func back_button(c: CanvasItem, hot: Vector2) -> void:
	var over := BACK_RECT.has_point(hot)
	var ink := CREAM if over else MUTED
	plate(c, BACK_RECT, BACK_FILL, ink, 12)
	var px := 2.0
	var size := Vector2(_BACK_ICON[0].length(), _BACK_ICON.size()) * px
	var at := (BACK_RECT.get_center() - size * 0.5).round()
	for j in _BACK_ICON.size():
		for i in _BACK_ICON[j].length():
			if _BACK_ICON[j][i] == "1":
				c.draw_rect(Rect2(at + Vector2(i, j) * px, Vector2(px, px)), ink)


# the screen header: the way out (when there is one) and the screen's name beside it
static func header(c: CanvasItem, title: String, back: bool, hot: Vector2) -> void:
	var x := 16.0
	if back:
		back_button(c, hot)
		x = BACK_RECT.end.x + HEAD_GAP
	var size := BIG
	if text_width(title, BIG) > 470.0 - x:
		size = TEXT
	text(c, Vector2(x, BACK_RECT.get_center().y + cap_h(size) * 0.5), title, size, CREAM)


# the dark slate checker every screen stands on (Battlegrounds' backdrop, the mockup's 38 px x2)
static func backdrop(c: CanvasItem) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, CANVAS), VOID)
	var n := ceili(CANVAS.x / CHECK)
	for y in n:
		for x in n:
			if (x + y) % 2 == 0:
				c.draw_rect(Rect2(x * CHECK, y * CHECK, CHECK, CHECK), SL0)


# the credit line, a note, and the test-data warning when nothing on screen is real
static func footer(c: CanvasItem, note: String) -> void:
	var y := CANVAS.y - 16.0
	var w := micro_width(CREDIT)
	micro(c, Vector2(CANVAS.x - 12.0 - w, y), CREDIT, MUTED, 2.0, true)
	if note != "":
		micro(c, Vector2(12, y), note, MUTED, 2.0, true)
	if Overpass.fixture_mode:
		var tag := Rect2(12, CANVAS.y - 44, text_width(TEST_TAG, TEXT, NARROW) + 20, 26)
		chip(c, tag, RED, CREAM)
		text_in(c, tag, TEST_TAG, TEXT, CREAM, NARROW, false)


# a framed progress bar (the mockup's office level bar)
static func bar(c: CanvasItem, r: Rect2, frac: float, ink: Color = GOLD) -> void:
	c.draw_rect(r, VOID)
	c.draw_rect(r.grow(-2), SL1)
	c.draw_rect(Rect2(r.position + Vector2(2, 2), Vector2(r.size.x - 4, 2)), SL3)
	var wide := floorf((r.size.x - 8) * clampf(frac, 0.0, 1.0) / 2.0) * 2.0
	if wide > 0.0:
		c.draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(wide, r.size.y - 8)), ink)
		c.draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(wide, 2)), CREAM)


# a gold coin, the mockup's 7x7 at 2x
static func coin(c: CanvasItem, at: Vector2) -> void:
	var rows: Array[String] = ["..111..", ".12221.", "1223221", "1232221", "1223221", ".12221.",
		"..111.."]
	for j in rows.size():
		for i in rows[j].length():
			var ch := rows[j][i]
			if ch != ".":
				var col := GOLD_M if ch == "1" else (GOLD if ch == "2" else CREAM)
				c.draw_rect(Rect2(at + Vector2(i, j) * 2.0, Vector2(2, 2)), col)


# "1,2 MB" style sizes, Spanish decimal comma
static func size_text(bytes: int) -> String:
	if bytes < 1024 * 1024:
		return "%d KB" % ceili(bytes / 1024.0)
	return ("%.1f MB" % (bytes / 1048576.0)).replace(".", ",")


# "12.345" with Spanish thousands dots
static func count(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "." + s.right(3) + out
		s = s.left(s.length() - 3)
	return ("-" if n < 0 else "") + s + out
