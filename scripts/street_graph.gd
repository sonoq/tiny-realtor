class_name StreetGraph
extends RefCounted

# Turns street centre lines into the city blocks between them (polygonizing a planar graph):
#   1. node: cut every segment where it crosses another (OSM usually shares the junction node,
#      but bridges over nothing, traced crossings and the disc edge do not)
#   2. weld points closer than SNAP into one node and build the undirected graph
#   3. prune dead ends (cul-de-sacs, roads leaving the disc) until every node has two or more ways
#   4. walk the faces: arriving at a node, leave by the next way clockwise; bounded faces come out
#      counter-clockwise (positive area), the outer face clockwise and is dropped
# Each face keeps, per edge, the width of the street on it, so the caller can cut the street
# away. Pure data: safe on a worker thread.

const SNAP := 0.5
const CELL := 30.0
const SAMPLE := 10.0
const MAX_WALK := 4000

var _a := PackedVector2Array()
var _b := PackedVector2Array()
var _w := PackedFloat32Array()


func add_line(line: PackedVector2Array, width: float) -> void:
	for i in range(1, line.size()):
		if line[i - 1].distance_squared_to(line[i]) > 0.0001:
			_a.append(line[i - 1])
			_b.append(line[i])
			_w.append(width)


# faces as {"poly": PackedVector2Array (ccw), "widths": PackedFloat32Array (edge i = poly[i] to
# poly[i + 1])}, smallest area `min_area`
func faces(min_area: float) -> Array[Dictionary]:
	var cuts := _node()
	var pos := {}
	var width := {}
	var links := {}
	for i in _a.size():
		var ts: PackedFloat32Array = cuts[i]
		ts.sort()
		var prev := Vector2i.MAX
		for t in ts:
			var p := _a[i].lerp(_b[i], t)
			var key := Vector2i(roundi(p.x / SNAP), roundi(p.y / SNAP))
			if not pos.has(key):
				pos[key] = p
			if prev != Vector2i.MAX and prev != key:
				var ek := _edge_key(prev, key)
				if not width.has(ek):
					width[ek] = _w[i]
					_link(links, prev, key)
					_link(links, key, prev)
				else:
					width[ek] = maxf(width[ek], _w[i])
			prev = key
	_prune(links)
	# every node's ways, sorted counter-clockwise by angle
	for key: Vector2i in links:
		var here: Vector2 = pos[key]
		var around: Array = links[key]
		around.sort_custom(func(p: Vector2i, q: Vector2i) -> bool:
			return (pos[p] - here).angle() < (pos[q] - here).angle())
	var seen := {}
	var out: Array[Dictionary] = []
	for u: Vector2i in links:
		for v: Vector2i in links[u]:
			if seen.has(Vector4i(u.x, u.y, v.x, v.y)):
				continue
			var ring := PackedVector2Array()
			var widths := PackedFloat32Array()
			var a := u
			var b := v
			var steps := 0
			while steps < MAX_WALK:
				steps += 1
				seen[Vector4i(a.x, a.y, b.x, b.y)] = true
				ring.append(pos[a])
				widths.append(width[_edge_key(a, b)])
				var around: Array = links[b]
				var back := around.find(a)
				var c: Vector2i = around[(back - 1 + around.size()) % around.size()]
				a = b
				b = c
				if a == u and b == v:
					break
			if steps < MAX_WALK and ring.size() >= 3 and Geo.area(ring) >= min_area:
				out.append({"poly": ring, "widths": widths})
	return out


# where each segment is cut (0..1 along it), found through a coarse grid of sampled cells
func _node() -> Array[PackedFloat32Array]:
	var cuts: Array[PackedFloat32Array] = []
	var grid := {}
	var cells_of: Array = []
	for i in _a.size():
		cuts.append(PackedFloat32Array([0.0, 1.0]))
		var cells := {}
		var length := _a[i].distance_to(_b[i])
		var n := maxi(1, ceili(length / SAMPLE))
		for s in n + 1:
			var p := _a[i].lerp(_b[i], float(s) / n)
			cells[Vector2i(floori(p.x / CELL), floori(p.y / CELL))] = true
		cells_of.append(cells)
		for c: Vector2i in cells:
			if not grid.has(c):
				grid[c] = PackedInt32Array()
			grid[c].append(i)
	for i in _a.size():
		var tried := {}
		for c: Vector2i in cells_of[i]:
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					for j: int in grid.get(c + Vector2i(dx, dy), PackedInt32Array()):
						if j <= i or tried.has(j):
							continue
						tried[j] = true
						var hit: Variant = Geometry2D.segment_intersects_segment(_a[i], _b[i],
							_a[j], _b[j])
						if hit == null:
							continue
						cuts[i].append(_param(_a[i], _b[i], hit))
						cuts[j].append(_param(_a[j], _b[j], hit))
	return cuts


static func _param(a: Vector2, b: Vector2, p: Vector2) -> float:
	var d := b - a
	return clampf((p - a).dot(d) / d.length_squared(), 0.0, 1.0)


static func _edge_key(p: Vector2i, q: Vector2i) -> Vector4i:
	if p.x < q.x or (p.x == q.x and p.y < q.y):
		return Vector4i(p.x, p.y, q.x, q.y)
	return Vector4i(q.x, q.y, p.x, p.y)


static func _link(links: Dictionary, p: Vector2i, q: Vector2i) -> void:
	if not links.has(p):
		links[p] = []
	if not links[p].has(q):
		links[p].append(q)


static func _prune(links: Dictionary) -> void:
	var queue: Array[Vector2i] = []
	for key: Vector2i in links:
		if links[key].size() < 2:
			queue.append(key)
	while not queue.is_empty():
		var key: Vector2i = queue.pop_back()
		if not links.has(key) or links[key].size() >= 2:
			continue
		for other: Vector2i in links[key]:
			if links.has(other):
				links[other].erase(key)
				if links[other].size() < 2:
					queue.append(other)
		links.erase(key)
