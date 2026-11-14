class_name OfficeMark
extends RefCounted

# Where an office's marker stands in its area. The office is not a building (docs/GAMEPLAY.md
# "Tu oficina"): it only marks the spot the player clicked, the middle of its radius ring, with a
# gold pin on the ground (AreaBuilder draws it). The pin must never stand in a lot, where it
# would get in the way of what is built there, nor on the asphalt, so it goes to the open ground
# nearest the clicked point: the pavement, a pedestrian street, a square or a park; among the
# spots about as near as the nearest, the one nearest the viewer, so the lot it stands in front
# of does not hide it. Baked areas keep it as "office_mark" [x, y]; older files work it out when
# they are drawn.

# how far from the clicked point (m) the pin may go looking for open ground
const REACH := 70.0
# room the pin keeps from a lot's edge and from the asphalt's edge (m)
const LOT_CLEAR := 1.0
const ROAD_CLEAR := 0.9
# a rail bed's half width plus room (m)
const RAIL_CLEAR := 3.4
# spots up to this much farther than the nearest open one may win by being nearer the viewer
const PREFER := 8.0
# keep this far inside the disc's edge (m)
const EDGE := 12.0
# the radius of the dashed gold ring painted round the pin's foot (m)
const RING := 4.0


# the marker's ground point (metres, the area's frame), worked out once and kept in the block
static func at(block: Dictionary) -> Vector2:
	var kept: Variant = block.get("office_mark")
	if kept is Array and (kept as Array).size() == 2:
		return Vector2(float(kept[0]), float(kept[1]))
	var p := spot(block)
	block["office_mark"] = [snappedf(p.x, 0.1), snappedf(p.y, 0.1)]
	return Vector2(block["office_mark"][0], block["office_mark"][1])


static func spot(block: Dictionary) -> Vector2:
	var near := REACH + 20.0
	var lots: Array = []
	for p: Dictionary in block.get("plots", []):
		var poly := _pts(p["poly"])
		var box := Geo.bounds(poly)
		if box.grow(near).has_point(Vector2.ZERO):
			lots.append([poly, box.grow(LOT_CLEAR)])
	var waters: Array = []
	for w: Dictionary in block.get("water", []):
		var poly := _pts(w["poly"])
		var box := Geo.bounds(poly)
		if box.grow(near).has_point(Vector2.ZERO):
			waters.append([poly, box])
	# segments to keep clear of: [a, b, clearance]
	var segs: Array = []
	for r: Dictionary in block.get("roads", []):
		if r["kind"] == "pedestrian":
			continue
		_add_segs(segs, _pts(r["line"]), float(r["width"]) * 0.5 + ROAD_CLEAR, near)
	for r: Dictionary in block.get("rails", []):
		if r["kind"] != "tram":
			_add_segs(segs, _pts(r["line"]), RAIL_CLEAR, near)
	var limit := float(block.get("radius_m", Rules.MAX_RADIUS)) - EDGE
	var found := -1.0
	var best := Vector2.ZERO
	var r := 0.0
	while r <= REACH and r <= limit:
		var n := 1 if r == 0.0 else ceili(TAU * r)
		for k in n:
			var a := TAU * k / n
			var q := Vector2(cos(a), sin(a)) * r
			if not _open(q, lots, waters, segs):
				continue
			if found < 0.0:
				found = r
				best = q
			elif Iso.depth(q) > Iso.depth(best):
				best = q
		if found >= 0.0 and r >= found + PREFER:
			break
		r += 1.0
	return best


static func _open(q: Vector2, lots: Array, waters: Array, segs: Array) -> bool:
	for s: Array in segs:
		if Geometry2D.get_closest_point_to_segment(q, s[0], s[1]).distance_to(q) < float(s[2]):
			return false
	for l: Array in lots:
		if not (l[1] as Rect2).has_point(q):
			continue
		var poly: PackedVector2Array = l[0]
		if Geometry2D.is_point_in_polygon(q, poly):
			return false
		for i in poly.size():
			var d := Geometry2D.get_closest_point_to_segment(q, poly[i],
				poly[(i + 1) % poly.size()]).distance_to(q)
			if d < LOT_CLEAR:
				return false
	for w: Array in waters:
		if (w[1] as Rect2).has_point(q) and Geometry2D.is_point_in_polygon(q, w[0]):
			return false
	return true


static func _add_segs(segs: Array, line: PackedVector2Array, clear: float, near: float) -> void:
	for i in range(1, line.size()):
		var a := line[i - 1]
		var b := line[i]
		if Geometry2D.get_closest_point_to_segment(Vector2.ZERO, a, b).length() < near + clear:
			segs.append([a, b, clear])


static func _pts(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in raw:
		out.append(Vector2(q[0], q[1]))
	return out
