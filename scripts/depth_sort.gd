class_name DepthSort
extends RefCounted

# Painter's order for the office view's objects (buildings, trees, cars...), robust where a plain
# sort by centre fails: long thin plots and oblique streets. Only objects whose screen boxes
# overlap are compared; for each such pair a separating axis between their footprints (convex
# hulls in (u, v)) says which one stands behind, and a topological sort turns those pairwise
# rules into one order. Pairs with no clean answer (hulls that overlap) fall back to the centres;
# rules that go round in a circle are broken at the farthest object in it, so the order of
# everything else stays the same whatever circle forms elsewhere (a lot redraw sorts only the
# objects round the lot and must agree with a fresh drawing).
#
# Each object is a Dictionary with "hull" (PackedVector2Array in u, v), "rect" (Rect2 on screen)
# and "key" (u + v of its centre, bigger is nearer).

const CELL := 48.0
const EPS := 0.05


static func order(objs: Array) -> Array:
	var n := objs.size()
	var buckets := {}
	for i in n:
		var r: Rect2 = objs[i]["rect"]
		for cy in range(floori(r.position.y / CELL), floori(r.end.y / CELL) + 1):
			for cx in range(floori(r.position.x / CELL), floori(r.end.x / CELL) + 1):
				var key := Vector2i(cx, cy)
				if not buckets.has(key):
					buckets[key] = PackedInt32Array()
				buckets[key].append(i)
	var after: Array[PackedInt32Array] = []
	after.resize(n)
	var indeg := PackedInt32Array()
	indeg.resize(n)
	var seen := {}
	for key: Vector2i in buckets:
		var list: PackedInt32Array = buckets[key]
		for x in list.size():
			var a := list[x]
			var ra: Rect2 = objs[a]["rect"]
			for y in range(x + 1, list.size()):
				var b := list[y]
				var pair := mini(a, b) * n + maxi(a, b)
				if seen.has(pair):
					continue
				seen[pair] = true
				if not ra.intersects(objs[b]["rect"]):
					continue
				if _behind(objs[a], objs[b]):
					after[a].append(b)
					indeg[b] += 1
				else:
					after[b].append(a)
					indeg[a] += 1
	# Kahn's algorithm, always taking the farthest object that is free to go
	var heap: Array = []
	for i in n:
		if indeg[i] == 0:
			_push(heap, objs[i]["key"], i)
	var out: Array = []
	var done := PackedByteArray()
	done.resize(n)
	# objects by centre, farthest first: where the rules go round in a circle (odd shapes) the
	# farthest object left goes next and the sort carries on, so a circle only reorders itself
	# and not everything nearer than it (that would change with every lot redrawn elsewhere)
	var by_key: Array = []
	var next_key := 0
	while out.size() < n:
		if heap.is_empty():
			if by_key.is_empty():
				for i in n:
					by_key.append([objs[i]["key"], i])
				by_key.sort()
			while done[by_key[next_key][1]] == 1:
				next_key += 1
			var f: int = by_key[next_key][1]
			indeg[f] = 0
			_push(heap, objs[f]["key"], f)
		var i: int = _pop(heap)
		done[i] = 1
		out.append(objs[i])
		for j in after[i]:
			indeg[j] -= 1
			if indeg[j] == 0:
				_push(heap, objs[j]["key"], j)
	return out


# true when a must be drawn before b
static func _behind(a: Dictionary, b: Dictionary) -> bool:
	var ha: PackedVector2Array = a["hull"]
	var hb: PackedVector2Array = b["hull"]
	for hull: PackedVector2Array in [ha, hb]:
		var m := hull.size()
		for i in m:
			var e := hull[(i + 1) % m] - hull[i]
			var nrm := Vector2(e.y, -e.x)
			var toward := nrm.x + nrm.y
			if absf(toward) < 1e-4 * nrm.length():
				continue
			var la := _span(ha, nrm)
			var lb := _span(hb, nrm)
			var tol := EPS * nrm.length()
			if la.y <= lb.x + tol:
				return toward > 0.0
			if lb.y <= la.x + tol:
				return toward < 0.0
	return a["key"] <= b["key"]


static func _span(hull: PackedVector2Array, axis: Vector2) -> Vector2:
	var lo := INF
	var hi := -INF
	for q in hull:
		var d := q.dot(axis)
		lo = minf(lo, d)
		hi = maxf(hi, d)
	return Vector2(lo, hi)


static func _push(heap: Array, key: float, i: int) -> void:
	heap.append([key, i])
	var c := heap.size() - 1
	while c > 0:
		var p := (c - 1) >> 1
		if heap[p][0] <= heap[c][0]:
			break
		var t: Array = heap[p]
		heap[p] = heap[c]
		heap[c] = t
		c = p


static func _pop(heap: Array) -> int:
	var top: int = heap[0][1]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	heap[0] = last
	var c := 0
	var n := heap.size()
	while true:
		var l := c * 2 + 1
		var r := l + 1
		var m := c
		if l < n and heap[l][0] < heap[m][0]:
			m = l
		if r < n and heap[r][0] < heap[m][0]:
			m = r
		if m == c:
			break
		var t: Array = heap[m]
		heap[m] = heap[c]
		heap[c] = t
		c = m
	return top
