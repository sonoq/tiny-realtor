class_name Geo
extends RefCounted

# Plain geometry shared by the bakers and the views: lat/lon to local metres, distances, polygon
# clean-up and the two OSM shapes that need assembling (multipolygon rings and coastlines).
# Local frame: metres, x east, y north (y up), origin at a chosen lat/lon.

const EARTH_R := 6371000.0
const M_PER_DEG_LAT := 110540.0
const M_PER_DEG_LON := 111320.0
# vertices closer than this are one vertex; OSM traces often double-click corners
const WELD := 0.3


# metres per degree of longitude and latitude at a latitude, for a local flat projection
static func scale_at(lat: float) -> Vector2:
	return Vector2(M_PER_DEG_LON * cos(deg_to_rad(lat)), M_PER_DEG_LAT)


static func to_local(lat: float, lon: float, lat0: float, lon0: float, k: Vector2) -> Vector2:
	return Vector2((lon - lon0) * k.x, (lat - lat0) * k.y)


static func to_latlon(p: Vector2, lat0: float, lon0: float, k: Vector2) -> Vector2:
	return Vector2(lat0 + p.y / k.y, lon0 + p.x / k.x)


# great-circle distance in metres; offices in different cities compare with this
static func distance(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := p2 - p1
	var dl := deg_to_rad(lon2 - lon1)
	var a := sin(dp * 0.5) ** 2 + cos(p1) * cos(p2) * sin(dl * 0.5) ** 2
	return 2.0 * EARTH_R * asin(minf(1.0, sqrt(a)))


# an n-gon standing in for a circle, counter-clockwise in y-up metres
static func circle(radius: float, sides: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in sides:
		var a := TAU * i / sides
		out.append(Vector2(cos(a), sin(a)) * radius)
	return out


# signed area, positive when counter-clockwise in y-up coordinates
static func area(poly: PackedVector2Array) -> float:
	var sum := 0.0
	var n := poly.size()
	for i in n:
		var a := poly[i]
		var b := poly[(i + 1) % n]
		sum += a.x * b.y - b.x * a.y
	return sum * 0.5


static func centre(poly: PackedVector2Array) -> Vector2:
	var sum := Vector2.ZERO
	for p in poly:
		sum += p
	return sum / maxf(1.0, poly.size())


static func bounds(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r


# drops repeated and near-duplicate vertices (and a closing vertex equal to the first)
static func weld(pts: PackedVector2Array, tol: float = WELD) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > tol:
			out.append(p)
	while out.size() > 1 and out[0].distance_to(out[out.size() - 1]) <= tol:
		out.remove_at(out.size() - 1)
	return out


# turns any traced ring into one Godot can triangulate: welded, and if it self-intersects, run
# through Clipper (a tiny offset unions the loops) keeping the largest piece
static func repair(poly: PackedVector2Array) -> PackedVector2Array:
	var p := weld(poly)
	if p.size() < 3:
		return PackedVector2Array()
	if not Geometry2D.triangulate_polygon(p).is_empty():
		return p
	var best := PackedVector2Array()
	for part: PackedVector2Array in Geometry2D.offset_polygon(p, 0.05):
		if not Geometry2D.is_polygon_clockwise(part) and absf(area(part)) > absf(area(best)):
			best = part
	if best.size() >= 3 and not Geometry2D.triangulate_polygon(best).is_empty():
		return best
	return PackedVector2Array()


# the pieces of a polygon inside a convex clip shape (outer rings only, holes dropped)
static func clip(poly: PackedVector2Array, shape: PackedVector2Array) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for part: PackedVector2Array in Geometry2D.intersect_polygons(poly, shape):
		if Geometry2D.is_polygon_clockwise(part) == Geometry2D.is_polygon_clockwise(shape):
			out.append(part)
	return out


# Douglas-Peucker, for the city map where 10 m of detail is invisible
static func simplify(line: PackedVector2Array, tol: float) -> PackedVector2Array:
	if line.size() < 3:
		return line
	var keep := PackedByteArray()
	keep.resize(line.size())
	keep[0] = 1
	keep[line.size() - 1] = 1
	var stack: Array[Vector2i] = [Vector2i(0, line.size() - 1)]
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var far := -1.0
		var at := -1
		for i in range(span.x + 1, span.y):
			var q := Geometry2D.get_closest_point_to_segment(line[i], line[span.x], line[span.y])
			var d := q.distance_to(line[i])
			if d > far:
				far = d
				at = i
		if at >= 0 and far > tol:
			keep[at] = 1
			stack.append(Vector2i(span.x, at))
			stack.append(Vector2i(at, span.y))
	var out := PackedVector2Array()
	for i in line.size():
		if keep[i] == 1:
			out.append(line[i])
	return out


# joins open ways end to end into closed rings, as OSM multipolygon members come in pieces;
# pieces that never close are dropped
static func rings(pieces: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var open: Array[PackedVector2Array] = []
	for piece in pieces:
		if piece.size() < 2:
			continue
		if piece[0].distance_to(piece[piece.size() - 1]) < 0.01 and piece.size() > 3:
			out.append(weld(piece))
		else:
			open.append(piece)
	while not open.is_empty():
		var ring: PackedVector2Array = open.pop_back()
		var grew := true
		while grew and ring[0].distance_to(ring[ring.size() - 1]) > 0.01:
			grew = false
			var tail := ring[ring.size() - 1]
			for i in open.size():
				var p := open[i]
				if p[0].distance_to(tail) < 0.01:
					ring.append_array(p.slice(1))
				elif p[p.size() - 1].distance_to(tail) < 0.01:
					var rev := p.duplicate()
					rev.reverse()
					ring.append_array(rev.slice(1))
				else:
					continue
				open.remove_at(i)
				grew = true
				break
		if ring[0].distance_to(ring[ring.size() - 1]) <= 0.01 and ring.size() > 3:
			out.append(weld(ring))
	return out


# joins directed ways whose end is another's start (coastlines keep their direction)
static func chains(pieces: Array[PackedVector2Array]) -> Array[PackedVector2Array]:
	var open: Array[PackedVector2Array] = []
	for p in pieces:
		if p.size() >= 2:
			open.append(p.duplicate())
	var merged := true
	while merged:
		merged = false
		for i in open.size():
			for j in open.size():
				if i == j:
					continue
				var a := open[i]
				var b := open[j]
				if a[a.size() - 1].distance_to(b[0]) < 0.01 and a[0].distance_to(a[a.size() - 1]) > 0.01:
					a.append_array(b.slice(1))
					open[i] = a
					open.remove_at(j)
					merged = true
					break
			if merged:
				break
	return open


# Sea polygons inside a convex border (counter-clockwise, y up) from coastline chains, which
# OSM draws with land on the left and water on the right. Each chain is cut where it crosses the
# border; the water polygon follows a piece to its exit, then the border clockwise to the next
# entry, and so on until it closes. Closed rings fully inside are islands (or lakes of sea) and
# are returned separately so the caller paints them as land on top.
static func sea(coast: Array[PackedVector2Array], border: PackedVector2Array) -> Dictionary:
	var pieces: Array[Dictionary] = []
	var islands: Array[PackedVector2Array] = []
	for chain in chains(coast):
		var closed := chain[0].distance_to(chain[chain.size() - 1]) < 0.01
		var all_in := true
		for p in chain:
			if not Geometry2D.is_point_in_polygon(p, border):
				all_in = false
				break
		if closed and all_in:
			islands.append(weld(chain))
			continue
		pieces.append_array(_cut(chain, border))
	var water: Array[PackedVector2Array] = []
	if pieces.is_empty():
		# no coastline crosses: the box is all sea only if an island ring says so (land is ccw)
		if not islands.is_empty():
			water.append(border)
		return {"water": water, "islands": islands}
	var perim := _perimeter(border)
	var used := PackedByteArray()
	used.resize(pieces.size())
	for start in pieces.size():
		if used[start] == 1:
			continue
		var poly := PackedVector2Array()
		var k := start
		var guard := 0
		while guard < pieces.size() + 1:
			guard += 1
			used[k] = 1
			var piece: Dictionary = pieces[k]
			poly.append_array(piece["pts"])
			# walk the border clockwise (decreasing parameter) from this exit to the next entry
			var exit_t: float = piece["exit"]
			var best := -1
			var best_gap := INF
			for j in pieces.size():
				var gap := fposmod(exit_t - float(pieces[j]["entry"]), perim)
				if gap < best_gap:
					best_gap = gap
					best = j
			poly.append_array(_border_walk(border, perim, exit_t, best_gap))
			k = best
			if k == start:
				break
		var fixed := repair(poly)
		if fixed.size() >= 3:
			water.append(fixed)
	return {"water": water, "islands": islands}


# the parts of a directed chain inside the border, each with where it enters and leaves
static func _cut(chain: PackedVector2Array, border: PackedVector2Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var perim := _perimeter(border)
	var inside := Geometry2D.is_point_in_polygon(chain[0], border)
	var cur := PackedVector2Array()
	var entry := -1.0
	if inside:
		# a chain starting inside (data cut short): enter it at the nearest border point
		entry = _param(border, chain[0])
		cur.append(_on_border(border, chain[0]))
		cur.append(chain[0])
	for i in range(1, chain.size()):
		var a := chain[i - 1]
		var b := chain[i]
		var hits := _crossings(a, b, border)
		for hit: Vector2 in hits:
			if inside:
				cur.append(hit)
				out.append({"pts": cur, "entry": entry, "exit": _param(border, hit)})
				cur = PackedVector2Array()
				inside = false
			else:
				entry = _param(border, hit)
				cur = PackedVector2Array([hit])
				inside = true
		if inside:
			cur.append(b)
	if inside and cur.size() >= 2:
		var end := cur[cur.size() - 1]
		cur.append(_on_border(border, end))
		out.append({"pts": cur, "entry": entry, "exit": _param(border, end)})
	return out


# where segment a-b crosses the border, sorted from a
static func _crossings(a: Vector2, b: Vector2, border: PackedVector2Array) -> Array[Vector2]:
	var hits: Array[Vector2] = []
	var n := border.size()
	for i in n:
		var hit: Variant = Geometry2D.segment_intersects_segment(a, b, border[i], border[(i + 1) % n])
		if hit != null:
			hits.append(hit)
	hits.sort_custom(func(p: Vector2, q: Vector2) -> bool:
		return a.distance_squared_to(p) < a.distance_squared_to(q))
	return hits


static func _perimeter(border: PackedVector2Array) -> float:
	var sum := 0.0
	for i in border.size():
		sum += border[i].distance_to(border[(i + 1) % border.size()])
	return sum


# distance along the border (counter-clockwise from vertex 0) to the border point nearest p
static func _param(border: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	var at := 0.0
	var run := 0.0
	for i in border.size():
		var a := border[i]
		var b := border[(i + 1) % border.size()]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := q.distance_squared_to(p)
		if d < best:
			best = d
			at = run + a.distance_to(q)
		run += a.distance_to(b)
	return at


static func _on_border(border: PackedVector2Array, p: Vector2) -> Vector2:
	var best := INF
	var out := p
	for i in border.size():
		var q := Geometry2D.get_closest_point_to_segment(p, border[i], border[(i + 1) % border.size()])
		if q.distance_squared_to(p) < best:
			best = q.distance_squared_to(p)
			out = q
	return out


# the border vertices met walking clockwise a distance `gap` from parameter t
static func _border_walk(border: PackedVector2Array, perim: float, t: float,
		gap: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var starts := PackedFloat32Array()
	var run := 0.0
	for i in border.size():
		starts.append(run)
		run += border[i].distance_to(border[(i + 1) % border.size()])
	# vertex i sits at starts[i]; clockwise means walking toward smaller parameters
	var picks: Array[Vector2] = []
	for i in border.size():
		var back := fposmod(t - starts[i], perim)
		if back > 0.001 and back < gap - 0.001:
			picks.append(Vector2(back, i))
	picks.sort()
	for pick in picks:
		out.append(border[int(pick.y)])
	return out
