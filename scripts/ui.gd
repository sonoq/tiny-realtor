class_name Ui
extends RefCounted

# Shared immediate-mode drawing for every screen: the header bar with its back button, buttons,
# text with an outline, and the footer that carries the OpenStreetMap credit. Everything is in
# the fixed 600x600 canvas; anything clickable is at least MIN_HIT tall so it still works when
# the window is shrunk to 200 px (a third of the size).

const CANVAS := Vector2(600, 600)
const BAR_H := 48.0
const FOOT_H := 22.0
const MIN_HIT := 44.0
const BACK_RECT := Rect2(2, 2, 44, 44)
const FONT_SIZE := 15
const SMALL := 12

const BAR := Color("#201c28")
const PANEL := Color("#2b2636")
const PANEL_HI := Color("#3a3449")
const EDGE := Color("#4d4660")
const GOLD := Color("#ffd84a")
const INK := Color("#e4e2ec")
const DIM := Color("#9a98a8")
const RED := Color("#e5534b")
const GREEN := Color("#5fc46a")
const SHADE := Color(0.04, 0.035, 0.06, 0.82)
# OSM's licence (ODbL) asks for this line wherever its data is shown
const CREDIT := "© OpenStreetMap contributors"
const TEST_TAG := "DATOS DE PRUEBA"


static func font() -> Font:
	return ThemeDB.fallback_font


# the bar every screen starts with; the back button is drawn only when there is somewhere to go
static func header(c: CanvasItem, title: String, back: bool, hot: Vector2) -> void:
	c.draw_rect(Rect2(0, 0, CANVAS.x, BAR_H), BAR)
	c.draw_line(Vector2(0, BAR_H), Vector2(CANVAS.x, BAR_H), GOLD)
	var x := 12.0
	if back:
		button(c, BACK_RECT, "<", hot)
		x = BACK_RECT.end.x + 10.0
	text(c, Vector2(x, BAR_H * 0.5 + 6.0), title, 17, GOLD)


# the credit line, and the test-data warning when nothing on screen is real
static func footer(c: CanvasItem, note: String) -> void:
	var y := CANVAS.y - FOOT_H
	c.draw_rect(Rect2(0, y, CANVAS.x, FOOT_H), Color(BAR, 0.88))
	text(c, Vector2(8, y + 15), CREDIT, SMALL, DIM)
	if note != "":
		var w := font().get_string_size(note, HORIZONTAL_ALIGNMENT_LEFT, -1, SMALL).x
		text(c, Vector2(CANVAS.x - 8 - w, y + 15), note, SMALL, INK)
	if Overpass.fixture_mode:
		var tag := Rect2(CANVAS.x * 0.5 - 62, y, 124, FOOT_H)
		c.draw_rect(tag, RED)
		text_in(c, tag, TEST_TAG, SMALL, Color.WHITE)


static func button(c: CanvasItem, r: Rect2, label: String, hot: Vector2,
		accent: bool = false, off: bool = false) -> void:
	var over := r.has_point(hot) and not off
	var fill := GOLD if accent else (PANEL_HI if over else PANEL)
	if accent and over:
		fill = GOLD.lightened(0.25)
	c.draw_rect(r, fill)
	c.draw_rect(r, EDGE if not accent else GOLD.darkened(0.4), false, 2.0)
	var ink := BAR if accent else (DIM if off else INK)
	text_in(c, r, label, FONT_SIZE, ink)


static func text(c: CanvasItem, at: Vector2, s: String, size: int, color: Color) -> void:
	c.draw_string(font(), at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


# a label with a dark rim, readable over any map colour
static func label(c: CanvasItem, at: Vector2, s: String, size: int, color: Color) -> void:
	c.draw_string_outline(font(), at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4,
		Color(0.08, 0.07, 0.1, 0.9))
	c.draw_string(font(), at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func text_in(c: CanvasItem, r: Rect2, s: String, size: int, color: Color) -> void:
	var f := font()
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var at := Vector2(r.position.x + (r.size.x - w) * 0.5,
		r.position.y + (r.size.y + f.get_ascent(size) - f.get_descent(size)) * 0.5)
	c.draw_string(f, at.round(), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func text_width(s: String, size: int) -> float:
	return font().get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


# a centred panel with a title and wrapped lines, for loading and error messages
static func panel(c: CanvasItem, r: Rect2) -> void:
	c.draw_rect(r, PANEL)
	c.draw_rect(r, EDGE, false, 2.0)


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
