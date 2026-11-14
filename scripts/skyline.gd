class_name Skyline
extends RefCounted

# The two top tiers, torres (4) and rascacielos (5), as plans: which masses stand where on a lot
# and how high. A plan is data only; AreaBuilder draws it and lays its works out from it, so the
# building site always grows into the building that will stand there.
# Heights are capped so a fully grown area still reads in the 600 px widget: no tower roof above
# TOWER_Z.y + a setback, no skyscraper roof above SKY_Z.y, one thin spire a few pixels more.
# A tier reads as "more" than the one before through its footprint, count, glass and gold, not
# through height. Four layouts (Oscar picks one; AreaBuilder.SKYLINE_STYLE):
#   CLUSTER   A: 2-3 concrete towers; 3-5 slender glass towers of staggered heights, gold crowns
#   BRIDGES   B: 2 towers on a podium; 2-3 glass towers on a shared podium joined by sky bridges
#   MEGA      C: a terraced slab; a wide stepped megablock with roof gardens and a helipad
#   RING      D: 3-4 towers round a plaza; a ring of 4-6 glass towers round a garden
#
# plan() -> {"groups": [{"foot": ground footprint (one object), "masses": [[pieces]],
#   "shadows": [[foot, height]], "top": px}], "built": footprints trees keep off, "ground":
#   [[poly, palette name]], "works": [[foot, goal px]], "top": Vector2 (metres), "top_z": px}
# A mass is drawn bottom to top and outlined in ink as one; masses are in painter's order.
# Piece keys: "look" (TOWER, GLASS, PODIUM, BRIDGE, TREE, PAD), "foot", "z0", "z1"; GLASS takes
# "lobby" and "crown" (0, 1 = 3 gold rows, 2 = 4), TOWER "props", the top piece of a mass
# "spire" (px) and "flag"; TREE "at" + "z"; PAD and LAWN lie on "foot" at "z1".

enum { CLUSTER, BRIDGES, MEGA, RING }
enum { TOWER, GLASS, PODIUM, BRIDGE, TREE, PAD, LAWN }
const NAMES: Array[String] = ["A RACIMO", "B PUENTES", "C MEGABLOQUE", "D ANILLO"]

# tier 4: a tower's main roof (px) by its levels (6..18 with each tower's own +-3)
const TOWER_Z := Vector2(30.0, 42.0)
const TOWER_SETBACK := 5.0
# tier 5: the tallest roof of the lot (px) by its levels (20..35); the others step down
const SKY_Z := Vector2(52.0, 60.0)
const SPIRE := 7
# each glass tower's crown: a setback this many px under its roof
const CROWN := 6.0
# heights of the other towers of a lot, as a share of the tallest, farthest first
const STAGGER: Array[float] = [1.0, 0.84, 0.72, 0.63, 0.56, 0.5]
const PODIUM_Z := 9.0
const BRIDGE_H := 4.0


# the highest pixel any variant of this tier can reach, for pops and the drawing's headroom
static func top(tier: int, levels: int) -> float:
	if tier == 4:
		return tower_z(levels + 3) + TOWER_SETBACK + 6.0
	return sky_z(levels) + SPIRE + 3.0


static func tower_z(levels: int) -> float:
	return floorf(lerpf(TOWER_Z.x, TOWER_Z.y, clampf((levels - 6) / 12.0, 0.0, 1.0)))


static func sky_z(levels: int) -> float:
	return floorf(lerpf(SKY_Z.x, SKY_Z.y, clampf((levels - 20) / 15.0, 0.0, 1.0)))


static func plan(style: int, tier: int, poly: PackedVector2Array, levels: int,
		id: String) -> Dictionary:
	var out := {"groups": [], "built": [] as Array[PackedVector2Array], "ground": [],
		"works": [], "top": Iso.centroid(poly), "top_z": 0.0}
	match style:
		BRIDGES:
			_bridges(out, tier, poly, levels, id)
		MEGA:
			_mega(out, tier, poly, levels, id)
		RING:
			_ring(out, tier, poly, levels, id)
		_:
			_cluster(out, tier, poly, levels, id)
	if (out["groups"] as Array).is_empty():
		# nothing fits the layout (a thin lot): one plain tower in the middle
		_cluster(out, tier, poly, levels, id)
	return out


# --- the four layouts ----------------------------------------------------------------------------

# A: towers apart on a plaza, each its own object; rascacielos = 3-5 slender glass towers whose
# heights step down toward the viewer, so the tallest never hides the others
static func _cluster(out: Dictionary, tier: int, poly: PackedVector2Array, levels: int,
		id: String) -> void:
	var area := Iso.area(poly)
	if tier == 4:
		var n := clampi(int(area / 1900.0), 1, 3)
		var half := clampf(sqrt(area) * 0.12, 6.0, 8.5)
		for at in spots(poly, n, half, id, 7.0):
			var lv := levels + int(Iso.h01(id + "tl%d_%d" % [roundi(at.x), roundi(at.y)]) * 7.0) - 3
			_add(out, _tower_mass(Iso.square(at, half), 0.0, tower_z(lv)), Iso.square(at, half))
		return
	var n := clampi(int(area / 1100.0) + 1, 3, 5)
	var half := clampf(sqrt(area) * 0.085, 4.5, 6.5)
	var at := spots(poly, n, half, id, 4.5)
	at.sort_custom(func(p: Vector2, q: Vector2) -> bool: return Iso.depth(p) < Iso.depth(q))
	var top := sky_z(levels)
	for k in at.size():
		var foot := Iso.square(at[k], half)
		var z := _stagger(top, k, id)
		_add(out, _glass_mass(foot, 0.0, z, k == 0), foot)


# B: one podium over most of the lot with the towers standing on it in a row, joined by glass
# sky bridges; one object, each tower and bridge ringed in ink on its own
static func _bridges(out: Dictionary, tier: int, poly: PackedVector2Array, levels: int,
		id: String) -> void:
	var area := Iso.area(poly)
	var n := 2 if tier == 4 or area < 4500.0 else 3
	var half := clampf(sqrt(area) * 0.09, 5.0, 8.0 if tier == 4 else 7.0)
	var at := spots(Iso.offset(poly, -3.0), n, half, id + "b", 6.0)
	if at.size() < 2:
		return
	# a chain along the way the towers spread most, so each bridge joins neighbours
	var spread := Geo.bounds(PackedVector2Array(at)).size
	var axis := Vector2.RIGHT if spread.x >= spread.y else Vector2.UP
	at.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.dot(axis) < q.dot(axis))
	var feet: Array[PackedVector2Array] = []
	var corners := PackedVector2Array()
	for c in at:
		feet.append(Iso.square(c, half))
		corners.append_array(Iso.square(c, half + 3.5))
	# the podium: the towers' hull and a terrace round them, cut to the lot
	var hull := Geometry2D.convex_hull(corners)
	hull.resize(hull.size() - 1)
	var base := PackedVector2Array()
	var keep := Iso.offset(poly, -2.0)
	if keep.size() < 3:
		return
	for part in Geo.clip(Iso.clean(hull), keep):
		if base.size() < 3 or Iso.area(part) > Iso.area(base):
			base = Iso.clean(part)
	if base.size() < 3:
		return
	var pz := PODIUM_Z - (3.0 if tier == 4 else 0.0)
	var tops: Array[float] = []
	for k in feet.size():
		if tier == 4:
			tops.append(tower_z(levels + int(Iso.h01(id + "bt%d" % k) * 5.0) - 2))
		else:
			# the middle one tallest, the ends stepped down
			var rank := absi(k * 2 - (feet.size() - 1))
			tops.append(_stagger(sky_z(levels), rank, id + str(k)))
	var masses: Array = [[{"look": PODIUM, "foot": base, "z0": 0.0, "z1": pz}]]
	var lawn := Iso.offset(base, -1.0)
	if lawn.size() >= 3:
		masses[0].append({"look": LAWN, "foot": lawn, "z0": pz, "z1": pz})
	var items: Array = []
	for k in feet.size():
		var m: Array = _tower_mass(feet[k], pz, tops[k]) if tier == 4 \
			else _glass_mass(feet[k], pz, tops[k], tops[k] >= tops.max())
		items.append([Iso.depth(Iso.centroid(feet[k])), m])
	if tier == 5:
		for k in feet.size() - 1:
			var a := Iso.centroid(feet[k])
			var b := Iso.centroid(feet[k + 1])
			var w := (b - a).normalized().orthogonal() * 1.4
			var span := PackedVector2Array([a + w, b + w, b - w, a - w])
			# only the stretch between the two towers: a bridge drawn inside a tower would show
			# on its face
			var between := PackedVector2Array()
			for part in Geo.minus(span, Iso.offset(feet[k], 0.05)):
				for rest in Geo.minus(part, Iso.offset(feet[k + 1], 0.05)):
					if between.size() < 3 or Iso.area(rest) > Iso.area(between):
						between = rest
			if between.size() < 3:
				continue
			var z := floorf(pz + (minf(tops[k], tops[k + 1]) - pz) * 0.62)
			for lift in [0.0, -14.0]:
				var z0: float = z + lift
				if z0 - pz < 10.0:
					continue
				items.append([Iso.depth(Iso.centroid(between)), [{"look": BRIDGE,
					"foot": Iso.clean(between), "z0": z0, "z1": z0 + BRIDGE_H}]])
	items.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	for it: Array in items:
		masses.append(it[1])
	var shadows: Array = [[base, pz]]
	for k in feet.size():
		shadows.append([feet[k], tops[k]])
		out["works"].append([feet[k], tops[k]])
	var best := tops.find(tops.max())
	_group(out, base, masses, shadows, Iso.centroid(feet[best]), tops.max())


# C: one wide building stepping back in terraces toward the far corner, roof gardens with trees
# on the terraces the camera sees; rascacielos adds a glass top with a gold crown and a helipad
static func _mega(out: Dictionary, tier: int, poly: PackedVector2Array, levels: int,
		id: String) -> void:
	var s0 := _rect_in(poly, 3.0, 0.84)
	if s0.size() < 3 or Iso.area(s0) < 120.0:
		return
	var steps: Array[PackedVector2Array] = [s0]
	var tz := sky_z(levels) if tier == 5 else tower_z(levels) + TOWER_SETBACK - 4.0
	var zs: Array[float] = [floorf(tz * 0.6), tz]
	if tier == 5:
		zs = [floorf(tz * 0.4), floorf(tz * 0.7), tz]
	for k in range(1, zs.size()):
		var prev := steps[k - 1]
		var cut := Iso.moved(Iso.offset(prev, -3.5), Vector2(-1.5, 1.5))
		var keep := Iso.offset(prev, -1.0)
		var next := PackedVector2Array()
		if cut.size() >= 3 and keep.size() >= 3:
			for part in Geo.clip(cut, keep):
				if next.size() < 3 or Iso.area(part) > Iso.area(next):
					next = Iso.clean(part)
		if next.size() < 3 or Iso.area(next) < 60.0:
			break
		steps.append(next)
	var masses: Array = []
	var z0 := 0.0
	for k in steps.size():
		var z1: float = zs[k] if k < steps.size() - 1 else tz
		var last := k == steps.size() - 1
		var piece := {"foot": steps[k], "z0": z0, "z1": z1}
		if tier == 5 and k > 0:
			piece.merge({"look": GLASS, "lobby": false, "crown": 2 if last else 1})
		else:
			piece.merge({"look": TOWER, "lobby": k == 0, "props": last and tier == 4})
		masses.append([piece])
		z0 = z1
	# roof gardens: a lawn on each terrace the next step leaves, trees on its near side
	var trees: Array = []
	for k in steps.size() - 1:
		var z: float = masses[k][0]["z1"]
		var lawn := Iso.offset(steps[k], -1.1)
		if lawn.size() >= 3:
			masses[k].append({"look": LAWN, "foot": lawn, "z0": z, "z1": z})
		var upper := steps[k + 1]
		for i in upper.size():
			var a := upper[i]
			var b := upper[(i + 1) % upper.size()]
			var nrm := Vector2(-(b.y - a.y), -(b.x - a.x)).normalized()
			if nrm.x + nrm.y <= 1e-3:
				continue
			var push := Vector2(nrm.x, -nrm.y) * 1.8
			var m := int(a.distance_to(b) / 6.0)
			for j in m:
				var q := a.lerp(b, (j + 0.5) / m) + push
				if Geometry2D.is_point_in_polygon(q, Iso.offset(steps[k], -1.2)) \
						and Iso.h01(id + "rt%d_%d_%d" % [k, i, j]) < 0.75:
					trees.append({"look": TREE, "at": q, "z": z})
	if not trees.is_empty():
		masses.append(trees)
	var top_foot := steps[steps.size() - 1]
	if tier == 5:
		var pad := Iso.offset(top_foot, -1.6)
		if pad.size() >= 3 and Iso.area(pad) > 30.0:
			masses.append([{"look": PAD, "foot": pad, "z0": tz, "z1": tz}])
	masses[steps.size() - 1][0]["flag"] = true
	_group(out, s0, masses, [[s0, tz]], Iso.centroid(top_foot), tz)
	out["works"].append([s0, tz])


# D: towers on the corners of a square round a garden in the lot's middle (a fountain, lawn),
# the far ones the tallest; each tower its own object
static func _ring(out: Dictionary, tier: int, poly: PackedVector2Array, levels: int,
		id: String) -> void:
	var inner := Iso.offset(poly, -3.0)
	if inner.size() < 3:
		return
	var area := Iso.area(poly)
	var half := clampf(sqrt(area) * (0.09 if tier == 4 else 0.075), 4.5, 7.0 if tier == 4 else 6.0)
	var want := clampi(int(area / 1000.0), 4, 6)
	if tier == 4:
		want = 3 + int(Iso.h01(id + "r4") * 2.0)
	var picks: Array[Vector2] = []
	var path := PackedVector2Array()
	while half >= 4.0 and picks.size() < 3:
		# towers stand round a ring path half a tower in from the lot's edge, spread out by
		# farthest-point picking so they frame the garden whatever the lot's shape
		path = Iso.offset(inner, -half - 0.2)
		picks.clear()
		if path.size() >= 3:
			var cand: Array[Vector2] = []
			for i in path.size():
				var a := path[i]
				var b := path[(i + 1) % path.size()]
				var m := maxi(1, int(a.distance_to(b)))
				for j in m:
					var q := a.lerp(b, float(j) / m)
					if Iso.contains(inner, Iso.square(q, half)):
						cand.append(q)
			if not cand.is_empty():
				picks.append(cand[int(Iso.h01(id + "r0") * cand.size())])
			while picks.size() < want and not cand.is_empty():
				var best := -1.0
				var pick := Vector2.ZERO
				for q in cand:
					var near := INF
					for o in picks:
						near = minf(near, maxf(absf(o.x - q.x), absf(o.y - q.y)))
					if near > best:
						best = near
						pick = q
				if best < half * 2.0 + 4.0:
					break
				picks.append(pick)
		if picks.size() < 3:
			half -= 0.5
	if picks.size() < 3:
		return
	picks.sort_custom(func(p: Vector2, q: Vector2) -> bool: return Iso.depth(p) < Iso.depth(q))
	for k in picks.size():
		var foot := Iso.square(picks[k], half)
		if tier == 4:
			var lv := levels + int(Iso.h01(id + "rl%d" % k) * 5.0) - 2
			_add(out, _tower_mass(foot, 0.0, tower_z(lv)), foot)
		else:
			_add(out, _glass_mass(foot, 0.0, _stagger(sky_z(levels), k, id), k == 0), foot)
	var garden := Iso.offset(inner, -half * 2.0 - 2.5)
	if garden.size() >= 3 and Iso.area(garden) > 40.0:
		out["ground"].append([garden, "GRASS"])
		var lawn := Iso.offset(garden, -0.8)
		if lawn.size() >= 3:
			out["ground"].append([lawn, "GRASS_L"])
		var mid := Iso.centroid(garden)
		var pool := Iso.square(mid, 2.4)
		if Iso.contains(garden, Iso.square(mid, 3.2)):
			out["ground"].append([pool, "CREAM"])
			out["ground"].append([Iso.offset(pool, -0.6), "CYAN_M"])
			out["ground"].append([Iso.offset(pool, -1.2), "CYAN"])


# --- masses --------------------------------------------------------------------------------------

# a slender glass tower: a shaft with a glass lobby and a gold band under its roof, then a setback
# crown with a deeper gold band; the tallest of a lot carries the spire
static func _glass_mass(foot: PackedVector2Array, z0: float, top: float, tallest: bool) -> Array:
	var crown := Iso.offset(foot, -1.2)
	var out: Array = []
	if crown.size() >= 3 and Iso.area(crown) > 8.0 and top - z0 > 24.0:
		out.append({"look": GLASS, "foot": foot, "z0": z0, "z1": top - CROWN, "lobby": true,
			"crown": 1})
		out.append({"look": GLASS, "foot": crown, "z0": top - CROWN, "z1": top, "lobby": false,
			"crown": 2})
	else:
		out.append({"look": GLASS, "foot": foot, "z0": z0, "z1": top, "lobby": true, "crown": 2})
	out[out.size() - 1]["spire"] = SPIRE if tallest else 0
	out[out.size() - 1]["flag"] = tallest
	return out


# a concrete-and-glass tower (the old torres): a shaft with a glass lobby, a setback top, roof huts
static func _tower_mass(foot: PackedVector2Array, z0: float, top: float) -> Array:
	var base := Iso.offset(foot, -1.2)
	if base.size() < 3:
		base = foot
	var crown := Iso.offset(base, -2.2)
	if crown.size() < 3 or Iso.area(crown) <= 6.0:
		return [{"look": TOWER, "foot": base, "z0": z0, "z1": z0 + top, "lobby": true,
			"props": true}]
	return [{"look": TOWER, "foot": base, "z0": z0, "z1": z0 + top, "lobby": true},
		{"look": TOWER, "foot": crown, "z0": z0 + top, "z1": z0 + top + TOWER_SETBACK,
		"lobby": false, "props": true}]


# --- helpers -------------------------------------------------------------------------------------

# the k-th tower's roof, farthest first: the tallest steps down, each a little off by hash
static func _stagger(top: float, k: int, id: String) -> float:
	var f: float = STAGGER[mini(k, STAGGER.size() - 1)]
	if k > 0:
		f += (Iso.h01(id + "st%d" % k) - 0.5) * 0.06
	return floorf(top * f)


# one tower standing alone: a group of one mass
static func _add(out: Dictionary, mass: Array, foot: PackedVector2Array) -> void:
	var top: float = mass[mass.size() - 1]["z1"]
	var z0: float = mass[0]["z0"]
	_group(out, foot, [mass], [[mass[0]["foot"], top]], Iso.centroid(foot), top)
	out["works"].append([mass[0]["foot"], top - z0])


static func _group(out: Dictionary, foot: PackedVector2Array, masses: Array, shadows: Array,
		at: Vector2, top: float) -> void:
	out["groups"].append({"foot": foot, "masses": masses, "shadows": shadows, "top": top})
	out["built"].append(foot)
	if top > float(out["top_z"]):
		out["top_z"] = top
		out["top"] = at


# the lot's biggest rectangle-ish footprint: its minimal rectangle shrunk about its middle, cut
# to the lot `margin` metres in
static func _rect_in(poly: PackedVector2Array, margin: float, shrink: float) -> PackedVector2Array:
	var inner := Iso.offset(poly, -margin)
	if inner.size() < 3:
		return PackedVector2Array()
	var rect := Iso.min_rect(inner, shrink)
	if rect.size() < 4:
		return PackedVector2Array()
	var best := PackedVector2Array()
	for part in Geo.clip(rect, inner):
		if best.size() < 3 or Iso.area(part) > Iso.area(best):
			best = part
	return Iso.clean(best) if best.size() >= 3 else best


# up to n square building spots of half-size `half` well inside the lot, `gap` metres apart,
# picked by hash (or the one nearest the middle when `central`); smaller when nothing fits
static func spots(poly: PackedVector2Array, n: int, half: float, seed: String, gap: float,
		central: bool = false) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var inner := Iso.offset(poly, -3.0)
	if inner.size() < 3:
		return out
	var box := Geo.bounds(inner)
	var h := half
	while h >= 4.0 and out.is_empty():
		var step := h * 2.0 + gap
		var cand: Array = []
		var y := box.position.y + h
		while y <= box.end.y - h:
			var x := box.position.x + h
			while x <= box.end.x - h:
				var at := Vector2(x, y)
				if Iso.contains(inner, Iso.square(at, h)):
					cand.append([Iso.h01(seed + "sp%.0f_%.0f" % [x, y]), at])
				x += 2.0
			y += 2.0
		if central:
			var mid := Iso.centroid(poly)
			cand.sort_custom(func(p: Array, q: Array) -> bool:
				return (p[1] as Vector2).distance_to(mid) < (q[1] as Vector2).distance_to(mid))
		else:
			cand.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
		for c: Array in cand:
			var at: Vector2 = c[1]
			var clear := true
			for o in out:
				if absf(o.x - at.x) < step and absf(o.y - at.y) < step:
					clear = false
					break
			if clear:
				out.append(at)
				if out.size() >= n:
					break
		if out.is_empty():
			h *= 0.8
	return out
