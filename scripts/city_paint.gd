class_name CityPaint
extends Node2D

# Draws a baked city map (format tiny-realtor-city, see CityBaker) once, top-down, north up, at
# M_PER_PX metres per pixel, for a SubViewport that CityMap scales up with nearest filtering.
# Pixel (0, 0) is the north-west corner of the city box.

const M_PER_PX := 12.0
const LAND := Color("#cbc09f")
const LAND_DOT := Color("#c2b694")
const SEA := Color("#4f7fae")
const SEA_DOT := Color("#5a8ab8")
const WATER := Color("#5b8dbb")
const PARK := Color("#94b86e")
const ROAD := {
	"motorway": [Color("#d9644a"), 3.0], "trunk": [Color("#e58a4a"), 2.0],
	"primary": [Color("#f4c95d"), 2.0], "secondary": [Color("#ffffff"), 1.0],
}
const ORDER := ["secondary", "primary", "trunk", "motorway"]

var size := Vector2.ZERO

var _city: Dictionary = {}
var _half := 0.0


func set_city(city: Dictionary) -> void:
	_city = city
	_half = float(city["half_m"])
	size = Vector2.ONE * ceilf(_half * 2.0 / M_PER_PX)
	queue_redraw()


# metres from the centre (x east, y north) to a pixel of the drawing
func to_px(m: Vector2) -> Vector2:
	return Vector2(m.x + _half, _half - m.y) / M_PER_PX


func to_m(px: Vector2) -> Vector2:
	return Vector2(px.x * M_PER_PX - _half, _half - px.y * M_PER_PX)


func _draw() -> void:
	if _city.is_empty():
		return
	draw_rect(Rect2(Vector2.ZERO, size), LAND)
	# a faint dither so the land is not a flat sheet of colour
	for y in range(0, int(size.y), 3):
		for x in range(y % 6, int(size.x), 6):
			draw_rect(Rect2(x, y, 1, 1), LAND_DOT)
	for poly: Array in _city["sea"]:
		_fill(poly, SEA)
	for poly: Array in _city["land"]:
		_fill(poly, LAND)
	for poly: Array in _city["water"]:
		_fill(poly, WATER)
	for poly: Array in _city["parks"]:
		_fill(poly, PARK)
	for line: Array in _city["rivers"]:
		draw_polyline(_px(line), WATER, 2.0)
	for kind: String in ORDER:
		var style: Array = ROAD[kind]
		for road: Dictionary in _city["roads"]:
			if road["kind"] == kind:
				draw_polyline(_px(road["line"]), style[0], style[1])


func _px(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Array in raw:
		out.append(to_px(Vector2(p[0], p[1])).round())
	return out


func _fill(raw: Array, color: Color) -> void:
	# rounding to whole pixels can fold a thin shape onto itself; repair untangles it
	var pts := Geo.repair(_px(raw))
	if pts.size() >= 3:
		draw_colored_polygon(pts, color)
