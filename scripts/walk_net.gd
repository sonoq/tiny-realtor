class_name WalkNet
extends RefCounted

# The office area's pavements as a walking network for Walkers. Every block gets a ring a little
# out from its edge, on the pavement between the shop fronts and the street trees; the parts of
# it that run along a street (not a rail line, the water or the disc's edge) are the walkways.
# Streets are crossed where AreaBuilder paints its zebra crossings at the junctions (the same
# rule, copied in zebra_spots()), at the corner of narrower streets that have no paint, and
# freely over pedestrian streets. The walkways are cut into edges (at most PIECE metres) between
# nodes where walkers choose their way; a crossing is an edge from one ring to the other, with
# the kerbs marked along it.
# Cars and walkers share the crossings: `bands(path)` gives where a RoadNet path (lane or
# junction curve) runs through each crossing's band, which Traffic keeps out of while `busy`
# (someone is on it), and stops before when it waits for its junction.

# the walkway's distance out from a block's edge (m): the shop fronts are at 0, the street trees
# at 1.6, the lamps at 2.6, the kerb at BlockBaker.PAVEMENT
const RING_OUT := 0.95
# the ring is tested every this many metres
const STEP := 1.0
# a walkway keeps this clear of any lot (m)
const BLOCK_CLEAR := 0.6
# longest walkway edge (m), so walkers near the view are found and choose their way often
const PIECE := 18.0
# walkway pieces are filed in the grid this much (m) beyond their ends
const ATTACH := 1.8
# a walkway point keeps this clear of any carriageway (m) and lies within KERB_OUT of a kerb
const KERB_IN := 0.4
const KERB_OUT := BlockBaker.PAVEMENT + 1.2
# attachments closer than this (m) along a walkway share one node
const MERGE := 0.8
const SEG_CELL := 20.0
const CROSS_CELL := 30.0
# half the depth (m, along the street) of the band cars keep out of while someone crosses, and
# how far past the kerbs it reaches
const BAND := 1.6
const BAND_OUT := 0.6
# junction arms shorter than this (m) are not arms (AreaBuilder's rule); unpainted crossings
# take any street that runs on at least ARM_OUT (m)
const ARM_MIN := 12.0
const ARM_OUT := 6.0
# how far (m) a crossing may reach from its spot to a walkway: a dual carriageway and its median
const MARCH := 45.0
# carriageways further apart than this (m) along a crossing have a median between: it is cut
# there into one crossing each, with a node on the median to wait on
const MEDIAN := 3.0
# no crossing runs over more than this much road in one go (m): longer ones cut across
# junctions, where cars come from every side
const SPAN_MAX := 24.0
# how far to either side of a crossing's line its kerbs are looked for (m)
const LANE_SIDE := 0.6
# the most a crossing may run along a street it crosses (cosine of the angle between them)
const SLANT_MAX := 0.6
enum { PAVE, CROSS, FREE }

# --- nodes ---
var node_pos := PackedVector2Array()
# half-edges leaving each node: e * 2 runs a -> b, e * 2 + 1 runs b -> a
var node_out: Array[PackedInt32Array] = []
# --- edges ---
var pts: Array[PackedVector2Array] = []
var cum: Array[PackedFloat32Array] = []
var length := PackedFloat32Array()
var ea := PackedInt32Array()
var eb := PackedInt32Array()
var kind := PackedByteArray()
# the crossing a CROSS / FREE edge is, else -1
var cross := PackedInt32Array()
# PAVE: +1 when the block is on the right going a -> b, -1 on the left
var side := PackedInt32Array()
var mid := PackedVector2Array()
var pave_m := 0.0
# --- crossings ---
var c_mid := PackedVector2Array()
# along the street and across it (pointing from the edge's a to its b)
var c_along := PackedVector2Array()
var c_across := PackedVector2Array()
var c_half := PackedFloat32Array()
var c_edge := PackedInt32Array()
# the kerbs along the edge, from a
var c_k0 := PackedFloat32Array()
var c_k1 := PackedFloat32Array()
var c_zebra := PackedByteArray()
var c_free := PackedByteArray()
# walkers on a crossing or stepping onto it (Walkers keeps it); cars keep out while > 0
var busy := PackedInt32Array()
# all of them, so cars need not look while nobody crosses
var busy_total := 0

var radius := 500.0
var _segs := {}
var _blocks := {}
var _cgrid := {}
# per RoadNet path, its bands (empty until asked; the paths grow as junction curves are made)
var _bands: Array[PackedFloat32Array] = []
var _banded := PackedByteArray()
var _no_bands := PackedFloat32Array()


func build(block: Dictionary) -> void:
	radius = float(block.get("radius_m", 500.0))
	var roads: Array = block.get("roads", [])
	for road: Dictionary in roads:
		var line := _line(road.get("line", []))
		var half := float(road.get("width", 8.0)) * 0.5
		var walk := 1.0 if road.get("kind", "") == "pedestrian" else 0.0
		for i in range(1, line.size()):
			var lo := (line[i - 1].min(line[i]) - Vector2.ONE * (half + KERB_OUT)) / SEG_CELL
			var hi := (line[i - 1].max(line[i]) + Vector2.ONE * (half + KERB_OUT)) / SEG_CELL
			for cy in range(floori(lo.y), floori(hi.y) + 1):
				for cx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(cx, cy)
					if not _segs.has(key):
						_segs[key] = []
					_segs[key].append([line[i - 1], line[i], half, walk])
	# what walkways keep clear of: the lots and the small gardens
	for key: String in ["plots", "courts"]:
		for b: Dictionary in block.get(key, []):
			var poly := _line(b["poly"])
			if poly.size() < 3:
				continue
			var box := Geo.bounds(poly).grow(BLOCK_CLEAR)
			for cy in range(floori(box.position.y / SEG_CELL), floori(box.end.y / SEG_CELL) + 1):
				for cx in range(floori(box.position.x / SEG_CELL),
						floori(box.end.x / SEG_CELL) + 1):
					var cell := Vector2i(cx, cy)
					if not _blocks.has(cell):
						_blocks[cell] = []
					_blocks[cell].append([box, poly])
	# the walkways: runs of each block's ring that lie on a pavement
	var runs: Array[PackedVector2Array] = []
	var closed: Array[bool] = []
	var owner: Array[PackedVector2Array] = []
	for b: Dictionary in block.get("blocks", []):
		var poly := Iso.clean(_line(b["poly"]))
		if poly.size() < 3:
			continue
		var ring := Iso.offset(poly, RING_OUT)
		if ring.size() < 3:
			continue
		_runs_of(ring, poly, runs, closed, owner)
	var run_cum: Array[PackedFloat32Array] = []
	var run_grid := {}
	for r in runs.size():
		run_cum.append(_cumulate(runs[r]))
		var line := runs[r]
		for k in range(1, line.size()):
			var lo := (line[k - 1].min(line[k]) - Vector2.ONE * ATTACH) / SEG_CELL
			var hi := (line[k - 1].max(line[k]) + Vector2.ONE * ATTACH) / SEG_CELL
			for cy in range(floori(lo.y), floori(hi.y) + 1):
				for cx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(cx, cy)
					if not run_grid.has(key):
						run_grid[key] = PackedInt32Array()
					run_grid[key].append(r * 65536 + k)
	# crossings: from a spot both ways across the street (and a median, the other half of a dual
	# carriageway) to the first walkway; joined to the walkways at [s along the run, spot, end]
	var attach: Array[Array] = []
	attach.resize(runs.size())
	for r in runs.size():
		attach[r] = []
	var ends := PackedVector2Array()
	var zebra := PackedByteArray()
	for spot: Dictionary in zebra_spots(roads, radius):
		var m: Vector2 = spot["mid"]
		var across: Vector2 = (spot["dir"] as Vector2).orthogonal()
		var half := float(spot["width"]) * 0.5
		var a := _march(m, -across, half, runs, run_cum, run_grid)
		var b := _march(m, across, half, runs, run_cum, run_grid)
		if a.is_empty() or b.is_empty():
			continue
		var pa: Vector2 = a[2]
		var pb: Vector2 = b[2]
		var dup := false
		for k in range(0, ends.size(), 2):
			if (ends[k].distance_to(pa) < 3.0 and ends[k + 1].distance_to(pb) < 3.0) \
					or (ends[k].distance_to(pb) < 3.0 and ends[k + 1].distance_to(pa) < 3.0):
				dup = true
				break
		if dup:
			continue
		var n := zebra.size()
		ends.append(pa)
		ends.append(pb)
		zebra.append(1 if spot["zebra"] else 0)
		attach[a[0]].append([a[1], n, 0])
		attach[b[0]].append([b[1], n, 1])
	# walkways cut into edges at the crossings and every PIECE metres
	var end_node: Array[PackedInt32Array] = []
	for n in zebra.size():
		end_node.append(PackedInt32Array([-1, -1]))
	for r in runs.size():
		_cut_run(runs[r], run_cum[r], closed[r], attach[r], owner[r], end_node)
	# each crossing from one walkway to the other, cut at a median into one per carriageway
	for n in zebra.size():
		var n0 := end_node[n][0]
		var n1 := end_node[n][1]
		if n0 < 0 or n1 < 0 or n0 == n1:
			continue
		var a := node_pos[n0]
		var b := node_pos[n1]
		var total := a.distance_to(b)
		var dir := (b - a) / total
		# the stretches over a carriageway, those less than MEDIAN apart taken as one; tested a
		# little to either side too, where walkers keep right (a kerb may run at a slant)
		var spans := PackedVector2Array()
		var inside := false
		var q := 0.0
		var side_v := dir.orthogonal() * LANE_SIDE
		var slant := false
		while q <= total:
			var at := a + dir * q
			# a crossing runs across the streets, never along one
			var along := _road_dir(at)
			if along != Vector2.ZERO and absf(along.dot(dir)) > SLANT_MAX:
				slant = true
				break
			if _on_carriageway(at) or _on_carriageway(at + side_v) \
					or _on_carriageway(at - side_v):
				if inside:
					spans[spans.size() - 1].y = q
				elif not spans.is_empty() and q - spans[spans.size() - 1].y < MEDIAN:
					spans[spans.size() - 1].y = q
				else:
					spans.append(Vector2(q, q))
				inside = true
			else:
				inside = false
			q += 0.5
		if slant:
			continue
		if spans.is_empty():
			_crossing(n0, n1, a, b, 0.0, 0.0, true, zebra[n] == 1)
			continue
		var long := false
		for k in spans.size():
			long = long or spans[k].y - spans[k].x > SPAN_MAX
		if long:
			continue
		var stops := PackedFloat32Array([0.0])
		var nodes := PackedInt32Array([n0])
		for k in range(1, spans.size()):
			var at := (spans[k - 1].y + spans[k].x) * 0.5
			stops.append(at)
			nodes.append(node_pos.size())
			node_pos.append(a + dir * at)
			node_out.append(PackedInt32Array())
		stops.append(total)
		nodes.append(n1)
		for k in spans.size():
			_crossing(nodes[k], nodes[k + 1], a + dir * stops[k], a + dir * stops[k + 1],
				spans[k].x - stops[k] - 0.1, spans[k].y - stops[k] + 0.1, false, zebra[n] == 1)
	busy.resize(c_mid.size())
	busy.fill(0)
	for c in c_mid.size():
		var key := Vector2i(floori(c_mid[c].x / CROSS_CELL), floori(c_mid[c].y / CROSS_CELL))
		if not _cgrid.has(key):
			_cgrid[key] = PackedInt32Array()
		_cgrid[key].append(c)


# one crossing edge from node n0 (at a) to n1 (at b), its kerbs k0 and k1 along it
func _crossing(n0: int, n1: int, a: Vector2, b: Vector2, k0: float, k1: float, free: bool,
		painted: bool) -> void:
	var c := c_mid.size()
	var e := _edge(PackedVector2Array([a, b]), n0, n1, FREE if free else CROSS)
	var total := length[e]
	var dir := (b - a) / maxf(total, 1e-4)
	cross[e] = c
	if free:
		k0 = total * 0.5
		k1 = total * 0.5
	k0 = clampf(k0, 0.2, total - 0.2)
	k1 = clampf(k1, k0, total - 0.2)
	c_edge.append(e)
	c_k0.append(k0)
	c_k1.append(k1)
	c_free.append(1 if free else 0)
	c_zebra.append(1 if painted else 0)
	# the band cars keep out of: the line from kerb to kerb
	c_across.append(dir)
	c_along.append(dir.orthogonal())
	c_mid.append(a + dir * (k0 + k1) * 0.5)
	c_half.append((k1 - k0) * 0.5)


# where the streets are crossed: first AreaBuilder._ground_marks' zebra rule (junctions = points
# shared by road lines with three or more arms; a crossing on each arm, just past the widest
# other street at the junction), plus the arms it leaves unpainted: narrow streets (crossed at
# the corner) and pedestrian streets (crossed anywhere, no cars); then the same at streets that
# cross or meet without sharing a point (as RoadNet splits them), all unpainted
static func zebra_spots(roads: Array, rad: float) -> Array[Dictionary]:
	var lines: Array[PackedVector2Array] = []
	var kept: Array = []
	for road: Dictionary in roads:
		var line := _line(road.get("line", []))
		if line.size() >= 2:
			lines.append(line)
			kept.append(road)
	roads = kept
	var out := _spots(roads, lines, rad, true)
	var split: Array[PackedVector2Array] = []
	for line in lines:
		split.append(line.duplicate())
	RoadNet.split_crossings(split)
	for spot in _spots(roads, split, rad, false):
		var dup := false
		for o in out:
			if (o["mid"] as Vector2).distance_to(spot["mid"]) < 4.0:
				dup = true
				break
		if not dup:
			out.append(spot)
	return out


static func _spots(roads: Array, lines: Array[PackedVector2Array], rad: float,
		paint: bool) -> Array[Dictionary]:
	var hits := {}
	for ri in lines.size():
		var line := lines[ri]
		for i in line.size():
			var key := Vector2i(roundi(line[i].x * 2.0), roundi(line[i].y * 2.0))
			if not hits.has(key):
				hits[key] = []
			hits[key].append([ri, i])
	var out: Array[Dictionary] = []
	for key: Vector2i in hits:
		var at := Vector2(key) * 0.5
		if at.length() > rad - 8.0:
			continue
		var arms: Array[Dictionary] = []
		for h: Array in hits[key]:
			var road: Dictionary = roads[h[0]]
			var line := lines[h[0]]
			var i: int = h[1]
			for step: int in [-1, 1]:
				var nb := i + step
				if nb < 0 or nb >= line.size():
					continue
				var d := line[nb] - line[i]
				if not paint:
					# the way the street leaves, a few metres out (short first pieces are noise)
					while d.length() < ARM_OUT and nb + step >= 0 and nb + step < line.size():
						nb += step
						d = line[nb] - line[i]
					if d.length() >= ARM_OUT:
						d = d.normalized() * (ARM_MIN + 1.0)
				if d.length() < ARM_MIN:
					continue
				arms.append({"road": h[0], "dir": d.normalized(),
					"width": float(road.get("width", 8.0)),
					"walk": road.get("kind", "") == "pedestrian"})
		if arms.size() < 3:
			continue
		for arm in arms:
			var other := 0.0
			for o in arms:
				if o != arm and o["road"] != arm["road"]:
					other = maxf(other, float(o["width"]) * 0.5)
			if other <= 0.0:
				continue
			var w: float = arm["width"]
			var zebra: bool = paint and not arm["walk"] and w >= 8.0
			var dist := other + 2.6
			out.append({"mid": at + (arm["dir"] as Vector2) * dist, "dir": arm["dir"],
				"width": w, "zebra": zebra, "walk": arm["walk"]})
	return out


# --- queries -------------------------------------------------------------------------------------

func edge_count() -> int:
	return length.size()


# where along edge e a distance s (from a) lies, the search started at segment `seg`
func seg_at(e: int, s: float, seg: int) -> int:
	var c := cum[e]
	var last := c.size() - 2
	seg = clampi(seg, 0, last)
	while seg > 0 and c[seg] > s:
		seg -= 1
	while seg < last and c[seg + 1] < s:
		seg += 1
	return seg


func point(e: int, s: float, seg: int) -> Vector2:
	var p := pts[e]
	var c := cum[e]
	var span := c[seg + 1] - c[seg]
	var t := clampf((s - c[seg]) / span, 0.0, 1.0) if span > 1e-5 else 0.0
	return p[seg].lerp(p[seg + 1], t)


func direction(e: int, seg: int) -> Vector2:
	var p := pts[e]
	return (p[seg + 1] - p[seg]).normalized()


# where RoadNet path p runs through each crossing's band: [crossing, s in, s out, ...] along the
# path, made the first time it is asked (junction curves are made lazily too)
func bands(rn: RoadNet, p: int) -> PackedFloat32Array:
	if p < _banded.size() and _banded[p] == 1:
		return _bands[p]
	if p >= _banded.size():
		_banded.resize(p + 64)
		_bands.resize(p + 64)
	var line := rn.pts[p]
	var lo := line[0]
	var hi := line[0]
	for q in line:
		lo = lo.min(q)
		hi = hi.max(q)
	var out := PackedFloat32Array()
	var seen := {}
	var c0 := Vector2i(floori((lo.x - 25.0) / CROSS_CELL), floori((lo.y - 25.0) / CROSS_CELL))
	var c1 := Vector2i(floori((hi.x + 25.0) / CROSS_CELL), floori((hi.y + 25.0) / CROSS_CELL))
	for cy in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			for c: int in _cgrid.get(Vector2i(cx, cy), PackedInt32Array()):
				if seen.has(c) or c_free[c] == 1:
					continue
				seen[c] = true
				var r := _through(line, c)
				if r.x < r.y:
					out.append(c)
					out.append(r.x)
					out.append(r.y)
	if out.is_empty():
		out = _no_bands
	_bands[p] = out
	_banded[p] = 1
	return out


# the stretch (s in, s out) of a polyline inside crossing c's band; in > out when it misses
func _through(line: PackedVector2Array, c: int) -> Vector2:
	var m := c_mid[c]
	var ax := c_across[c]
	var al := c_along[c]
	var hx := c_half[c] + BAND_OUT
	var s_in := INF
	var s_out := -INF
	var acc := 0.0
	for k in range(1, line.size()):
		var a := line[k - 1] - m
		var b := line[k] - m
		var l := a.distance_to(b)
		if l < 1e-5:
			continue
		# Liang-Barsky against |x| <= hx, |y| <= BAND in the crossing's frame
		var x0 := a.dot(ax)
		var y0 := a.dot(al)
		var dx := b.dot(ax) - x0
		var dy := b.dot(al) - y0
		var t0 := 0.0
		var t1 := 1.0
		var ok := true
		for side_i in 4:
			var pp: float = [-dx, dx, -dy, dy][side_i]
			var qq: float = [x0 + hx, hx - x0, y0 + BAND, BAND - y0][side_i]
			if absf(pp) < 1e-9:
				if qq < 0.0:
					ok = false
					break
				continue
			var r := qq / pp
			if pp < 0.0:
				t0 = maxf(t0, r)
			else:
				t1 = minf(t1, r)
			if t0 > t1:
				ok = false
				break
		if ok:
			s_in = minf(s_in, acc + t0 * l)
			s_out = maxf(s_out, acc + t1 * l)
		acc += l
	return Vector2(s_in, s_out)


# --- building ------------------------------------------------------------------------------------

# the stretches of a block's ring that lie on a pavement by a street
func _runs_of(ring: PackedVector2Array, poly: PackedVector2Array,
		runs: Array[PackedVector2Array], closed: Array[bool],
		owner: Array[PackedVector2Array]) -> void:
	var dense := PackedVector2Array()
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var n := maxi(1, ceili(a.distance_to(b) / STEP))
		for k in n:
			dense.append(a.lerp(b, float(k) / n))
	var m := dense.size()
	var ok := PackedByteArray()
	ok.resize(m)
	var all := true
	for k in m:
		ok[k] = 1 if _on_pavement(dense[k]) else 0
		all = all and ok[k] == 1
	if all:
		var loop := dense.duplicate()
		loop.append(dense[0])
		runs.append(loop)
		closed.append(true)
		owner.append(poly)
		return
	# start just after a piece that is not walkable, so no run wraps round the start
	var start := 0
	for k in m:
		if ok[k] == 0 or ok[(k + 1) % m] == 0:
			start = (k + 1) % m
			break
	var cur := PackedVector2Array()
	for j in m + 1:
		var k := (start + j) % m
		var nk := (k + 1) % m
		var walk := ok[k] == 1 and ok[nk] == 1 and j < m
		if walk:
			if cur.is_empty():
				cur.append(dense[k])
			cur.append(dense[nk])
		elif not cur.is_empty():
			if _len(cur) >= 3.0:
				runs.append(cur)
				closed.append(false)
				owner.append(poly)
			cur = PackedVector2Array()


# on a pavement: near some street's kerb, on no carriageway, clear of every lot and garden
# (where two blocks touch, one's ring runs into the other), inside the disc
func _on_pavement(q: Vector2) -> bool:
	if q.length() > radius - 3.0:
		return false
	for item: Array in _blocks.get(Vector2i(floori(q.x / SEG_CELL), floori(q.y / SEG_CELL)), []):
		if not (item[0] as Rect2).has_point(q):
			continue
		var poly: PackedVector2Array = item[1]
		if Geometry2D.is_point_in_polygon(q, poly):
			return false
		for k in poly.size():
			if Geometry2D.get_closest_point_to_segment(q, poly[k],
					poly[(k + 1) % poly.size()]).distance_squared_to(q) < BLOCK_CLEAR * BLOCK_CLEAR:
				return false
	var near := false
	for seg: Array in _segs.get(Vector2i(floori(q.x / SEG_CELL), floori(q.y / SEG_CELL)), []):
		var d := Geometry2D.get_closest_point_to_segment(q, seg[0], seg[1]).distance_to(q) \
			- float(seg[2])
		if d < KERB_IN and float(seg[3]) == 0.0:
			return false
		if d < KERB_OUT:
			near = true
	return near


# the first walkway met going from spot m along u, past the street's kerb: [run, s along it,
# point], or [] when it runs into a block (or nothing) first
func _march(m: Vector2, u: Vector2, half: float, runs: Array[PackedVector2Array],
		run_cum: Array[PackedFloat32Array], grid: Dictionary) -> Array:
	var d := half * 0.5
	while d < MARCH:
		var p := m + u * d
		var q := m + u * (d + 1.0)
		var key := Vector2i(floori((p.x + q.x) * 0.5 / SEG_CELL),
			floori((p.y + q.y) * 0.5 / SEG_CELL))
		var best := INF
		var out: Array = []
		for code: int in grid.get(key, PackedInt32Array()):
			var r := code >> 16
			var k := code & 65535
			var a := runs[r][k - 1]
			var b := runs[r][k]
			var hit: Variant = Geometry2D.segment_intersects_segment(p, q, a, b)
			if hit != null and (hit as Vector2).distance_to(p) < best:
				best = (hit as Vector2).distance_to(p)
				out = [r, run_cum[r][k - 1] + a.distance_to(hit), hit]
		if not out.is_empty():
			return out
		for item: Array in _blocks.get(key, []):
			if (item[0] as Rect2).has_point(q) and Geometry2D.is_point_in_polygon(q, item[1]):
				return []
		d += 1.0
	return []


# the direction of the carriageway at q (the nearest one under it), zero off the roads
func _road_dir(q: Vector2) -> Vector2:
	var best := INF
	var out := Vector2.ZERO
	for seg: Array in _segs.get(Vector2i(floori(q.x / SEG_CELL), floori(q.y / SEG_CELL)), []):
		var a: Vector2 = seg[0]
		var b: Vector2 = seg[1]
		var d := Geometry2D.get_closest_point_to_segment(q, a, b).distance_to(q)
		if float(seg[3]) == 0.0 and d < float(seg[2]) and d < best and a.distance_to(b) > 0.5:
			best = d
			out = (b - a).normalized()
	return out


func _on_carriageway(q: Vector2) -> bool:
	for seg: Array in _segs.get(Vector2i(floori(q.x / SEG_CELL), floori(q.y / SEG_CELL)), []):
		if float(seg[3]) == 0.0 and Geometry2D.get_closest_point_to_segment(q, seg[0],
				seg[1]).distance_to(q) < float(seg[2]):
			return true
	return false


# one walkway run cut into edges at its crossings' ends and every PIECE metres
func _cut_run(line: PackedVector2Array, c: PackedFloat32Array, is_closed: bool, at: Array,
		poly: PackedVector2Array, end_node: Array[PackedInt32Array]) -> void:
	var total := c[c.size() - 1]
	var cuts: Array[float] = []
	for a: Array in at:
		if is_closed:
			a[0] = fposmod(float(a[0]), total)
	at.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	# each crossing end on the cut it joins
	var joins: Array[Array] = []
	for a: Array in at:
		var s: float = a[0]
		if cuts.is_empty() or s - cuts[cuts.size() - 1] >= MERGE:
			cuts.append(s)
		joins.append([cuts.size() - 1, a[1], a[2]])
	# round a loop, the last cut may lie just before the first
	if is_closed and cuts.size() >= 2 and cuts[0] + total - cuts[cuts.size() - 1] < MERGE:
		for j in joins:
			if int(j[0]) == cuts.size() - 1:
				j[0] = 0
		cuts.pop_back()
	if not is_closed:
		if cuts.is_empty() or cuts[0] > MERGE:
			cuts.insert(0, 0.0)
			for j in joins:
				j[0] = int(j[0]) + 1
		else:
			cuts[0] = 0.0
		if total - cuts[cuts.size() - 1] > MERGE:
			cuts.append(total)
		else:
			cuts[cuts.size() - 1] = total
	elif cuts.is_empty():
		cuts.append(0.0)
	# every gap longer than PIECE gets nodes in between (marked -1 so joins keep their index)
	var all: Array[float] = []
	var keep: Array[int] = []
	var n := cuts.size()
	var spans := n if is_closed else n - 1
	for k in n:
		all.append(cuts[k])
		keep.append(k)
		if k >= spans:
			continue
		var s0 := cuts[k]
		var s1 := cuts[(k + 1) % n] + (total if is_closed and k == n - 1 else 0.0)
		var pieces := ceili((s1 - s0) / PIECE)
		for p in range(1, pieces):
			all.append(s0 + (s1 - s0) * p / pieces)
			keep.append(-1)
	var nodes := PackedInt32Array()
	var by_cut := PackedInt32Array()
	by_cut.resize(n)
	for k in all.size():
		var s := fmod(all[k], total) if is_closed else all[k]
		var id := node_pos.size()
		node_pos.append(_along(line, c, s))
		node_out.append(PackedInt32Array())
		nodes.append(id)
		if keep[k] >= 0:
			by_cut[keep[k]] = id
	for j in joins:
		end_node[j[1]][j[2]] = by_cut[j[0]]
	var m := all.size()
	for k in (m if is_closed else m - 1):
		var s0 := all[k]
		var s1 := all[k + 1] if k + 1 < m else all[0] + total
		# pieces past the loop's start
		if is_closed and s0 >= total:
			s0 -= total
			s1 -= total
		if s1 - s0 < 0.02:
			continue
		var piece := _slice(line, c, s0, s1, total)
		var e := _edge(piece, nodes[k], nodes[(k + 1) % m], PAVE)
		pave_m += length[e]
		# which hand the block is on
		var sg := seg_at(e, length[e] * 0.5, 0)
		var d := direction(e, sg)
		var probe := point(e, length[e] * 0.5, sg) + Vector2(d.y, -d.x) * RING_OUT * 1.6
		side[e] = 1 if Geometry2D.is_point_in_polygon(probe, poly) else -1


func _edge(line: PackedVector2Array, a: int, b: int, k: int) -> int:
	var e := length.size()
	pts.append(line)
	var c := _cumulate(line)
	cum.append(c)
	length.append(c[c.size() - 1])
	ea.append(a)
	eb.append(b)
	kind.append(k)
	cross.append(-1)
	side.append(0)
	mid.append(_along(line, c, c[c.size() - 1] * 0.5))
	node_out[a].append(e * 2)
	node_out[b].append(e * 2 + 1)
	return e


static func _cumulate(line: PackedVector2Array) -> PackedFloat32Array:
	var c := PackedFloat32Array()
	c.resize(line.size())
	var total := 0.0
	for i in range(1, line.size()):
		total += line[i].distance_to(line[i - 1])
		c[i] = total
	return c


static func _along(line: PackedVector2Array, c: PackedFloat32Array, s: float) -> Vector2:
	for i in range(1, line.size()):
		if c[i] >= s:
			var span := c[i] - c[i - 1]
			return line[i - 1].lerp(line[i], (s - c[i - 1]) / span) if span > 1e-5 \
				else line[i]
	return line[line.size() - 1]


# the part of a polyline from s0 to s1 (s1 may run past the end of a closed loop)
static func _slice(line: PackedVector2Array, c: PackedFloat32Array, s0: float, s1: float,
		total: float) -> PackedVector2Array:
	var out := PackedVector2Array([_along(line, c, s0)])
	var wrap := s1 > total + 1e-4
	var stop := total if wrap else s1
	for i in line.size():
		if c[i] > s0 + 1e-4 and c[i] < stop - 1e-4:
			out.append(line[i])
	if wrap:
		for i in line.size():
			if c[i] > 1e-4 and c[i] < s1 - total - 1e-4:
				out.append(line[i])
		out.append(_along(line, c, s1 - total))
	else:
		out.append(_along(line, c, s1))
	var clean := PackedVector2Array()
	for q in out:
		if clean.is_empty() or clean[clean.size() - 1].distance_to(q) > 0.02:
			clean.append(q)
	if clean.size() < 2:
		clean.append(clean[0] + Vector2(0.01, 0))
	return clean


static func _line(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in raw:
		out.append(Vector2(q[0], q[1]))
	return out


static func _len(line: PackedVector2Array) -> float:
	var total := 0.0
	for i in range(1, line.size()):
		total += line[i].distance_to(line[i - 1])
	return total
