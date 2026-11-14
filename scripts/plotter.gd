class_name Plotter
extends RefCounted

# Two cuts of the same land, both pure data and safe on a worker thread:
#   split()  the bake: one city block into 1..n big lots ("terrenos"), the pieces the player buys.
#            A block up to LOT_MAX stays whole; a bigger one is halved with a straight cut across
#            its long side (streets run along the axes, so cuts run parallel to streets), again
#            and again, and a cut is only kept when every piece still faces a street.
#   sites()  the drawing: one lot into the building sites of its development, the way real
#            blocks are parcelled: a strip one site deep along each street side, cut across every
#            frontage width, each convex street corner one corner site; what is left is garden or
#            courtyard. Every street side owns the wedge between its corner bisectors (or runs
#            square to a side with no street), so the sides never fight over ground.

# a block bigger than this (m2, varied per block by LOT_SPREAD) is cut into lots
const LOT_MAX := 7600.0
const LOT_SPREAD := 0.22
# no lot piece smaller than this, and a piece must face this much street (m) to be a lot
const LOT_MIN := 900.0
const FRONT_MIN := 10.0
# where along the long side a halving cut falls, as a share of the area (0.5 +- this)
const CUT_JITTER := 0.08
const MIN_EDGE := 4.0
const MIN_SITE := 25.0
const SIMPLIFY := 1.5


# the block cut into lots (counter-clockwise rings); `fronts(poly) -> Dictionary` says how many
# metres of street a piece faces ("length") and which way its longest street side runs ("dir")
static func split(block: PackedVector2Array, seed: String, fronts: Callable,
		max_area: float = LOT_MAX) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var ring := ring_of(block)
	if ring.size() < 3:
		return out
	var cap := max_area * (1.0 + (_h01(seed + "cap") - 0.5) * 2.0 * LOT_SPREAD)
	var todo: Array = [[ring, seed]]
	while not todo.is_empty():
		var item: Array = todo.pop_back()
		var poly: PackedVector2Array = item[0]
		var key: String = item[1]
		var halves: Array[PackedVector2Array] = []
		if Geo.area(poly) > cap:
			halves = _halve(poly, key, fronts)
		if halves.is_empty():
			out.append(poly)
			continue
		for k in halves.size():
			todo.append([halves[k], key + str(k)])
	return out


# a cut across the long axis (else the short one, else square to the longest street side, which
# shares that street out) leaving pieces that are big enough and all face a street; empty when no
# such cut exists
static func _halve(poly: PackedVector2Array, key: String,
		fronts: Callable) -> Array[PackedVector2Array]:
	var rect := Iso.min_rect(poly)
	if rect.size() < 4:
		return []
	var long := (rect[1] - rect[0]).normalized()
	var share := 0.5 + (_h01(key + "cut") - 0.5) * 2.0 * CUT_JITTER
	var along: Vector2 = (fronts.call(poly) as Dictionary).get("dir", Vector2.ZERO)
	var axes: Array[Vector2] = [long, long.orthogonal()]
	if along != Vector2.ZERO:
		axes.append(along)
	for axis in axes:
		var pieces := _cut_at(poly, axis, share)
		if pieces.size() < 2:
			continue
		var ok := true
		for p in pieces:
			if absf(Geo.area(p)) < LOT_MIN \
					or float((fronts.call(p) as Dictionary)["length"]) < FRONT_MIN:
				ok = false
				break
		if ok:
			return pieces
	return []


# the polygon cut by a line square to `axis`, placed so the near side holds `share` of the area
static func _cut_at(poly: PackedVector2Array, axis: Vector2,
		share: float) -> Array[PackedVector2Array]:
	var lo := INF
	var hi := -INF
	for q in poly:
		lo = minf(lo, q.dot(axis))
		hi = maxf(hi, q.dot(axis))
	var side := axis.orthogonal()
	var mid := Geo.centre(poly)
	var span := (hi - lo) + 10.0
	var total := absf(Geo.area(poly))
	var a := lo
	var b := hi
	var t := (lo + hi) * 0.5
	# bisection on the cut position: about 0.1% of the side after a dozen steps
	for _i in 12:
		t = (a + b) * 0.5
		var near := 0.0
		for p in Geo.clip(poly, _half_plane(axis, side, mid, t, lo - 5.0, span)):
			near += absf(Geo.area(p))
		if near < total * share:
			a = t
		else:
			b = t
	var out: Array[PackedVector2Array] = []
	for p in Geo.clip(poly, _half_plane(axis, side, mid, t, lo - 5.0, span)):
		out.append(p)
	for p in Geo.clip(poly, _half_plane(axis, side, mid, hi + 5.0, t, span)):
		out.append(p)
	return out


# the rectangle between positions `from` and `to` along `axis`, wide enough to cover the polygon
static func _half_plane(axis: Vector2, side: Vector2, mid: Vector2, to: float, from: float,
		span: float) -> PackedVector2Array:
	var m := mid - axis * mid.dot(axis)
	var w := span * 2.0
	return PackedVector2Array([m + axis * from - side * w, m + axis * to - side * w,
		m + axis * to + side * w, m + axis * from + side * w])


# the lot cut into building sites: [{"poly", "edge", "corner"}], `edge` indexing `ring`
# (counter-clockwise metres); only the sides in `fronts` get sites, `depth` deep, cut every
# `front.x`..`front.y` metres along the side
static func sites(ring: PackedVector2Array, fronts: PackedInt32Array, depth: float,
		front: Vector2, seed: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n := ring.size()
	if n < 3:
		return out
	var is_front := PackedByteArray()
	is_front.resize(n)
	for i in fronts:
		if i >= 0 and i < n:
			is_front[i] = 1
	var normals := PackedVector2Array()
	for i in n:
		var d := (ring[(i + 1) % n] - ring[i]).normalized()
		normals.append(Vector2(-d.y, d.x))
	# at each vertex, how the wedge of the side starting (`starts`) or ending (`ends`) there
	# reaches in: along the bisector between two street sides, or along a side with no street
	var starts := PackedVector2Array()
	var ends := PackedVector2Array()
	starts.resize(n)
	ends.resize(n)
	for i in n:
		var prev := (i - 1 + n) % n
		var both := is_front[prev] == 1 and is_front[i] == 1
		var b := (normals[prev] + normals[i]).normalized()
		var lean := maxf(0.35, b.dot(normals[i]))
		starts[i] = b * depth / lean if both else _along(ring[prev] - ring[i], normals[i], depth)
		ends[i] = b * depth / maxf(0.35, b.dot(normals[prev])) if both \
			else _along(ring[(i + 1) % n] - ring[i], normals[prev], depth)
	var first := PackedInt32Array()
	var last := PackedInt32Array()
	first.resize(n)
	last.resize(n)
	first.fill(-1)
	last.fill(-1)
	for i in n:
		if is_front[i] == 0:
			continue
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var length := a.distance_to(b)
		if length < MIN_EDGE:
			continue
		var j1 := (i + 1) % n
		var wedge := PackedVector2Array([a, b, b + ends[j1], a + starts[i]])
		var t := (b - a) / length
		var nrm := normals[i]
		# cut positions along the side, a frontage width apart, the last piece taking the rest
		var marks := PackedFloat32Array([0.0])
		var s := 0.0
		var k := 0
		while true:
			var w := lerpf(front.x, front.y, _h01("%s%d_%d" % [seed, i, k]))
			if s + w > length - front.x * 0.6:
				break
			s += w
			marks.append(s)
			k += 1
		marks.append(length)
		for j in range(marks.size() - 1):
			var s0 := marks[j] if j > 0 else -depth * 3.0
			var s1 := marks[j + 1] if j < marks.size() - 2 else length + depth * 3.0
			var slab := PackedVector2Array([a + t * s0 - nrm * 2.0, a + t * s1 - nrm * 2.0,
				a + t * s1 + nrm * depth, a + t * s0 + nrm * depth])
			for piece in _pieces(wedge, slab, ring, out):
				if j == 0 and first[i] < 0:
					first[i] = out.size()
				last[i] = out.size()
				out.append({"poly": piece, "edge": i, "corner": false})
	_merge_corners(out, ring, first, last)
	return out.filter(func(p: Dictionary) -> bool: return not p.has("gone"))


# a wedge side running along `dir` (a side with no street) when that leans inward enough,
# else straight in along the normal
static func _along(dir: Vector2, nrm: Vector2, depth: float) -> Vector2:
	var d := dir.normalized()
	var lean := d.dot(nrm)
	if lean > 0.35:
		return d * depth / lean
	return nrm * depth


# wedge x slab x lot, minus the sites already made
static func _pieces(wedge: PackedVector2Array, slab: PackedVector2Array,
		ring: PackedVector2Array, made: Array[Dictionary]) -> Array[PackedVector2Array]:
	var parts: Array[PackedVector2Array] = []
	for w in Geo.clip(Geo.repair(wedge), slab):
		parts.append_array(Geo.clip(w, ring))
	for p in made:
		var poly: PackedVector2Array = p["poly"]
		var box := Geo.bounds(poly)
		var keep: Array[PackedVector2Array] = []
		for part in parts:
			if Geo.bounds(part).intersects(box):
				keep.append_array(Geo.minus(part, poly))
			else:
				keep.append(part)
		parts = keep
	var out: Array[PackedVector2Array] = []
	for part in parts:
		var clean := Geo.repair(part)
		if clean.size() >= 3 and absf(Geo.area(clean)) >= MIN_SITE:
			out.append(clean)
	return out


# at each convex corner the last site of one side and the first of the next become one corner
# site facing both streets (it keeps the longer side's edge)
static func _merge_corners(made: Array[Dictionary], ring: PackedVector2Array,
		first: PackedInt32Array, last: PackedInt32Array) -> void:
	var n := ring.size()
	for i in n:
		var prev := (i - 1 + n) % n
		var a := last[prev]
		var b := first[i]
		if a < 0 or b < 0 or a == b or made[a].has("gone") or made[b].has("gone"):
			continue
		var d0 := ring[i] - ring[prev]
		var d1 := ring[(i + 1) % n] - ring[i]
		# only real corners (the block turns by 45 degrees or more), not a bend in a curved street
		if d0.normalized().dot(d1.normalized()) > 0.7 or d0.cross(d1) <= 0.0:
			continue
		var merged := Geometry2D.merge_polygons(made[a]["poly"], made[b]["poly"])
		if merged.size() != 1:
			continue
		var keep := a if ring[i].distance_to(ring[prev]) >= d1.length() else b
		var drop := b if keep == a else a
		made[keep]["poly"] = merged[0]
		made[keep]["corner"] = true
		made[drop]["gone"] = true


# a block outline, simplified and counter-clockwise
static func ring_of(block: PackedVector2Array) -> PackedVector2Array:
	if block.size() < 3:
		return PackedVector2Array()
	var closed := block.duplicate()
	closed.append(block[0])
	var simple := Geo.simplify(closed, SIMPLIFY)
	simple.remove_at(simple.size() - 1)
	simple = Geo.weld(simple, 1.0)
	if simple.size() < 3:
		return PackedVector2Array()
	if Geo.area(simple) < 0.0:
		simple.reverse()
	return simple


static func _h01(key: String) -> float:
	return float(key.hash() & 0xFFFF) / 65536.0
