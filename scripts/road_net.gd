class_name RoadNet
extends RefCounted

# The office area's streets as lanes for Traffic. Every street line (pedestrian streets aside) is
# split where it meets another into edges. A two-way edge gets one lane each way, two on avenues
# (18 m and wider, where AreaBuilder paints two dashed lines), on the right-hand side (left in
# left-hand countries); a one-way edge (the road's `oneway`) one to three lanes its way, between
# the painted dashes. Lanes are pulled back from each junction to the kerb of the crossing
# street. Junctions are crossed on connectors, smooth curves from the end of one lane to the
# start of the next, made the first time a car takes them; a two-way dead end is a U-turn, a
# one-way street out of the disc (or into nowhere) an exit. Lanes and connectors are both
# "paths": a polyline with its running length, all in ground metres, indexed together (lanes
# first).

# nodes are matched on a half-metre grid: the bake snaps to 10 cm and welds at 0.5 m
const KEY := 2.0
# junctions closer than this (m, along the street between them) are one
const MERGE := 8.0
# grid cell (m) of the street segments that keep junction curves on the road
const ROAD_CELL := 20.0
# lane offset never closer to the middle line than this (m)
const LANE_MIN := 1.4
# connectors that pass closer than this (m) cross each other
const CLEAR := 2.4
# metres of lane a queued car takes, to tell how full a lane is
const JAM_M := 6.5
# top speeds by street kind (m/s): calm, so a car takes half a minute to cross the window
const CRUISE := {
	"motorway": 11.0, "trunk": 10.0, "primary": 8.5, "secondary": 7.5, "tertiary": 7.0,
	"unclassified": 5.5, "residential": 5.5, "road": 5.5, "living_street": 3.5, "busway": 7.0,
}
# cars per 100 m of lane, by street kind: avenues busy, back streets quiet
const DENSITY := {
	"motorway": 2.6, "trunk": 2.6, "primary": 2.6, "secondary": 2.4, "tertiary": 2.0,
	"unclassified": 1.4, "residential": 1.4, "road": 1.2, "living_street": 0.7, "busway": 0.8,
}
# how much a street kind draws turning cars, so they keep to the avenues
const PULL := {
	"motorway": 3.0, "trunk": 3.0, "primary": 3.0, "secondary": 2.5, "tertiary": 2.0,
	"unclassified": 1.0, "residential": 1.0, "road": 1.0, "living_street": 0.4, "busway": 0.6,
}

# --- every path ---
var pts: Array[PackedVector2Array] = []
var cum: Array[PackedFloat32Array] = []
var length := PackedFloat32Array()
var speed := PackedFloat32Array()
var is_conn := PackedByteArray()
# lane: the nodes it runs between; connector: its junction in both
var from_node := PackedInt32Array()
var to_node := PackedInt32Array()
# lane: its edge and direction (+1 / -1); connector: the lane it leaves and the lane it joins
var src := PackedInt32Array()
var dst := PackedInt32Array()
# --- lanes only (the first lane_count paths) ---
var lane_count := 0
var kind: Array[String] = []
var density := PackedFloat32Array()
var mid := PackedVector2Array()
# --- nodes ---
var node_pos := PackedVector2Array()
var node_deg := PackedInt32Array()
var out_lanes: Array[PackedInt32Array] = []
# a node at the disc's edge, where cars on a street with no way back drive off the world
var node_rim := PackedByteArray()

var _side := 1.0
var _edges: Array[Dictionary] = []
var _conn := {}
var _conflict := {}
var _conflict_end := {}
var _trims := {}
# node -> the edges that end at it
var _at_node := {}
# connectors that leave the street, taken only when there is no other way
var _rough := {}
# the street segments by grid cell, [a, b, half width], to keep junction curves on the road
var _roads := {}


# roads: the area's roads[] (format v3); left_hand: drive on the left; radius: the disc's
func build(roads: Array, left_hand: bool, radius: float) -> void:
	_side = -1.0 if left_hand else 1.0
	var lines: Array[PackedVector2Array] = []
	var info: Array[Dictionary] = []
	for road: Dictionary in roads:
		if road.get("kind", "") == "pedestrian":
			continue
		var line := _line(road["line"])
		if line.size() < 2:
			continue
		lines.append(line)
		info.append(road)
		var half := float(road["width"]) * 0.5
		for i in range(1, line.size()):
			var lo := (line[i - 1].min(line[i]) - Vector2.ONE * (half + 4.0)) / ROAD_CELL
			var hi := (line[i - 1].max(line[i]) + Vector2.ONE * (half + 4.0)) / ROAD_CELL
			for cy in range(floori(lo.y), floori(hi.y) + 1):
				for cx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(cx, cy)
					if not _roads.has(key):
						_roads[key] = []
					_roads[key].append([line[i - 1], line[i], half])
	split_crossings(lines)
	# a point shared by two lines (or an end) is a node
	var seen := {}
	for line in lines:
		for i in line.size():
			var k := _key(line[i])
			seen[k] = int(seen.get(k, 0)) + (2 if i == 0 or i == line.size() - 1 else 1)
	var ids := {}
	for li in lines.size():
		var line := lines[li]
		var start := 0
		for i in range(1, line.size()):
			if i < line.size() - 1 and int(seen[_key(line[i])]) < 2:
				continue
			var piece := line.slice(start, i + 1)
			start = i
			if _len(piece) < 0.3:
				continue
			var a := _node(ids, piece[0])
			var b := _node(ids, piece[piece.size() - 1])
			var w := float(info[li]["width"])
			var oneway := int(info[li].get("oneway", 0))
			_edges.append({"pts": piece, "a": a, "b": b, "width": w, "oneway": oneway,
				"kind": String(info[li]["kind"]), "offsets": _lane_offsets(w, oneway != 0)})
			node_deg[a] += 1
			node_deg[b] += 1
	_merge_close()
	out_lanes.resize(node_pos.size())
	node_rim.resize(node_pos.size())
	for n in node_pos.size():
		out_lanes[n] = PackedInt32Array()
		node_rim[n] = 1 if node_pos[n].length() > radius - 12.0 else 0
	for e in _edges.size():
		var edge: Dictionary = _edges[e]
		var line: PackedVector2Array = edge["pts"]
		var back := line.duplicate()
		back.reverse()
		for dir: int in [1, -1]:
			if int(edge["oneway"]) != 0 and dir != int(edge["oneway"]):
				continue
			var run := line if dir == 1 else back
			var from: int = edge["a"] if dir == 1 else edge["b"]
			var to: int = edge["b"] if dir == 1 else edge["a"]
			for off: float in edge["offsets"]:
				var path := _trim(_offset(run, off * _side), _trim_at(from, e), _trim_at(to, e))
				var id := _add(path, float(CRUISE.get(edge["kind"], 5.5)), false, from, to, e, dir)
				kind.append(edge["kind"])
				density.append(float(DENSITY.get(edge["kind"], 0.5)))
				mid.append(_at(id, length[id] * 0.5))
				out_lanes[from].append(id)
	lane_count = length.size()


# where along a path a distance s lies, starting the search at segment `seg`; returns the
# segment, so a car can keep it for its next step
func seg_at(path: int, s: float, seg: int) -> int:
	var c := cum[path]
	var last := c.size() - 2
	while seg < last and c[seg + 1] < s:
		seg += 1
	return seg


func point(path: int, s: float, seg: int) -> Vector2:
	var p := pts[path]
	var c := cum[path]
	var span := c[seg + 1] - c[seg]
	var t := clampf((s - c[seg]) / span, 0.0, 1.0) if span > 1e-5 else 0.0
	return p[seg].lerp(p[seg + 1], t)


func direction(path: int, seg: int) -> Vector2:
	var p := pts[path]
	return (p[seg + 1] - p[seg]).normalized()


func _at(path: int, s: float) -> Vector2:
	return point(path, s, seg_at(path, s, 0))


# the lane a car on `lane` takes at its end, drawn at random by `rng`: never straight back the
# way it came unless there is nothing else, the avenues and straight on preferred, and a street
# already full of cars (`load`: cars per lane, when given) avoided, as drivers go round a jam
func choose(lane: int, rng: RandomNumberGenerator,
		load: PackedInt32Array = PackedInt32Array()) -> int:
	var n := to_node[lane]
	var outs := out_lanes[n]
	var din := direction(lane, pts[lane].size() - 2)
	var total := 0.0
	for m in outs:
		total += _weight(lane, m, din, load)
	if total > 0.0:
		var pick := rng.randf() * total
		var last := -1
		for m in outs:
			var w := _weight(lane, m, din, load)
			if w <= 0.0:
				continue
			last = m
			pick -= w
			if pick <= 0.0:
				return m
		return last
	# a dead end: off the world at the disc's edge, else back the other way (or nowhere, -1)
	if node_rim[n] == 1:
		return -1
	for m in outs:
		return m
	return -1


func _weight(lane: int, m: int, din: Vector2, load: PackedInt32Array) -> float:
	# never into a street with no way out (a one-way street ending inside the disc)
	if out_lanes[to_node[m]].is_empty() and node_rim[to_node[m]] == 0:
		return 0.0
	var w: float = PULL.get(kind[m], 1.0)
	var turn := din.dot(direction(m, 0))
	# no hairpins, and no curve that would have to leave the street
	if turn < -0.5 or _rough.has(connector(lane, m)):
		return 0.0
	if turn > 0.8:
		# straight on, and on a wide street in the lane in line with this one
		var a := pts[lane][pts[lane].size() - 1]
		var off := absf((pts[m][0] - a).dot(din.orthogonal()))
		w *= 2.5 * 4.0 / (4.0 + off * off)
	if not load.is_empty():
		# how full the lane is (a queued car takes about JAM_M)
		var full := minf(1.0, load[m] * JAM_M / maxf(length[m], JAM_M))
		w *= (1.0 - full * 0.95) * (1.0 - full * 0.95)
	return w


# the connector from the end of lane a to the start of lane b at their junction (made once)
func connector(a: int, b: int) -> int:
	var key := a * 65536 + b
	if _conn.has(key):
		return _conn[key]
	var pa := pts[a]
	var A := pa[pa.size() - 1]
	var dA := direction(a, pa.size() - 2)
	var B := pts[b][0]
	var dB := direction(b, 0)
	var dist := A.distance_to(B)
	var u_turn := dA.dot(dB) < -0.7
	var k := maxf(dist, 3.0) * 0.9 if u_turn else dist * 0.38
	var c1 := A + dA * k
	var c2 := B - dB * k
	# a turn bends round the corner where the two lanes would meet, which keeps it off the kerb
	var corner: Variant = null if u_turn or absf(dA.cross(dB)) < 0.2 \
		else Geometry2D.line_intersects_line(A, dA, B, dB)
	if corner != null:
		var ta := (corner as Vector2 - A).dot(dA)
		var tb := (B - corner as Vector2).dot(dB)
		if ta > 0.0 and tb > 0.0 and ta < dist * 2.0 and tb < dist * 2.0:
			c1 = A.lerp(corner, 2.0 / 3.0)
			c2 = B.lerp(corner, 2.0 / 3.0)
	var line := _curve(A, c1, c2, B, clampi(ceili(dist / 1.2), 3, 16) + (6 if u_turn else 0))
	# a curve that cuts across a corner (where streets meet at odd angles) goes by the junction
	if not u_turn and _off_road(line) > 0.3:
		var at := node_pos[to_node[a]]
		var mid := (B - A).normalized()
		var ka := A.distance_to(at) * 0.4
		var kb := B.distance_to(at) * 0.4
		var via := _curve(A, A + dA * ka, at - mid * ka, at, clampi(ceili(ka / 0.5), 3, 12))
		via.append_array(_curve(at, at + mid * kb, B - dB * kb, B,
			clampi(ceili(kb / 0.5), 3, 12)).slice(1))
		if _off_road(via) < _off_road(line):
			line = via
	line = _dedupe(line)
	if line.size() < 2:
		line = PackedVector2Array([A, A + dA * 0.1])
	var top := minf(speed[a], speed[b])
	var turn := acos(clampf(dA.dot(dB), -1.0, 1.0))
	var v := top
	var arc := _len(line)
	if turn > 0.35:
		v = clampf(sqrt(1.8 * arc / turn), 1.5, top)
	var id := _add(line, v, true, to_node[a], to_node[a], a, b)
	_conn[key] = id
	if not u_turn and _off_road(line) > 1.0:
		_rough[id] = true
	return id


static func _curve(a: Vector2, c1: Vector2, c2: Vector2, b: Vector2,
		n: int) -> PackedVector2Array:
	var line := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / n
		var s := 1.0 - t
		line.append(a * s * s * s + c1 * 3.0 * s * s * t + c2 * 3.0 * s * t * t + b * t * t * t)
	return line


# how far (m) a line strays past the edge of the streets at worst
func _off_road(line: PackedVector2Array) -> float:
	var worst := 0.0
	for q in line:
		var best := INF
		for seg: Array in _roads.get(Vector2i(floori(q.x / ROAD_CELL), floori(q.y / ROAD_CELL)),
				[]):
			var c := Geometry2D.get_closest_point_to_segment(q, seg[0], seg[1])
			best = minf(best, c.distance_to(q) - float(seg[2]))
		worst = maxf(worst, best)
	return worst


# true when cars on these two connectors of one junction would run into each other; two from
# the same lane only follow one another
func conflict(c1: int, c2: int) -> bool:
	if c1 == c2 or src[c1] == src[c2]:
		return false
	var key := mini(c1, c2) * 65536 + maxi(c1, c2)
	if _conflict.has(key):
		return _conflict[key]
	var p := pts[c1]
	var q := pts[c2]
	var hit := false
	for i in p.size() - 1:
		for j in q.size() - 1:
			var cp := Geometry2D.get_closest_points_between_segments(p[i], p[i + 1], q[j],
				q[j + 1])
			if cp[0].distance_to(cp[1]) < CLEAR:
				hit = true
				break
		if hit:
			break
	_conflict[key] = hit
	return hit


# how far along connector c1 (m) its last stretch within CLEAR of connector c2 ends, -1 when
# they never come that close: a car on c1 whose rear is past it is out of c2's way
func conflict_end(c1: int, c2: int) -> float:
	var key := c1 * 65536 + c2
	if _conflict_end.has(key):
		return _conflict_end[key]
	var p := pts[c1]
	var q := pts[c2]
	var end := -1.0
	for i in range(p.size() - 2, -1, -1):
		for j in q.size() - 1:
			var cp := Geometry2D.get_closest_points_between_segments(p[i], p[i + 1], q[j],
				q[j + 1])
			if cp[0].distance_to(cp[1]) < CLEAR:
				end = cum[c1][i + 1]
				break
		if end >= 0.0:
			break
	_conflict_end[key] = end
	return end


func path_count() -> int:
	return length.size()


# --- building ------------------------------------------------------------------------------------

func _add(line: PackedVector2Array, v: float, conn: bool, from: int, to: int, a: int,
		b: int) -> int:
	var c := PackedFloat32Array()
	c.resize(line.size())
	var total := 0.0
	for i in range(1, line.size()):
		total += line[i].distance_to(line[i - 1])
		c[i] = total
	pts.append(line)
	cum.append(c)
	length.append(total)
	speed.append(v)
	is_conn.append(1 if conn else 0)
	from_node.append(from)
	to_node.append(to)
	src.append(a)
	dst.append(b)
	return length.size() - 1


func _key(q: Vector2) -> Vector2i:
	return Vector2i(roundi(q.x * KEY), roundi(q.y * KEY))


func _node(ids: Dictionary, q: Vector2) -> int:
	var k := _key(q)
	if not ids.has(k):
		ids[k] = node_pos.size()
		node_pos.append(q)
		node_deg.append(0)
	return ids[k]


# lanes across a street, as offsets to the right of travel: the kerb lane first
static func _lane_offsets(width: float, oneway: bool) -> Array[float]:
	if oneway:
		if width < 10.0:
			return [0.0]
		if width < 18.0:
			return [width * 0.22, -width * 0.22]
		return [width * 0.375, 0.0, -width * 0.375]
	if width >= 18.0:
		return [width * 0.375, maxf(LANE_MIN, width * 0.125)]
	# a little in from the lane's middle, to leave AreaBuilder's parked cars room at the kerb
	return [maxf(LANE_MIN, width * 0.22)]


# junctions a few metres apart (a kink where two streets meet, mapping noise) or whose boxes
# overlap are one: the bit of street between them, and any other between the same two, goes
func _merge_close() -> void:
	var merged := true
	while merged:
		merged = false
		for e in _edges.size():
			var edge: Dictionary = _edges[e]
			var a: int = edge["a"]
			var b: int = edge["b"]
			if a == b or node_deg[a] < 2 or node_deg[b] < 2:
				continue
			var l := _len(edge["pts"])
			# or so close that the street between is all junction (their boxes overlap)
			if l >= MERGE and l - _trim_at(a, e) - _trim_at(b, e) >= 1.0:
				continue
			var keep: Array[Dictionary] = []
			for o: Dictionary in _edges:
				var oa: int = o["a"]
				var ob: int = o["b"]
				if (oa == a and ob == b) or (oa == b and ob == a):
					node_deg[a] -= 1
					node_deg[b] -= 1
					continue
				if oa == b:
					o["a"] = a
				if ob == b:
					o["b"] = a
				keep.append(o)
			_edges = keep
			node_pos[a] = (node_pos[a] + node_pos[b]) * 0.5
			node_deg[a] += node_deg[b]
			node_deg[b] = 0
			_at_node.clear()
			_trims.clear()
			merged = true
			break
	_at_node.clear()
	_trims.clear()


# streets that cross (or end on another) without sharing a point get one there, so every
# crossing is a junction
static func split_crossings(lines: Array[PackedVector2Array]) -> void:
	var cell := 40.0
	var grid := {}
	for li in lines.size():
		var line := lines[li]
		for si in line.size() - 1:
			var lo := (line[si].min(line[si + 1]) - Vector2.ONE) / cell
			var hi := (line[si].max(line[si + 1]) + Vector2.ONE) / cell
			for cy in range(floori(lo.y), floori(hi.y) + 1):
				for cx in range(floori(lo.x), floori(hi.x) + 1):
					var k := Vector2i(cx, cy)
					if not grid.has(k):
						grid[k] = PackedInt32Array()
					grid[k].append(li * 65536 + si)
	# line -> segment -> points to insert
	var cuts := {}
	var seen := {}
	for k: Vector2i in grid:
		var list: PackedInt32Array = grid[k]
		for x in list.size():
			for y in range(x + 1, list.size()):
				var a := list[x]
				var b := list[y]
				var la := a >> 16
				var lb := b >> 16
				if la == lb or seen.has(a * 4294967296 + b):
					continue
				seen[a * 4294967296 + b] = true
				var pa := lines[la]
				var pb := lines[lb]
				var sa := a & 65535
				var sb := b & 65535
				var hit: Variant = Geometry2D.segment_intersects_segment(pa[sa], pa[sa + 1],
					pb[sb], pb[sb + 1])
				if hit == null:
					continue
				_cut(cuts, la, sa, pa, hit)
				_cut(cuts, lb, sb, pb, hit)
	# a line ending just short of (or past) another meets it there
	for li in lines.size():
		var line := lines[li]
		for end: int in [0, line.size() - 1]:
			var e := line[end]
			var best := 1.2
			var at := Vector2.INF
			var on := -1
			for code: int in grid.get(Vector2i(floori(e.x / cell), floori(e.y / cell)),
					PackedInt32Array()):
				var lo := code >> 16
				if lo == li:
					continue
				var o := lines[lo]
				var si := code & 65535
				var q := Geometry2D.get_closest_point_to_segment(e, o[si], o[si + 1])
				var d := q.distance_to(e)
				if d < best and d > 0.01:
					best = d
					at = q
					on = code
			if on >= 0:
				var o := lines[on >> 16]
				var si := on & 65535
				if at.distance_to(o[si]) < 0.05:
					at = o[si]
				elif at.distance_to(o[si + 1]) < 0.05:
					at = o[si + 1]
				else:
					_cut(cuts, on >> 16, si, o, at)
				line[end] = at
		lines[li] = line
	for li: int in cuts:
		var line := lines[li]
		var out := PackedVector2Array()
		var by_seg: Dictionary = cuts[li]
		for si in line.size():
			out.append(line[si])
			if not by_seg.has(si) or si == line.size() - 1:
				continue
			var extra: Array = by_seg[si]
			var a := line[si]
			extra.sort_custom(func(p: Vector2, q: Vector2) -> bool:
				return p.distance_squared_to(a) < q.distance_squared_to(a))
			for q: Vector2 in extra:
				out.append(q)
		lines[li] = _dedupe(out)


static func _cut(cuts: Dictionary, li: int, si: int, line: PackedVector2Array,
		at: Vector2) -> void:
	if at.distance_to(line[si]) < 0.05 or at.distance_to(line[si + 1]) < 0.05:
		return
	if not cuts.has(li):
		cuts[li] = {}
	if not cuts[li].has(si):
		cuts[li][si] = []
	cuts[li][si].append(at)


# how far a lane stops short of node n: until its street is clear of every street meeting it
# there at an angle (at the crossing street's kerb, much further back where a street joins
# another at a slant), a little at a plain bend, enough for a U-turn at a dead end
func _trim_at(n: int, e: int) -> float:
	if node_deg[n] == 1:
		return 3.0
	var key := n * 65536 + e
	if _trims.has(key):
		return _trims[key]
	var mine := _tangent(e, n)
	var others: Array[int] = []
	for o: int in _edges_at(n):
		if o != e and mine.dot(_tangent(o, n)) > -0.85:
			others.append(o)
	var line: PackedVector2Array = _edges[e]["pts"]
	if int(_edges[e]["a"]) != n:
		line = line.duplicate()
		line.reverse()
	var total := _len(line)
	var out := minf(total, 45.0)
	if others.is_empty():
		out = 1.5
	var s := 0.0
	while not others.is_empty() and s < out:
		var q := _point_along(line, s)
		var clear := true
		for o in others:
			if _distance(q, _edges[o]["pts"]) < float(_edges[o]["width"]) * 0.5 + 1.2:
				clear = false
				break
		if clear:
			out = maxf(s, 1.5)
			break
		s += 0.5
	_trims[key] = out
	return out


static func _point_along(line: PackedVector2Array, at: float) -> Vector2:
	var acc := 0.0
	for i in range(1, line.size()):
		var l := line[i].distance_to(line[i - 1])
		if acc + l >= at and l > 1e-5:
			return line[i - 1].lerp(line[i], (at - acc) / l)
		acc += l
	return line[line.size() - 1]


static func _distance(q: Vector2, line: PackedVector2Array) -> float:
	var best := INF
	for i in range(1, line.size()):
		best = minf(best, Geometry2D.get_closest_point_to_segment(q, line[i - 1],
			line[i]).distance_to(q))
	return best



func _edges_at(n: int) -> PackedInt32Array:
	if _at_node.is_empty():
		for e in _edges.size():
			for end: int in [_edges[e]["a"], _edges[e]["b"]]:
				if not _at_node.has(end):
					_at_node[end] = PackedInt32Array()
				_at_node[end].append(e)
	return _at_node.get(n, PackedInt32Array())


# the direction edge e leaves node n in, taken a few metres out so a short first piece of line
# does not skew it
func _tangent(e: int, n: int) -> Vector2:
	var line: PackedVector2Array = _edges[e]["pts"]
	if int(_edges[e]["a"]) != n:
		line = line.duplicate()
		line.reverse()
	var at := line[0]
	for i in range(1, line.size()):
		if line[i].distance_to(at) >= 4.0 or i == line.size() - 1:
			return (line[i] - at).normalized()
	return Vector2.RIGHT


# a polyline moved sideways by off (+ = to the right of travel), mitred at the bends
static func _offset(line: PackedVector2Array, off: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := line.size()
	out.resize(n)
	for i in n:
		var a := Vector2.ZERO
		var b := Vector2.ZERO
		if i > 0:
			var d := (line[i] - line[i - 1]).normalized()
			a = Vector2(d.y, -d.x)
		if i < n - 1:
			var d := (line[i + 1] - line[i]).normalized()
			b = Vector2(d.y, -d.x)
		if i == 0:
			a = b
		if i == n - 1:
			b = a
		var m := a + b
		m = a if m.length() < 0.1 else m.normalized()
		out[i] = line[i] + m * off / maxf(m.dot(a), 0.5)
	return out


# the part of a polyline from t0 after its start to t1 before its end (at least a little of it)
static func _trim(line: PackedVector2Array, t0: float, t1: float) -> PackedVector2Array:
	var total := _len(line)
	var room := maxf(total - 0.2, 0.0)
	if t0 + t1 > room:
		var f := room / maxf(t0 + t1, 1e-5)
		t0 *= f
		t1 *= f
	var out := PackedVector2Array()
	var acc := 0.0
	var stop := total - t1
	for i in range(1, line.size()):
		var a := line[i - 1]
		var b := line[i]
		var l := a.distance_to(b)
		if l < 1e-5:
			continue
		if acc + l >= t0 and out.is_empty():
			out.append(a.lerp(b, (t0 - acc) / l))
		if not out.is_empty():
			if acc + l >= stop:
				out.append(a.lerp(b, (stop - acc) / l))
				break
			out.append(b)
		acc += l
	out = _dedupe(out)
	if out.size() < 2:
		var d := (line[line.size() - 1] - line[0]).normalized()
		var c := line[0].lerp(line[line.size() - 1], 0.5)
		out = PackedVector2Array([c - d * 0.1, c + d * 0.1])
	return out


static func _line(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in raw:
		out.append(Vector2(q[0], q[1]))
	return out


static func _dedupe(line: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q in line:
		if out.is_empty() or out[out.size() - 1].distance_to(q) > 0.02:
			out.append(q)
	return out


static func _len(line: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, line.size()):
		total += line[i].distance_to(line[i - 1])
	return total
