class_name World
extends RefCounted

# The world map's geometry, shared by the screen (WorldMap) and the tool that bakes its pictures
# (tools/build_world.gd): a Miller cylindrical projection (north up, rectangular like a plain
# lat/lon grid but with Europe much less squashed), cropped to LAT_N at the top and to whatever
# makes the map exactly twice as wide as tall at the bottom (about 58 S: Cape Horn fits,
# Antarctica does not). The map is baked once per zoom level at BASE x 2^level art pixels, each
# art pixel shown as 2x2 screen pixels like every other drawing in the game, so zooming in adds
# detail instead of blowing pixels up; the last zoom step (x16) shows the last picture at 4x4,
# the city map's way, so that close cities (Barcelona and Valencia) get apart. Also the greedy
# grouping of map markers into clusters so that no two hit boxes overlap at any zoom.

const LAT_N := 84.0
# baked pictures, and zoom steps (x1 ... x16) shown from them
const LEVELS := 4
const STEPS := 5
# art pixels of the whole map at level 0 (shown at 2x: the 600 px canvas is exactly the world)
const BASE := Vector2i(300, 150)
const ART_PX := 2.0
const PATH := "res://assets/world/world_%d.png"

static var _yn := 0.0
static var _ys := 0.0


static func _miller(lat: float) -> float:
	return 1.25 * log(tan(PI * 0.25 + 0.4 * deg_to_rad(lat)))


static func _ensure() -> void:
	if _yn != 0.0:
		return
	_yn = _miller(LAT_N)
	_ys = _yn - PI


# where a place falls on the map, 0..1 across and down
static func unit(lat: float, lon: float) -> Vector2:
	_ensure()
	var y := _miller(clampf(lat, -89.0, 89.0))
	return Vector2((lon + 180.0) / 360.0, (_yn - y) / (_yn - _ys))


static func lat_at(v: float) -> float:
	_ensure()
	var y := _yn - v * (_yn - _ys)
	return rad_to_deg(2.5 * atan(exp(0.8 * y)) - 0.625 * PI)


static func lon_at(u: float) -> float:
	return u * 360.0 - 180.0


# the map's size in art pixels at a zoom level
static func art_size(level: int) -> Vector2i:
	return BASE * (1 << level)


# the picture a zoom step shows
static func texture_level(step: int) -> int:
	return mini(step, LEVELS - 1)


# the map's size in canvas pixels at a zoom step
static func screen_size(step: int) -> Vector2:
	return Vector2(BASE) * ART_PX * float(1 << step)


# Groups points (canvas positions, in the order given: the first of each group is its anchor and
# stays where it is) so that no two anchors are closer than `gap` on both axes: square hit boxes
# `gap` wide never overlap. Returns [{at, members: [indices]}].
static func clusters(points: PackedVector2Array, gap: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in points.size():
		var p := points[i]
		var best := -1
		var best_d := INF
		for k in out.size():
			var d: Vector2 = (out[k]["at"] as Vector2) - p
			if absf(d.x) < gap and absf(d.y) < gap and d.length() < best_d:
				best_d = d.length()
				best = k
		if best >= 0:
			(out[best]["members"] as Array).append(i)
		else:
			out.append({"at": p, "members": [i]})
	return out
