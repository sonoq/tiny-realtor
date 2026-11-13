class_name Iso
extends RefCounted

# The office view's camera and the plane geometry its drawing needs. Ground metres (x east,
# y north) go to low-res pixels as in the mockup: u = x, v = -y, screen = ((u - v) s,
# (u + v) s / 2 - z), with z already in pixels (a storey is 3-5 px, whatever its plot).
# Polygons handed to the drawing are "clean": counter-clockwise in (u, v), which is clockwise
# in ground metres.

# the mockup's scale: low-res pixels per metre, each shown as a 2x2 block at the default zoom
const S := 1.19
# light from the upper left of the screen: +v walls lit, +u walls in shade (gen_battlegrounds.py)
const LIGHT := Vector3(-1.0, 0.55, 1.25)

var origin := Vector2.ZERO


func p(x: float, y: float, z: float = 0.0) -> Vector2:
	return Vector2((x + y) * S, (x - y) * S * 0.5 - z) + origin


# p() rounded to the pixel, as the mockup's Pi
func pi(x: float, y: float, z: float = 0.0) -> Vector2:
	var q := p(x, y, z)
	return Vector2(floorf(q.x + 0.5), floorf(q.y + 0.5))


func pv(at: Vector2, z: float = 0.0) -> Vector2:
	return pi(at.x, at.y, z)


func poly(pts: PackedVector2Array, z: float = 0.0) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in pts:
		out.append(pi(q.x, q.y, z))
	return out


# 0 brightest .. 3 darkest, for a normal in (u, v, z)
static func shade(n: Vector3) -> int:
	var d := n.normalized().dot(LIGHT.normalized())
	if d > 0.6:
		return 0
	if d > 0.12:
		return 1
	if d > -0.42:
		return 2
	return 3


# u + v: bigger is nearer the viewer
static func depth(at: Vector2) -> float:
	return at.x - at.y


# --- plane geometry ------------------------------------------------------------------------------

static func clean(poly: PackedVector2Array) -> PackedVector2Array:
	if Geo.area(poly) > 0.0:
		var out := poly.duplicate()
		out.reverse()
		return out
	return poly


# the biggest piece of a polygon grown (+) or shrunk (-) by d metres, mitred; empty if it vanishes
static func offset(poly: PackedVector2Array, d: float) -> PackedVector2Array:
	var best := PackedVector2Array()
	var best_a := 0.0
	for part: PackedVector2Array in Geometry2D.offset_polygon(poly, d, Geometry2D.JOIN_MITER):
		var a := absf(Geo.area(part))
		if a > best_a:
			best_a = a
			best = part
	if best.size() < 3:
		return PackedVector2Array()
	return clean(best)


static func hull(poly: PackedVector2Array) -> PackedVector2Array:
	return clean(Geometry2D.convex_hull(poly).slice(0, -1))


static func area(poly: PackedVector2Array) -> float:
	return absf(Geo.area(poly))


static func centroid(poly: PackedVector2Array) -> Vector2:
	var a := 0.0
	var c := Vector2.ZERO
	var n := poly.size()
	for i in n:
		var p0 := poly[i]
		var p1 := poly[(i + 1) % n]
		var cr := p0.x * p1.y - p1.x * p0.y
		a += cr
		c += (p0 + p1) * cr
	if absf(a) < 1e-6:
		return Geo.centre(poly)
	return c / (3.0 * a)


# the minimum-area rectangle around a polygon, as A, B, C, D with A->B the long side
static func min_rect(poly: PackedVector2Array, shrink: float = 1.0) -> PackedVector2Array:
	var h := Geometry2D.convex_hull(poly)
	var best := PackedVector2Array()
	var best_a := INF
	for i in h.size() - 1:
		var e := (h[i + 1] - h[i])
		if e.length() < 1e-6:
			continue
		e = e.normalized()
		var nrm := e.orthogonal()
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for q in h:
			var s := Vector2(q.dot(e), q.dot(nrm))
			lo = lo.min(s)
			hi = hi.max(s)
		var a := (hi.x - lo.x) * (hi.y - lo.y)
		if a < best_a:
			best_a = a
			best = PackedVector2Array([e * lo.x + nrm * lo.y, e * hi.x + nrm * lo.y,
				e * hi.x + nrm * hi.y, e * lo.x + nrm * hi.y])
	if best.is_empty():
		return best
	if shrink != 1.0:
		var c := Geo.centre(best)
		for i in 4:
			best[i] = c + (best[i] - c) * shrink
	best = clean(best)
	if best[0].distance_to(best[1]) < best[1].distance_to(best[2]):
		best = PackedVector2Array([best[1], best[2], best[3], best[0]])
	return best


static func contains(outer: PackedVector2Array, inner: PackedVector2Array) -> bool:
	for q in inner:
		if not Geometry2D.is_point_in_polygon(q, outer):
			return false
	return true


static func moved(poly: PackedVector2Array, by: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in poly:
		out.append(q + by)
	return out


static func square(at: Vector2, half: float) -> PackedVector2Array:
	return clean(PackedVector2Array([at + Vector2(-half, -half), at + Vector2(half, -half),
		at + Vector2(half, half), at + Vector2(-half, half)]))


# a stable 0..1 hash of any key; String.hash alone barely changes in its low bits when only the
# last character does ("a1" / "b1"), so it is mixed first
static func h01(key: String) -> float:
	var x := key.hash() & 0xFFFFFFFF
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xFFFFFFFF
	x = ((x ^ (x >> 16)) * 0x45d9f3b) & 0xFFFFFFFF
	x = x ^ (x >> 16)
	return float(x & 0xFFFF) / 65536.0
