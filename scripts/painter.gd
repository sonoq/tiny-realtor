class_name Painter
extends RefCounted

# Records the drawing of one world object (a building, a tree, a car) as a short list of ops in
# low-res pixels, so BlockView can replay it twice: first as a one-pixel ink silhouette (the ops
# shifted left, right, up and down, all in INK), then in colour, faded or not. That is the
# mockup's "outline each sprite, then paste it" without ever reading pixels back.
# The primitives are ports of gen_battlegrounds.py: wall (wall_pixels), prism, face3d, pitched.
# Polygons and walls also carry the depth (x - y, bigger is nearer) of their ground points, for
# BlockView's depth pass that lets moving cars hide behind what stands in front of them:
#   OP_POLY [op, screen points, colour, depth per point], OP_WALL [..., Vector2(left, right)].

enum { OP_POLY, OP_WALL, OP_RECT, OP_TEX }

const UV_BASE := 16384.0
const VIEW := Vector3(1, 1, 1)
const DIRS: Array[Vector2] = [Vector2(-1, 0), Vector2(1, 0), Vector2(0, -1), Vector2(0, 1)]

var iso: Iso
var ops: Array = []
# 0..63, picks the hashed details (lit windows, awnings) of this object's walls
var seed6 := 0


func _init(camera: Iso) -> void:
	iso = camera


func begin(seed_key: String) -> Array:
	ops = []
	seed6 = int(Iso.h01(seed_key + "s6") * 64.0) & 63
	return ops


# --- flat things -----------------------------------------------------------------------------------

# a polygon already in screen pixels; skipped when rounding folded it to nothing
func screen_poly(pts: PackedVector2Array, idx: int,
		depth: PackedFloat32Array = PackedFloat32Array()) -> void:
	if pts.size() < 3 or Geometry2D.triangulate_polygon(pts).is_empty():
		return
	if depth.size() == pts.size():
		ops.append([OP_POLY, pts, idx, depth])
	else:
		ops.append([OP_POLY, pts, idx])


func flat(poly: PackedVector2Array, z: float, idx: int) -> void:
	var depth := PackedFloat32Array()
	for q in poly:
		depth.append(q.x - q.y)
	screen_poly(iso.poly(poly, z), idx, depth)


func dot(at: Vector2, idx: int) -> void:
	ops.append([OP_RECT, Rect2(at, Vector2.ONE), idx])


func block(r: Rect2, idx: int) -> void:
	ops.append([OP_RECT, r, idx])


# a one-pixel Bresenham line, as PIL draws it, kept as horizontal runs
func line(a: Vector2, b: Vector2, idx: int) -> void:
	for r in Painter.line_runs(a, b):
		ops.append([OP_RECT, r, idx])


func tex(key: String, at: Vector2) -> void:
	ops.append([OP_TEX, key, at])


# a one-pixel ink silhouette under the ops recorded since `start`, as BlockView's outline pass
# gives a whole object: towers that share one object (a podium, sky bridges) still read apart
# where one stands in front of another. A sprite's ink copy carries a fourth "ink" element.
func ink_under(start: int) -> void:
	var body := ops.slice(start)
	var ink: Array = []
	var black := Pal.i("INK")
	for d in DIRS:
		for op: Array in body:
			match op[0]:
				OP_POLY:
					var moved := [OP_POLY, Iso.moved(op[1], d), black]
					if op.size() > 3:
						moved.append(op[3])
					ink.append(moved)
				OP_RECT:
					var r: Rect2 = op[1]
					ink.append([OP_RECT, Rect2(r.position + d, r.size), black])
				OP_WALL:
					if op[4]:
						continue
					var code: Color = op[3]
					code.r8 = (code.r8 & ~15) | WorldShader.STYLE_INK
					ink.append([OP_WALL, Iso.moved(op[1], d), op[2], code, true, op[5]])
				OP_TEX:
					ink.append([OP_TEX, op[1], op[2] + d, true])
	ops.resize(start)
	ops.append_array(ink)
	ops.append_array(body)


static func line_runs(a: Vector2, b: Vector2) -> Array[Rect2]:
	var out: Array[Rect2] = []
	var x0 := int(a.x)
	var y0 := int(a.y)
	var x1 := int(b.x)
	var y1 := int(b.y)
	var dx := absi(x1 - x0)
	var dy := -absi(y1 - y0)
	var sx := 1 if x0 < x1 else -1
	var sy := 1 if y0 < y1 else -1
	var err := dx + dy
	var run := Rect2(x0, y0, 1, 1)
	while not (x0 == x1 and y0 == y1):
		var e2 := 2 * err
		if e2 >= dy:
			err += dy
			x0 += sx
		if e2 <= dx:
			err += dx
			y0 += sy
		if y0 == int(run.position.y) and (x0 == int(run.end.x) or x0 == int(run.position.x) - 1):
			run = run.expand(Vector2(x0, y0)).expand(Vector2(x0 + 1, y0 + 1))
		else:
			out.append(run)
			run = Rect2(x0, y0, 1, 1)
	out.append(run)
	return out


# --- walls -----------------------------------------------------------------------------------------

# one vertical wall a->b (ground metres) from z0 to z1 (pixels), painted by the facade shader
func wall(a: Vector2, b: Vector2, z0: float, z1: float, style: int, k: int, ramp: int,
		variant: int = 0, door: bool = false, inkless: bool = false) -> void:
	var pa := iso.p(a.x, a.y, z0)
	var pb := iso.p(b.x, b.y, z0)
	var flip := pb.x < pa.x
	if flip:
		var t := pa
		pa = pb
		pb = t
	var xs := floorf(pa.x + 0.5)
	var xe := floorf(pb.x + 0.5)
	var n := int(xe - xs)
	if n <= 0:
		return
	var h := clampi(roundi(z1 - z0), 0, 255)
	var u0 := UV_BASE + seed6 * 1024.0
	var ua := u0 + (float(n) if flip else 0.0)
	var ub := u0 + (0.0 if flip else float(n))
	var quad := PackedVector2Array([Vector2(xs, pa.y - h - 2.0), Vector2(xe, pb.y - h - 2.0),
		Vector2(xe, pb.y + 2.0), Vector2(xs, pa.y + 2.0)])
	var uv := PackedVector2Array([Vector2(ua, h + 2.0), Vector2(ub, h + 2.0), Vector2(ub, -2.0),
		Vector2(ua, -2.0)])
	var r := style | (k << 4) | ((1 << 7) if door else 0)
	var g := ramp | (variant << 5)
	var code := Color8(r, g, h, clampi(n, 1, 255))
	var da := a.x - a.y
	var db := b.x - b.y
	ops.append([OP_WALL, quad, uv, code, inkless, Vector2(db, da) if flip else Vector2(da, db)])


# vertical walls with a facade style and a flat roof with a one-pixel parapet rim
func prism(poly: PackedVector2Array, z0: float, z1: float, style: int, ramp: int,
		roof: int = -1, rim: bool = true, variant: int = 0, door_ok: bool = true) -> void:
	poly = Iso.clean(poly)
	var walls: Array = []
	for wi in poly.size():
		var a := poly[wi]
		var b := poly[(wi + 1) % poly.size()]
		var du := b.x - a.x
		var dv := -(b.y - a.y)
		var nrm := Vector2(dv, -du).normalized()
		if nrm.x + nrm.y <= 1e-3:
			continue
		var k := maxi(1, Iso.shade(Vector3(nrm.x, nrm.y, 0.0)))
		walls.append([(a.x + b.x) * 0.5 - (a.y + b.y) * 0.5, a, b, k])
	walls.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	for j in walls.size():
		var w: Array = walls[j]
		wall(w[1], w[2], z0, z1, style, w[3], ramp, variant, door_ok and j == 0 and w[3] == 1)
	if roof < 0:
		return
	var rp := Pal.ramp(roof)
	flat(poly, z1, rp[0])
	if not rim:
		return
	var inner := Iso.offset(poly, -0.9)
	if inner.size() < 3 or Iso.area(inner) <= 4.0:
		return
	flat(inner, z1, rp[1])
	# the parapet's inner face on the far side is in shadow
	for i in inner.size():
		var a := inner[i]
		var b := inner[(i + 1) % inner.size()]
		if -(b.y - a.y) - (b.x - a.x) < -1e-3:
			line(iso.pi(a.x, a.y, z1) + Vector2(0, 1), iso.pi(b.x, b.y, z1) + Vector2(0, 1), rp[2])


# a planar face in (x, y, z), culled when it looks away and lit by its normal; ZERO when culled
func face3d(pts: Array[Vector3], ramp: int, inside: Vector3, plain: int = -1,
		bias: int = 0) -> Vector3:
	var q: Array[Vector3] = []
	for t in pts:
		q.append(Vector3(t.x, -t.y, t.z))
	var nrm := (q[1] - q[0]).cross(q[2] - q[0])
	var cen := Vector3.ZERO
	for t in q:
		cen += t
	cen /= q.size()
	var ip := Vector3(inside.x, -inside.y, inside.z)
	if nrm.dot(cen - ip) < 0.0:
		nrm = -nrm
	if nrm.dot(VIEW) <= 1e-6:
		return Vector3.ZERO
	nrm = nrm.normalized()
	var idx := plain
	if idx < 0:
		idx = Pal.ramp(ramp)[mini(3, Iso.shade(nrm) + bias)]
	var scr := PackedVector2Array()
	var depth := PackedFloat32Array()
	for t in pts:
		scr.append(iso.pi(t.x, t.y, t.z))
		depth.append(t.x - t.y)
	screen_poly(scr, idx, depth)
	return nrm


# a house: plain or house-style walls under a gabled (hip 0) or hipped roof with tile courses;
# returns [ridge end 1, ridge end 2, ridge z]
func pitched(rect: PackedVector2Array, z0: float, z1: float, wall_ramp: int, roof_ramp: int,
		rh: float, hip: float, style: int) -> Array:
	var A := rect[0]
	var B := rect[1]
	var C := rect[2]
	var D := rect[3]
	prism(rect, z0, z1, style, wall_ramp)
	var c := (A + B + C + D) * 0.25
	var eave := 0.6
	var A2 := A + (A - c) * eave / 6.0
	var B2 := B + (B - c) * eave / 6.0
	var C2 := C + (C - c) * eave / 6.0
	var D2 := D + (D - c) * eave / 6.0
	var R1 := (A2 + D2) * 0.5
	var R2 := (B2 + C2) * 0.5
	if hip > 0.0:
		var r1 := R1.lerp(R2, hip)
		var r2 := R1.lerp(R2, 1.0 - hip)
		R1 = r1
		R2 = r2
	var zt := z1 + rh
	var inside := Vector3(c.x, c.y, z1 + rh * 0.3)
	var faces: Array = [
		[Vector3(A2.x, A2.y, z1), Vector3(B2.x, B2.y, z1), Vector3(R2.x, R2.y, zt),
			Vector3(R1.x, R1.y, zt)],
		[Vector3(C2.x, C2.y, z1), Vector3(D2.x, D2.y, z1), Vector3(R1.x, R1.y, zt),
			Vector3(R2.x, R2.y, zt)],
		[Vector3(B2.x, B2.y, z1), Vector3(C2.x, C2.y, z1), Vector3(R2.x, R2.y, zt)],
		[Vector3(D2.x, D2.y, z1), Vector3(A2.x, A2.y, z1), Vector3(R1.x, R1.y, zt)],
	]
	faces.sort_custom(func(f: Array, g: Array) -> bool: return _face_depth(f) < _face_depth(g))
	var roof := Pal.ramp(roof_ramp)
	for f: Array in faces:
		var pts: Array[Vector3] = []
		pts.assign(f)
		if hip <= 0.0 and pts.size() == 3:
			face3d(pts, wall_ramp, inside)
			continue
		var nrm := face3d(pts, roof_ramp, inside, -1, 1)
		if nrm == Vector3.ZERO:
			continue
		# tile courses: darker lines parallel to the eave
		var idx := roof[mini(3, Iso.shade(nrm) + 2)]
		var e0 := pts[0]
		var e1 := pts[1]
		var t0 := pts[3] if pts.size() == 4 else pts[2]
		var t1 := pts[2]
		var nc := maxi(2, int((zt - z1) / 2.5))
		for j in range(1, nc):
			var t := float(j) / nc
			var a3 := e0.lerp(t0, t)
			var b3 := e1.lerp(t1, t)
			line(iso.pi(a3.x, a3.y, a3.z), iso.pi(b3.x, b3.y, b3.z), idx)
		line(iso.pi(e0.x, e0.y, e0.z), iso.pi(e1.x, e1.y, e1.z), roof[3])
	line(iso.pi(R1.x, R1.y, zt), iso.pi(R2.x, R2.y, zt), roof[0])
	return [R1, R2, zt]


static func _face_depth(f: Array) -> float:
	var s := 0.0
	for t: Vector3 in f:
		s += t.x - t.y
	return s / f.size()
