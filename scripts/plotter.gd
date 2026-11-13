class_name Plotter
extends RefCounted

# Cuts one city block into plots along its street frontage, the way real blocks are parcelled:
# a perimeter strip one plot deep, split across the street every frontage width; each corner
# plot takes both frontages; what is left in the middle is the block's courtyard (an Eixample
# "interior d'illa"). A block too small for a courtyard is shared out to the centre instead.
# Every side of the block owns the wedge between the bisectors at its two corners, so the sides
# never fight over ground; overlaps left by odd shapes go to the plot made first.
# Pure data: safe on a worker thread.

# plot depth (m) and frontage width range (m) by zone
const DEPTH := {"residential": Vector2(16, 22), "commercial": Vector2(18, 26),
	"industrial": Vector2(24, 34)}
const FRONT := {"residential": Vector2(8, 14), "commercial": Vector2(15, 30),
	"industrial": Vector2(20, 36)}
const MIN_EDGE := 6.0
const MIN_PLOT := 30.0
const SIMPLIFY := 1.5
# a courtyard smaller than this share of the block is not worth keeping
const MIN_COURT := 0.12


# {"plots": [{"poly", "edge", "corner", "front"}], "courts": [PackedVector2Array]}; `edge` indexes
# the simplified ring in "ring", so the caller can name each plot's street
# `rim`: the radius of the downloaded disc; a side lying on it faces no street and gets no plots
static func cut(block: PackedVector2Array, zone: String, seed: String, rim: float) -> Dictionary:
	var ring := _ring(block)
	var plots: Array[Dictionary] = []
	var courts: Array[PackedVector2Array] = []
	if ring.size() < 3:
		return {"plots": plots, "courts": courts, "ring": ring}
	var area := Geo.area(ring)
	var dr: Vector2 = DEPTH.get(zone, DEPTH["residential"])
	var depth := lerpf(dr.x, dr.y, _h01(seed + "d"))
	var inner: Array[PackedVector2Array] = []
	var inner_area := 0.0
	for part: PackedVector2Array in Geometry2D.offset_polygon(ring, -depth,
			Geometry2D.JOIN_MITER):
		if Geo.area(part) > 0.0:
			inner.append(part)
			inner_area += Geo.area(part)
	if inner_area < area * MIN_COURT:
		inner.clear()
	courts = inner
	var perimeter := 0.0
	for i in ring.size():
		perimeter += ring[i].distance_to(ring[(i + 1) % ring.size()])
	# how far each side's wedge reaches in: past the courtyard edge, or to the middle
	var reach := depth * 1.4 if not inner.is_empty() else 2.0 * area / perimeter * 1.1
	var n := ring.size()
	var normals := PackedVector2Array()
	for i in n:
		var d := (ring[(i + 1) % n] - ring[i]).normalized()
		normals.append(Vector2(-d.y, d.x))
	var bis := PackedVector2Array()
	for i in n:
		var b := (normals[(i - 1 + n) % n] + normals[i]).normalized()
		var lean := maxf(0.35, b.dot(normals[i]))
		bis.append(b * reach / lean)
	var fr: Vector2 = FRONT.get(zone, FRONT["residential"])
	var first := PackedInt32Array()
	var last := PackedInt32Array()
	first.resize(n)
	last.resize(n)
	first.fill(-1)
	last.fill(-1)
	for i in n:
		var a := ring[i]
		var b := ring[(i + 1) % n]
		var length := a.distance_to(b)
		if length < MIN_EDGE or (a.length() > rim - 2.0 and b.length() > rim - 2.0):
			continue
		var wedge := PackedVector2Array([a, b, b + bis[(i + 1) % n], a + bis[i]])
		var t := (b - a) / length
		var nrm := normals[i]
		# cut positions along the side, a frontage width apart, the last piece taking the rest
		var marks := PackedFloat32Array([0.0])
		var s := 0.0
		var k := 0
		while true:
			var w := lerpf(fr.x, fr.y, _h01("%s%d_%d" % [seed, i, k]))
			if s + w > length - fr.x * 0.6:
				break
			s += w
			marks.append(s)
			k += 1
		marks.append(length)
		for j in range(marks.size() - 1):
			var s0 := marks[j] if j > 0 else -reach * 3.0
			var s1 := marks[j + 1] if j < marks.size() - 2 else length + reach * 3.0
			var slab := PackedVector2Array([a + t * s0 - nrm * 2.0, a + t * s1 - nrm * 2.0,
				a + t * s1 + nrm * reach * 3.0, a + t * s0 + nrm * reach * 3.0])
			for piece in _pieces(wedge, slab, ring, inner, plots):
				if j == 0 and first[i] < 0:
					first[i] = plots.size()
				last[i] = plots.size()
				plots.append({"poly": piece, "edge": i, "corner": false,
					"front": marks[j + 1] - marks[j]})
	_merge_corners(plots, ring, first, last)
	return {"plots": plots.filter(func(p: Dictionary) -> bool: return not p.has("gone")),
		"courts": courts, "ring": ring}


# wedge x slab x block, minus the courtyard and minus plots already made
static func _pieces(wedge: PackedVector2Array, slab: PackedVector2Array,
		ring: PackedVector2Array, inner: Array[PackedVector2Array],
		plots: Array[Dictionary]) -> Array[PackedVector2Array]:
	var parts: Array[PackedVector2Array] = []
	for w in Geo.clip(Geo.repair(wedge), slab):
		parts.append_array(Geo.clip(w, ring))
	for hole in inner:
		parts = _minus(parts, hole)
	for p in plots:
		var poly: PackedVector2Array = p["poly"]
		var box := Geo.bounds(poly)
		var keep: Array[PackedVector2Array] = []
		for part in parts:
			if Geo.bounds(part).intersects(box):
				keep.append_array(_minus([part], poly))
			else:
				keep.append(part)
		parts = keep
	var out: Array[PackedVector2Array] = []
	for part in parts:
		var clean := Geo.repair(part)
		if clean.size() >= 3 and absf(Geo.area(clean)) >= MIN_PLOT:
			out.append(clean)
	return out


static func _minus(parts: Array[PackedVector2Array], cut: PackedVector2Array) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for part in parts:
		out.append_array(Geo.minus(part, cut))
	return out


# at each convex corner the last plot of one side and the first of the next become one corner
# plot facing both streets (it is named after the longer side)
static func _merge_corners(plots: Array[Dictionary], ring: PackedVector2Array,
		first: PackedInt32Array, last: PackedInt32Array) -> void:
	var n := ring.size()
	for i in n:
		var prev := (i - 1 + n) % n
		var a := last[prev]
		var b := first[i]
		if a < 0 or b < 0 or a == b or plots[a].has("gone") or plots[b].has("gone"):
			continue
		var d0 := ring[i] - ring[prev]
		var d1 := ring[(i + 1) % n] - ring[i]
		# only real corners (the block turns by 45 degrees or more), not a bend in a curved street
		if d0.normalized().dot(d1.normalized()) > 0.7 or d0.cross(d1) <= 0.0:
			continue
		var merged := Geometry2D.merge_polygons(plots[a]["poly"], plots[b]["poly"])
		if merged.size() != 1:
			continue
		var keep := a if ring[i].distance_to(ring[prev]) >= d1.length() else b
		var drop := b if keep == a else a
		plots[keep]["poly"] = merged[0]
		plots[keep]["corner"] = true
		plots[drop]["gone"] = true


# the block outline, simplified and counter-clockwise
static func _ring(block: PackedVector2Array) -> PackedVector2Array:
	var closed := block.duplicate()
	closed.append(block[0])
	var simple := Geo.simplify(closed, SIMPLIFY)
	simple.remove_at(simple.size() - 1)
	simple = Geo.weld(simple, 1.0)
	if Geo.area(simple) < 0.0:
		simple.reverse()
	return simple


static func _h01(key: String) -> float:
	return float(key.hash() & 0xFFFF) / 65536.0
