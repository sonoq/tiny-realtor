class_name Skyline
extends RefCounted

# The two top tiers, torres (4) and rascacielos (5), as plans: which buildings stand where on a
# lot, how high and in what materials. A plan is data only; AreaBuilder draws it and lays its
# works out from it, so the building site always grows into the building that will stand there.
#
# Every lot picks its own composition (an archetype) and its own materials (a scheme) by stable
# hash, so a grown district is as mixed as the mid tiers: towers of different shapes, glass in
# blue, teal, cyan, green, bronze or dark steel, white or cream concrete, brick and stone, office
# slabs and hotel wings and apartment rows between them, crowns, spires, helipads, pyramids, roof
# gardens, pools, water tanks, AC units and rooftop signs. Lower buildings, gardens and plazas
# stay round the tall ones, so the skyline has peaks and valleys.
# Heights are capped so a grown area still reads in the 600 px widget: no torres roof above
# TOWER_Z.y + a setback, no rascacielos roof above SKY_Z.y, one thin spire or mast a few pixels
# more. Rascacielos stay the premium tier: their tallest element always reaches sky_z (the
# highest roofs of the area) and wears a crown (gold bands, a spire, a helipad, a pyramid or a
# mast), on bigger lots.
#
# plan() -> {"groups": [{"foot": ground footprint (one object), "masses": [[pieces]],
#   "shadows": [[foot, height]], "top": px}], "built": footprints trees keep off, "ground":
#   [[poly, palette name]], "works": [[foot, goal px]], "top": Vector2 (metres), "top_z": px,
#   "base": the lot's ground (palette name), "trees": square metres per tree, "kind": archetype}
# A mass is drawn bottom to top and outlined in ink as one; masses are in painter's order.
# Pieces: BOX {"foot", "z0", "z1", "style" (WorldShader), "ramp", "variant", "roof" (ramp or -1),
#   "rim", "top" (a building's main roof), "spire" (px), "flag"}; HIP (a pyramid
#   roof: "foot" (4 corners), "z0", "z1", "rh", "ramp", "roof"); BRIDGE, LAWN, POOL, SOLAR, PAD lie
#   on "foot" at "z1" (BRIDGE spans z0..z1; a LAWN with "deck" is a paved terrace with a planted
#   rim); TREE "at" + "z"; SIGN "a", "b", "z", "tint";
#   ANTENNA "at", "z", "len".

enum { CLUSTER, BRIDGES, MEGA, RING, PERIMETER, ZIGGURAT, SLIM_WIDE, DECO, OFFICES, HOTEL,
	CORNER, LSLAB, PYRAMID }
# every lot picks its own archetype; tools may force one
const MIX := -1
const NAMES: Array[String] = ["RACIMO", "PUENTES", "MEGABLOQUE", "ANILLO", "MANZANA",
	"ZIGURAT", "TORRE Y BLOQUE", "ART DECO", "OFICINAS", "HOTEL", "ESQUINA", "BLOQUE EN L",
	"PLAZA"]
# how often each archetype comes up: the ones that keep lower buildings round the tall one more
const WEIGHT: Array[float] = [1.0, 1.0, 0.8, 0.8, 2.0, 1.0, 1.6, 1.2, 1.4, 0.9, 1.6, 1.2, 1.0]

enum { BOX, HIP, BRIDGE, TREE, PAD, LAWN, POOL, SOLAR, SIGN, ANTENNA }
# facade kinds a building wears (a material is one of them with its ramps)
enum { M_GLASS, M_FRAME, M_RIBBON, M_GRID, M_APT, M_OFFICE }
# how a tower ends
enum { C_FLAT, C_SETBACK, C_GOLD, C_STEPS, C_PYRAMID, C_PAD, C_ANTENNA, C_SPIRE }

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
# the lower buildings round the tall ones (px): mid-rise by tier, and low pavilions
const MID_Z := {4: Vector2(16.0, 28.0), 5: Vector2(22.0, 36.0)}
const LOW_Z := Vector2(9.0, 13.0)
# green in the open paving (Oscar: no sandy wasteland): open ground under this many m2 stays paved;
# bigger is cut into planted squares (side in m, by lot) with cement paths between them, or for
# some lots one lawn, a small park
const GREEN_MIN := 140.0
const GREEN_CELL := Vector2(9.0, 14.0)
const GREEN_PATH := 2.6
const GREEN_PARK := 0.25

# a lot's materials: the tall element, a second kind for the others, the lower buildings, the
# trim (bands, crowns) and the flat roofs. A material is [kind, ramp, glass / window variant].
const SCHEMES: Array[Dictionary] = [
	{"tall": [M_GLASS, "GLS"], "alt": [M_FRAME, "CON", 0], "mid": [M_RIBBON, "CON", 0],
		"trim": "GLD", "roof": "CON"},
	{"tall": [M_GLASS, "TEAL"], "alt": [M_RIBBON, "STN", 1], "mid": [M_GRID, "STN", 2],
		"trim": "CON", "roof": "STN"},
	{"tall": [M_GLASS, "GRN"], "alt": [M_RIBBON, "CRM", 0], "mid": [M_APT, "CRM"],
		"trim": "CRM", "roof": "CRM"},
	{"tall": [M_GLASS, "BRZ"], "alt": [M_GRID, "OCH", 1], "mid": [M_GRID, "TER", 0],
		"trim": "GLD", "roof": "OCH"},
	{"tall": [M_GLASS, "STL"], "alt": [M_RIBBON, "STL", 2], "mid": [M_RIBBON, "CON", 2],
		"trim": "CYN", "roof": "STL"},
	{"tall": [M_FRAME, "CON", 1], "alt": [M_GLASS, "CYN"], "mid": [M_GRID, "CON", 2],
		"trim": "CON", "roof": "CON"},
	{"tall": [M_GRID, "TER", 0], "alt": [M_GRID, "SAL", 2], "mid": [M_APT, "SAL"],
		"trim": "CRM", "roof": "TER"},
	{"tall": [M_GRID, "STN", 3], "alt": [M_OFFICE, "STN"], "mid": [M_GRID, "CRM", 0],
		"trim": "GLD", "roof": "STN"},
	{"tall": [M_RIBBON, "CRM", 1], "alt": [M_GLASS, "TEAL"], "mid": [M_APT, "OCH"],
		"trim": "TEAL", "roof": "CRM"},
	{"tall": [M_GLASS, "CYN"], "alt": [M_FRAME, "STN", 1], "mid": [M_RIBBON, "STN", 1],
		"trim": "CON", "roof": "CON"},
	{"tall": [M_FRAME, "CRM", 3], "alt": [M_GLASS, "BRZ"], "mid": [M_GRID, "OCH", 0],
		"trim": "GLD", "roof": "CRM"},
	{"tall": [M_GRID, "CON", 3], "alt": [M_GLASS, "GLS"], "mid": [M_APT, "STN"],
		"trim": "STL", "roof": "CON"},
]
# apartment facades the lower buildings may take instead of the scheme's own
const APT_FACADES: Array[String] = ["CRM", "OCH", "SAL", "STN"]


# the highest pixel any variant of this tier can reach, for pops and the drawing's headroom
static func top(tier: int, levels: int) -> float:
	if tier == 4:
		return PODIUM_Z + tower_z(levels + 3) + TOWER_SETBACK + 6.0
	return sky_z(levels) + SPIRE + 3.0


static func tower_z(levels: int) -> float:
	return floorf(lerpf(TOWER_Z.x, TOWER_Z.y, clampf((levels - 6) / 12.0, 0.0, 1.0)))


static func sky_z(levels: int) -> float:
	return floorf(lerpf(SKY_Z.x, SKY_Z.y, clampf((levels - 20) / 15.0, 0.0, 1.0)))


# the archetype a lot gets: by hash, weighted, corner lots more often a corner landmark
static func archetype(id: String, tier: int, area: float, corner: bool) -> int:
	var w: Array[float] = WEIGHT.duplicate()
	if corner:
		w[CORNER] *= 2.5
	else:
		w[CORNER] = 0.0
	if area < 2600.0:
		for k in [RING, MEGA, PERIMETER, LSLAB]:
			w[k] *= 0.4
	var sum := 0.0
	for x: float in w:
		sum += x
	var pick := Iso.h01(id + "arch%d" % tier) * sum
	for k in w.size():
		pick -= w[k]
		if pick < 0.0:
			return k
	return CLUSTER


static func plan(tier: int, poly: PackedVector2Array, levels: int, id: String,
		fronts: PackedInt32Array = PackedInt32Array(), corner: bool = false,
		style: int = MIX) -> Dictionary:
	var out := {"groups": [], "built": [] as Array[PackedVector2Array], "ground": [],
		"works": [], "top": Iso.centroid(poly), "top_z": 0.0, "base": "PAVE_L", "trees": 120.0,
		"kind": style}
	var scheme := _scheme(id, tier)
	var lot := {"tier": tier, "poly": poly, "levels": levels, "id": id, "fronts": fronts,
		"corner": corner, "s": scheme, "cap": top(tier, levels)}
	var kind := style if style >= 0 else archetype(id, tier, Iso.area(poly), corner)
	# an archetype the lot has no room for hands over to another, in an order of its own
	var order: Array = range(NAMES.size())
	order.erase(kind)
	order.sort_custom(func(p: int, q: int) -> bool:
		return Iso.h01(id + "fb%d" % p) < Iso.h01(id + "fb%d" % q))
	order.push_front(kind)
	for a: int in order:
		if a == CORNER and not corner:
			continue
		out["kind"] = a
		_build(a, out, lot)
		if not (out["groups"] as Array).is_empty():
			break
		_reset(out)
	if (out["groups"] as Array).is_empty():
		# nothing fits (a thin lot): one plain tower in the middle
		_one_tower(out, lot)
	if not int(out["kind"]) in [PERIMETER, LSLAB, CORNER]:
		_fill(out, lot)
	_greens(out, lot)
	return out


static func _reset(out: Dictionary) -> void:
	out["groups"] = []
	out["built"] = [] as Array[PackedVector2Array]
	out["ground"] = []
	out["works"] = []
	out["top_z"] = 0.0
	out["base"] = "PAVE_L"
	out["trees"] = 120.0


static func _build(a: int, out: Dictionary, lot: Dictionary) -> void:
	match a:
		CLUSTER:
			_cluster(out, lot)
		BRIDGES:
			_bridges(out, lot)
		MEGA:
			_mega(out, lot)
		RING:
			_ring(out, lot)
		PERIMETER:
			_perimeter(out, lot)
		ZIGGURAT:
			_ziggurat(out, lot)
		SLIM_WIDE:
			_slim_wide(out, lot)
		DECO:
			_deco(out, lot)
		OFFICES:
			_offices(out, lot)
		HOTEL:
			_hotel(out, lot)
		CORNER:
			_corner(out, lot)
		LSLAB:
			_lslab(out, lot)
		PYRAMID:
			_pyramid(out, lot)


# --- materials -----------------------------------------------------------------------------------

static func _scheme(id: String, tier: int) -> Dictionary:
	var s: Dictionary = SCHEMES[int(Iso.h01(id + "scheme%d" % tier) * SCHEMES.size())]
	var roof := Pal.ramp_of(s["roof"])
	var out := {"tall": _mat(s["tall"], roof), "alt": _mat(s["alt"], roof),
		"mid": _mat(s["mid"], roof), "trim": Pal.ramp_of(s["trim"]), "roof": roof}
	# rascacielos lean to gold: half the schemes without it still crown their tallest in gold
	out["gold"] = s["trim"] == "GLD" or tier == 5 and Iso.h01(id + "gold") < 0.5
	return out


static func _mat(spec: Array, roof: int) -> Dictionary:
	return {"k": spec[0], "ramp": Pal.ramp_of(spec[1]), "sel": spec[2] if spec.size() > 2 else 0,
		"roof": roof}


# an apartment facade for one of the lower buildings, by hash
static func _apt(key: String, roof: int) -> Dictionary:
	return _mat([M_APT, APT_FACADES[int(Iso.h01(key + "af") * APT_FACADES.size())]], roof)


# one block of a building: walls in a material from z0 to z1 (px), a flat roof
static func _box(foot: PackedVector2Array, z0: float, z1: float, m: Dictionary,
		lobby: bool = true, crown: int = 0) -> Dictionary:
	var style := WorldShader.STYLE_PLAIN
	var variant := 0
	match int(m["k"]):
		M_GLASS:
			style = WorldShader.STYLE_SKY
			variant = (1 if lobby else 0) | (crown << 1)
		M_FRAME:
			style = WorldShader.STYLE_TOWER
			variant = (0 if lobby else 1) | (int(m["sel"]) << 1)
		M_RIBBON:
			style = WorldShader.STYLE_RIBBON
			variant = (1 if lobby else 0) | (int(m["sel"]) << 1)
		M_GRID:
			style = WorldShader.STYLE_GRID
			variant = (1 if lobby else 0) | (int(m["sel"]) << 1)
		M_APT:
			style = WorldShader.STYLE_APT
		M_OFFICE:
			style = WorldShader.STYLE_OFFICE
	return {"look": BOX, "foot": foot, "z0": z0, "z1": z1, "style": style, "ramp": m["ramp"],
		"variant": variant, "roof": m["roof"], "rim": true}


# a plain band (trim) round a footprint, h px from z
static func _band(foot: PackedVector2Array, z: float, h: float, ramp: int) -> Dictionary:
	return {"look": BOX, "foot": foot, "z0": z, "z1": z + h, "style": WorldShader.STYLE_PLAIN,
		"ramp": ramp, "variant": 0, "roof": -1, "rim": false}


# --- towers --------------------------------------------------------------------------------------

# a tower from z0 to top in material m, ending as `crown` says; its roof props by hash. The last
# roofed block is its main roof (teal when owned, the flag). `tallest` adds the spire or mast a
# rascacielos' crown wears.
static func _tower(foot: PackedVector2Array, z0: float, top: float, m: Dictionary, crown: int,
		lot: Dictionary, key: String, tallest: bool = false) -> Array:
	var s: Dictionary = lot["s"]
	var trim: int = Pal.ramp_of("GLD") if s["gold"] and tallest else s["trim"]
	var pieces: Array = []
	var h := top - z0
	var main := {}
	if h < 14.0:
		crown = C_FLAT
	match crown:
		C_GOLD, C_SETBACK, C_SPIRE:
			var cf := Iso.offset(foot, -1.3)
			if cf.size() < 3 or Iso.area(cf) < 10.0:
				main = _box(foot, z0, top, m)
				pieces.append(main)
			elif crown == C_GOLD and int(m["k"]) == M_GLASS:
				pieces.append(_box(foot, z0, top - CROWN, m, true, 1))
				main = _box(cf, top - CROWN, top, m, false, 2)
				# a steel roof behind the gold crown: a glass one read as a bright blue lid
				main["roof"] = Pal.ramp_of("STL")
				pieces.append(main)
			else:
				var sb := 6.0 if crown != C_SETBACK else 5.0
				pieces.append(_box(foot, z0, top - sb, m))
				pieces.append(_band(foot, top - sb, 2.0, trim if crown != C_SETBACK
					else s["trim"]))
				main = _box(cf, top - sb + 2.0, top, m, false)
				pieces.append(main)
			if lot["tier"] == 5 and (crown == C_SPIRE or tallest and crown == C_GOLD):
				main["spire"] = SPIRE
		C_STEPS:
			var f1 := Iso.offset(foot, -1.4)
			var f2 := Iso.offset(f1, -1.4)
			if f2.size() < 3 or Iso.area(f2) < 10.0:
				main = _box(foot, z0, top, m)
				pieces.append(main)
			else:
				var a := floorf(z0 + h * 0.62)
				var b := floorf(z0 + h * 0.84)
				pieces.append(_box(foot, z0, a, m))
				pieces.append(_band(f1, a, 1.0, trim))
				pieces.append(_box(f1, a + 1.0, b, m, false))
				pieces.append(_band(f2, b, 1.0, trim))
				main = _box(f2, b + 1.0, top, m, false)
				pieces.append(main)
				if tallest and lot["tier"] == 5:
					main["spire"] = SPIRE
		C_PYRAMID:
			var rh := 8.0 if lot["tier"] == 5 else 6.0
			var rect := Iso.min_rect(foot)
			if rect.size() < 4 or not _squareish(rect):
				main = _box(foot, z0, top, m)
				pieces.append(main)
			else:
				main = _box(rect, z0, top - rh, m)
				pieces.append(main)
				var roof: int = trim if lot["tier"] == 5 else s["trim"]
				if roof == Pal.ramp_of("CON") or roof == Pal.ramp_of("STL"):
					roof = Pal.ramp_of("TER")
				pieces.append({"look": HIP, "foot": rect, "z0": top - rh - 1.0,
					"z1": top - rh, "rh": rh, "ramp": m["ramp"], "roof": roof})
				if tallest:
					main["spire_at"] = top
		_:
			main = _box(foot, z0, top, m)
			pieces.append(main)
	main["top"] = true
	main["flag"] = true
	var z: float = main["z1"]
	var roof: PackedVector2Array = main["foot"]
	if crown == C_PYRAMID and main.has("spire_at"):
		pieces.append({"look": ANTENNA, "at": Iso.centroid(roof), "z": main["spire_at"],
			"len": SPIRE - 1})
	elif crown == C_PAD and not _pad_fits(roof):
		crown = C_ANTENNA
	if crown == C_PAD:
		pieces.append({"look": PAD, "foot": roof, "z1": z})
	elif crown in [C_FLAT, C_ANTENNA, C_PAD, C_SETBACK]:
		var room: float = lot["cap"] - z
		pieces.append_array(_props(roof, z, key, room, crown == C_ANTENNA))
	if crown == C_ANTENNA:
		var len := clampf(lot["cap"] - z - 2.0, 3.0, 8.0)
		var far := _far_corner(Iso.offset(roof, -1.0) if Iso.offset(roof, -1.0).size() >= 3
			else roof)
		pieces.append({"look": ANTENNA, "at": far, "z": z, "len": len})
	return pieces


static func _squareish(rect: PackedVector2Array) -> bool:
	var a := rect[0].distance_to(rect[1])
	var b := rect[1].distance_to(rect[2])
	return minf(a, b) >= 6.0 and maxf(a, b) <= minf(a, b) * 1.6


static func _pad_fits(roof: PackedVector2Array) -> bool:
	var c := Iso.centroid(roof)
	return Iso.contains(roof, Iso.square(c, 3.6))


# a crown for the tallest element: rascacielos always wear one that reads as premium
static func _crown(lot: Dictionary, m: Dictionary, key: String, tallest: bool) -> int:
	var r := Iso.h01(key + "crown")
	if lot["tier"] == 5 and tallest:
		if int(m["k"]) == M_GLASS:
			return [C_GOLD, C_SPIRE, C_PAD, C_STEPS, C_ANTENNA][int(r * 5.0)]
		return [C_SPIRE, C_STEPS, C_PAD, C_ANTENNA][int(r * 4.0)]
	return [C_FLAT, C_FLAT, C_SETBACK, C_ANTENNA, C_STEPS, C_PAD][int(r * 6.0)]


# --- roof props ----------------------------------------------------------------------------------

# what stands on a flat roof: AC units, water tanks, a stairwell hut, solar panels, a rooftop
# sign or a roof garden, by hash; never higher than `room` px
static func _props(roof: PackedVector2Array, z: float, key: String, room: float,
		few: bool = false) -> Array:
	var gi := Iso.offset(roof, -1.4)
	if gi.size() < 3 or room < 3.0:
		return []
	var area := Iso.area(gi)
	var r := Iso.h01(key + "props")
	var out: Array = []
	if area > 90.0 and not few and r < 0.18:
		# a roof garden
		var lawn := Iso.offset(roof, -1.0)
		out.append({"look": LAWN, "foot": lawn, "z1": z})
		var c := Iso.centroid(gi)
		var spread := sqrt(area) * 0.3
		for k in 3:
			var q := c + Vector2(Iso.h01(key + "gx%d" % k) - 0.5,
				Iso.h01(key + "gy%d" % k) - 0.5) * spread * 2.0
			if Geometry2D.is_point_in_polygon(q, Iso.offset(gi, -0.8)):
				out.append({"look": TREE, "at": q, "z": z})
		return _by_depth(out)
	if area > 120.0 and not few and r < 0.32:
		out.append({"look": SOLAR, "foot": gi, "z1": z})
	var c := Iso.centroid(gi)
	var want := 2 + int(Iso.h01(key + "np") * 3.0) - (1 if few else 0)
	var placed: Array = []
	var con := Pal.ramp_of("CON")
	for k in want * 4:
		if placed.size() >= want:
			break
		var kind := int(Iso.h01(key + "pk%d" % k) * 3.0)
		var half: float = [0.7, 0.9, 1.3][kind]
		var at := c + Vector2(Iso.h01(key + "px%d" % k) - 0.5,
			Iso.h01(key + "py%d" % k) - 0.5) * sqrt(area) * 0.85
		var bx := Iso.square(at, half)
		if not Iso.contains(gi, bx):
			continue
		var clear := true
		for p: Array in placed:
			var o: Vector2 = p[0]
			if absf(o.x - at.x) < half + float(p[1]) + 0.5 and absf(o.y - at.y) < half \
					+ float(p[1]) + 0.5:
				clear = false
		if not clear:
			continue
		placed.append([at, half])
		var h := minf([2.0, 4.0, 4.0][kind], room)
		var ramp: int = [con, Pal.ramp_of("STN"), Pal.ramp_of("CRM")][kind]
		out.append({"look": BOX, "foot": bx, "z0": z, "z1": z + h,
			"style": WorldShader.STYLE_PLAIN, "ramp": ramp, "variant": 0,
			"roof": ramp if kind != 1 else Pal.ramp_of("STL"), "rim": false})
	if not few and r > 0.8 and room >= 7.0:
		var sign := _sign(roof, z, key)
		if not sign.is_empty():
			out.append(sign)
	return _by_depth(out)


# a rooftop billboard on the roof's lit long side, set in a little
static func _sign(roof: PackedVector2Array, z: float, key: String) -> Dictionary:
	var ring := Iso.clean(roof)
	var best := -1.0
	var pick := []
	var c := Iso.centroid(ring)
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var nrm := Vector2(-(b.y - a.y), -(b.x - a.x)).normalized()
		if nrm.x + nrm.y <= 0.2:
			continue
		var len := a.distance_to(b)
		if len > best:
			best = len
			pick = [a, b]
	if pick.is_empty() or best < 6.0:
		return {}
	var a: Vector2 = pick[0]
	var b: Vector2 = pick[1]
	var mid := (a + b) * 0.5
	var inward := (c - mid) * 0.45
	var half := (b - a) * 0.3
	return {"look": SIGN, "a": mid - half + inward, "b": mid + half + inward, "z": z,
		"tint": [0, 3, 2, 1][int(Iso.h01(key + "tint") * 4.0)], "at": mid + inward}


static func _by_depth(items: Array) -> Array:
	var keyed: Array = []
	for it: Dictionary in items:
		var at: Vector2 = it["at"] if it.has("at") else Iso.centroid(it["foot"])
		var flat: bool = it["look"] in [LAWN, SOLAR]
		# flat things first, then whatever stands on them far to near
		keyed.append([(-1.0e6 if flat else Iso.depth(at)), it])
	keyed.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	var out: Array = []
	for k: Array in keyed:
		out.append(k[1])
	return out


static func _far_corner(poly: PackedVector2Array) -> Vector2:
	var far := poly[0]
	for q in poly:
		if Iso.depth(q) < Iso.depth(far):
			far = q
	return far


# --- groups --------------------------------------------------------------------------------------

# one building or a group on a shared base: its masses (sorted far to near unless `keep`), its
# shadows, its works (every mass that is not the base of another) and the lot's top
static func _put(out: Dictionary, base: PackedVector2Array, masses: Array,
		keep: bool = false) -> void:
	if masses.is_empty():
		return
	if not keep and masses.size() > 1:
		var keyed: Array = []
		for k in masses.size():
			var m: Array = masses[k]
			var f: PackedVector2Array = m[0]["foot"] if m[0].has("foot") else base
			keyed.append([float(m[0].get("z0", 0.0)), Iso.depth(Iso.centroid(f)), k, m])
		keyed.sort_custom(func(p: Array, q: Array) -> bool:
			if p[0] != q[0]:
				return p[0] < q[0]
			return p[1] < q[1])
		masses = []
		for kk: Array in keyed:
			masses.append(kk[3])
	var top := 0.0
	var at := Iso.centroid(base)
	var shadows: Array = []
	var feet: Array = []
	for m: Array in masses:
		var mt := 0.0
		for p: Dictionary in m:
			mt = maxf(mt, float(p.get("z1", 0.0)) + (float(p.get("rh", 0.0))))
		if not m[0].has("foot") or m[0]["look"] != BOX and m[0]["look"] != HIP:
			continue
		var f: PackedVector2Array = m[0]["foot"]
		shadows.append([f, mt])
		feet.append([f, mt])
		if mt > top:
			top = mt
			at = Iso.centroid(f)
	for fe: Array in feet:
		var f: PackedVector2Array = fe[0]
		var base_of_other := false
		for o: Array in feet:
			if o != fe and Geometry2D.is_point_in_polygon(Iso.centroid(o[0]), f) \
					and Iso.area(o[0]) < Iso.area(f):
				base_of_other = true
		if not base_of_other:
			out["works"].append([f, fe[1]])
	out["groups"].append({"foot": base, "masses": masses, "shadows": shadows, "top": top})
	out["built"].append(base)
	if top > float(out["top_z"]):
		out["top_z"] = top
		out["top"] = at


# a tower standing alone: a group of one mass
static func _alone(out: Dictionary, foot: PackedVector2Array, pieces: Array) -> void:
	_put(out, foot, [pieces])


# the tallest a rascacielos' or torres' main element may be, and the lot's mid-rise heights
static func _peak(lot: Dictionary) -> float:
	if lot["tier"] == 5:
		return sky_z(lot["levels"])
	return tower_z(lot["levels"]) + floorf(Iso.h01(lot["id"] + "pk") * TOWER_SETBACK)


static func _mid_z(lot: Dictionary, key: String) -> float:
	var r: Vector2 = MID_Z[lot["tier"]]
	return floorf(lerpf(r.x, r.y, Iso.h01(key + "mz")))


# --- the old four, in the lot's materials ---------------------------------------------------------

# towers apart on a plaza, each its own object, heights stepping down toward the viewer
static func _cluster(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var area := Iso.area(poly)
	var tier: int = lot["tier"]
	var n := clampi(int(area / 1900.0), 1, 3) if tier == 4 else clampi(int(area / 1300.0) + 1, 3, 5)
	var half := clampf(sqrt(area) * (0.12 if tier == 4 else 0.085), 4.5, 8.5 if tier == 4 else 6.5)
	var at := spots(poly, n, half, id, 5.5)
	at.sort_custom(func(p: Vector2, q: Vector2) -> bool: return Iso.depth(p) < Iso.depth(q))
	var peak := _peak(lot)
	var s: Dictionary = lot["s"]
	for k in at.size():
		# each tower its own width, so the cluster is not a row of twins
		var hk := half * (1.0 - 0.18 * Iso.h01(id + "cw%d" % k))
		var foot := Iso.square(at[k], hk)
		var z := _stagger(peak, k, id)
		var m: Dictionary = s["tall"] if k % 2 == 0 else s["alt"]
		var key := "%s_c%d" % [id, k]
		_alone(out, foot, _tower(foot, 0.0, z, m, _crown(lot, m, key, k == 0), lot, key, k == 0))
	out["trees"] = 90.0
	out["base"] = ["PAVE", "PAVE_L", "GRASS"][int(Iso.h01(id + "cb") * 3.0)]


# 2-3 towers on one podium (a lawn on its roof); rascacielos joined by sky bridges
static func _bridges(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var area := Iso.area(poly)
	var n := 2 if tier == 4 or area < 4500.0 else 3
	var half := clampf(sqrt(area) * 0.09, 5.0, 8.0 if tier == 4 else 7.0)
	var at := spots(Iso.offset(poly, -3.0), n, half, id + "b", 6.0)
	if at.size() < 2:
		return
	var spread := Geo.bounds(PackedVector2Array(at)).size
	var axis := Vector2.RIGHT if spread.x >= spread.y else Vector2.UP
	at.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.dot(axis) < q.dot(axis))
	var feet: Array[PackedVector2Array] = []
	var corners := PackedVector2Array()
	for k in at.size():
		var hk := half * (1.0 - 0.15 * Iso.h01(id + "bw%d" % k))
		feet.append(Iso.square(at[k], hk))
		corners.append_array(Iso.square(at[k], half + 3.5))
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
	var peak := _peak(lot)
	for k in feet.size():
		var rank := absi(k * 2 - (feet.size() - 1))
		tops.append(pz + _stagger(peak - pz, rank, id + str(k)))
	var pm: Dictionary = s["mid"].duplicate()
	var podium := _box(base, 0.0, pz, pm)
	var masses: Array = [[podium]]
	var lawn := Iso.offset(base, -1.0)
	if lawn.size() >= 3:
		masses[0].append({"look": LAWN, "foot": lawn, "z1": pz,
			"deck": Iso.h01(id + "bd") < 0.5})
	var best := tops.find(tops.max())
	var items: Array = []
	for k in feet.size():
		var m: Dictionary = s["tall"] if k == best or k % 2 == 0 else s["alt"]
		var key := "%s_b%d" % [id, k]
		items.append([Iso.depth(Iso.centroid(feet[k])), _tower(feet[k], pz, tops[k], m,
			_crown(lot, m, key, k == best), lot, key, k == best)])
	if tier == 5:
		for k in feet.size() - 1:
			var a := Iso.centroid(feet[k])
			var b := Iso.centroid(feet[k + 1])
			var w := (b - a).normalized().orthogonal() * 1.4
			var span := PackedVector2Array([a + w, b + w, b - w, a - w])
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
					"foot": Iso.clean(between), "z0": z0, "z1": z0 + BRIDGE_H,
					"ramp": s["tall"]["ramp"] if int(s["tall"]["k"]) == M_GLASS
					else Pal.ramp_of("GLS")}]])
	items.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
	for it: Array in items:
		masses.append(it[1])
	_put(out, base, masses, true)
	out["trees"] = 100.0
	out["base"] = "PAVE" if Iso.h01(id + "bb") < 0.6 else "GRASS"


# one wide building stepping back in terraces toward the far corner, roof gardens with trees on
# the terraces, a tower in the tall material rising from the top terrace
static func _mega(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var s0 := _rect_in(poly, 3.0, 0.84)
	if s0.size() < 3 or Iso.area(s0) < 200.0:
		return
	var peak := _peak(lot)
	var zs: Array[float] = [floorf(peak * 0.24), floorf(peak * 0.4)]
	if tier == 4:
		zs.assign([floorf(peak * 0.36)])
	var steps: Array[PackedVector2Array] = [s0]
	for k in range(1, zs.size()):
		var prev := steps[k - 1]
		var cut := Iso.moved(Iso.offset(prev, -3.5), Vector2(-1.5, 1.5))
		var keep := Iso.offset(prev, -1.0)
		var next := PackedVector2Array()
		if cut.size() >= 3 and keep.size() >= 3:
			for part in Geo.clip(cut, keep):
				if next.size() < 3 or Iso.area(part) > Iso.area(next):
					next = Iso.clean(part)
		if next.size() < 3 or Iso.area(next) < 120.0:
			break
		steps.append(next)
	# the tower: a square on the top terrace, pushed toward its far corner
	var top_step := steps[steps.size() - 1]
	var room := Iso.offset(top_step, -1.5)
	if room.size() < 3:
		return
	var half := clampf(sqrt(Iso.area(top_step)) * 0.28, 5.0, 8.0)
	var c := Iso.centroid(room)
	var foot := PackedVector2Array()
	while half >= 4.5 and foot.is_empty():
		for k in range(8, -1, -1):
			var at := c + Vector2(-1.0, 1.0) * k
			if Iso.contains(room, Iso.square(at, half)):
				foot = Iso.square(at, half)
				break
		half -= 0.5
	if foot.is_empty():
		return
	var pieces: Array = []
	var z0 := 0.0
	for k in steps.size():
		var z1: float = zs[k]
		var m: Dictionary = s["mid"] if k == 0 else s["alt"]
		pieces.append(_box(steps[k], z0, z1, m, k == 0))
		var lawn := Iso.offset(steps[k], -1.1)
		if lawn.size() >= 3:
			# the wide base a paved terrace with a planted rim, the steps above lawns
			pieces.append({"look": LAWN, "foot": lawn, "z1": z1,
				"deck": k == 0 or Iso.area(lawn) > 350.0})
		var upper: PackedVector2Array = steps[k + 1] if k + 1 < steps.size() else foot
		pieces.append_array(_terrace_trees(steps[k], upper, z1, id + str(k)))
		z0 = z1
	var m: Dictionary = s["tall"]
	var key := id + "_mtop"
	pieces.append_array(_tower(foot, z0, peak, m, _crown(lot, m, key, true), lot, key, true))
	_put(out, s0, [pieces], true)
	out["base"] = "PAVE"


# trees on the near strip of a terrace the next step leaves free
static func _terrace_trees(lower: PackedVector2Array, upper: PackedVector2Array, z: float,
		key: String) -> Array:
	var out: Array = []
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
			if Geometry2D.is_point_in_polygon(q, Iso.offset(lower, -1.2)) \
					and Iso.h01(key + "rt%d_%d" % [i, j]) < 0.7:
				out.append({"look": TREE, "at": q, "z": z})
	out.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return Iso.depth(p["at"]) < Iso.depth(q["at"]))
	return out


# towers spread round a garden with a fountain, the far ones tallest
static func _ring(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var inner := Iso.offset(poly, -3.0)
	if inner.size() < 3:
		return
	var area := Iso.area(poly)
	var half := clampf(sqrt(area) * (0.09 if tier == 4 else 0.075), 4.5, 7.0 if tier == 4 else 6.0)
	var want := clampi(int(area / 1000.0), 4, 6)
	if tier == 4:
		want = 3 + int(Iso.h01(id + "r4") * 2.0)
	var picks: Array[Vector2] = []
	while half >= 4.0 and picks.size() < 3:
		var path := Iso.offset(inner, -half - 0.2)
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
	var peak := _peak(lot)
	for k in picks.size():
		var foot := Iso.square(picks[k], half)
		var m: Dictionary = [s["tall"], s["alt"], s["mid"]][k % 3]
		var z := _stagger(peak, k, id) if k < 2 else minf(_stagger(peak, k, id), _mid_z(lot,
			id + str(k)) + 8.0)
		var key := "%s_r%d" % [id, k]
		_alone(out, foot, _tower(foot, 0.0, z, m, _crown(lot, m, key, k == 0), lot, key, k == 0))
	var garden := Iso.offset(inner, -half * 2.0 - 2.5)
	if garden.size() >= 3 and Iso.area(garden) > 40.0:
		_garden(out, garden, id, true)
	out["trees"] = 140.0
	out["base"] = "PAVE"


# a garden: lawn with a lighter middle and maybe a fountain / pool in it
static func _garden(out: Dictionary, garden: PackedVector2Array, id: String,
		fountain: bool) -> void:
	out["ground"].append([garden, "GRASS"])
	var lawn := Iso.offset(garden, -0.8)
	if lawn.size() >= 3:
		out["ground"].append([lawn, "GRASS_L" if Iso.h01(id + "gl") < 0.4 else "GRASS"])
	if not fountain:
		return
	var mid := Iso.centroid(garden)
	if Iso.contains(garden, Iso.square(mid, 3.2)):
		var pool := Iso.square(mid, 2.4)
		out["ground"].append([pool, "CREAM"])
		out["ground"].append([Iso.offset(pool, -0.6), "CYAN_M"])
		out["ground"].append([Iso.offset(pool, -1.2), "CYAN"])
		out["built"].append(pool)


# the paving the plan leaves open (a rim along the lot's edges and paths round every building and
# garden kept), planted: squares on a grid square to the lot, each its own kind, about half to
# four fifths of them by lot, or one lawn for the whole piece; small pieces stay paved
static func _greens(out: Dictionary, lot: Dictionary) -> void:
	if out["base"] == "GRASS":
		return
	var id: String = lot["id"]
	var poly: PackedVector2Array = lot["poly"]
	var open: Array[PackedVector2Array] = [Iso.offset(poly, -2.0)]
	var cuts: Array[PackedVector2Array] = []
	for b: PackedVector2Array in out["built"]:
		cuts.append(Iso.offset(b, 2.2))
	for g: Array in out["ground"]:
		cuts.append(Iso.offset(g[0], 1.6))
	for t in cuts:
		if t.size() < 3:
			continue
		var tb := Geo.bounds(t)
		var next: Array[PackedVector2Array] = []
		for part in open:
			if part.size() < 3:
				continue
			if Geo.bounds(part).intersects(tb):
				next.append_array(Geo.cut_out(part, t))
			else:
				next.append(part)
		open = next
	var rect := Iso.min_rect(poly, 1.0)
	if rect.size() < 4:
		return
	var ax := (rect[1] - rect[0]).normalized()
	var ay := ax.orthogonal()
	var cell := lerpf(GREEN_CELL.x, GREEN_CELL.y, Iso.h01(id + "gc"))
	var share := 0.5 + 0.3 * Iso.h01(id + "gs")
	var park := Iso.h01(id + "gp") < GREEN_PARK
	var step := cell + GREEN_PATH
	for n in open.size():
		var part := Iso.clean(open[n])
		if part.size() < 3 or Iso.area(part) < GREEN_MIN:
			continue
		var key := "%s_gn%d" % [id, n]
		if park:
			_lawn(out, Iso.offset(part, -1.0), key, 3)
			continue
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for q in part:
			var t := Vector2(q.dot(ax), q.dot(ay))
			lo = lo.min(t)
			hi = hi.max(t)
		var nx := ceili((hi.x - lo.x + GREEN_PATH) / step)
		var ny := ceili((hi.y - lo.y + GREEN_PATH) / step)
		var o := (lo + hi) * 0.5 - Vector2(nx, ny) * step * 0.5 + Vector2.ONE * GREEN_PATH * 0.5
		var planted := 0
		for i in nx:
			for j in ny:
				var ck := "%s_%d_%d" % [key, i, j]
				if Iso.h01(ck) > share:
					continue
				var u := o.x + i * step
				var v := o.y + j * step
				var sq := PackedVector2Array([ax * u + ay * v, ax * (u + cell) + ay * v,
					ax * (u + cell) + ay * (v + cell), ax * u + ay * (v + cell)])
				for piece in Geo.clip(sq, part):
					piece = Iso.clean(piece)
					if piece.size() < 3 or Iso.area(piece) < 30.0 \
							or Iso.offset(piece, -1.2).size() < 3:
						continue
					_lawn(out, piece, ck, int(Iso.h01(ck + "k") * 3.0))
					planted += 1
		# a big piece the dice left bare gets one lawn anyway
		if planted == 0:
			_lawn(out, Iso.offset(part, -1.5), key, 3)


# one planted patch: 0 a lawn in a dark hedge, 1 a lawn with a bed of shrubs in the middle,
# 2 a light meadow in a hedge, 3 a park lawn with a lighter middle
static func _lawn(out: Dictionary, foot: PackedVector2Array, key: String, kind: int) -> void:
	if foot.size() < 3 or Iso.area(foot) < 20.0:
		return
	var rim: String = ["GRASS_DD", "GRASS_D", "GRASS_D", "GRASS_D"][kind]
	var fill: String = ["GRASS", "GRASS", "GRASS_L", "GRASS"][kind]
	out["ground"].append([foot, rim])
	var inner := Iso.offset(foot, -0.8)
	if inner.size() < 3:
		return
	out["ground"].append([inner, fill])
	if kind == 1 or kind == 3:
		var mid := Iso.offset(inner, -2.2 if kind == 1 else -3.5)
		if mid.size() >= 3 and Iso.area(mid) > 8.0:
			out["ground"].append([mid, "GRASS_D" if kind == 1 else "GRASS_L"])


# --- the new ones ---------------------------------------------------------------------------------

# a city block: mid-rise buildings of their own heights and materials along the streets (a gap
# or a low pavilion now and then), a garden courtyard behind them and the tall one rising out of
# it at the far side
static func _perimeter(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var depth := lerpf(12.0, 15.0, Iso.h01(id + "pd"))
	var sites := _street_sites(lot, depth, Vector2(14.0, 24.0))
	if sites.size() < 2:
		return
	var court := Iso.offset(poly, -(depth + 2.5))
	var tower_at := Vector2.INF
	var half := clampf(sqrt(Iso.area(poly)) * 0.08, 5.0, 7.0)
	if court.size() >= 3:
		for h in [half, half - 1.0, 4.5]:
			var c := spots(court, 1, h, id + "pt", 3.0, false, true)
			if not c.is_empty() and Iso.contains(Iso.offset(court, -0.5), Iso.square(c[0], h)):
				tower_at = c[0]
				half = h
				break
	var tall_site := -1
	if tower_at == Vector2.INF:
		# no room inside: the corner site (or the biggest) rises as the tower
		var best := -1.0
		for k in sites.size():
			var a := Iso.area(sites[k]["poly"]) * (2.0 if sites[k]["corner"] else 1.0)
			if a > best:
				best = a
				tall_site = k
	var gap := int(Iso.h01(id + "gap") * sites.size()) if sites.size() >= 4 else -1
	for k in sites.size():
		var site: PackedVector2Array = sites[k]["poly"]
		var key := "%s_p%d" % [id, k]
		if k == tall_site:
			var m: Dictionary = s["tall"]
			_alone(out, site, _tower(site, 0.0, _peak(lot), m, _crown(lot, m, key, true), lot,
				key, true))
			continue
		var foot := Iso.offset(site, -0.4)
		if foot.size() < 3 or Iso.area(foot) < 40.0:
			continue
		if k == gap:
			# a low pavilion (a café, shops) and the way into the courtyard
			var low := Iso.offset(foot, -2.0)
			if low.size() >= 3 and Iso.area(low) > 30.0:
				_alone(out, low, [_box(low, 0.0, LOW_Z.x, _mat([M_OFFICE, "CRM"],
					s["roof"]))] + _props(low, LOW_Z.x, key, 3.0, true))
			continue
		var z := _mid_z(lot, key) + (6.0 if sites[k]["corner"] else 0.0)
		var pick := Iso.h01(key + "pm")
		var m: Dictionary = s["mid"] if pick < 0.45 else (_apt(key, s["roof"]) if pick < 0.8
			else s["alt"])
		var pieces: Array = [_box(foot, 0.0, z, m)]
		pieces[0]["top"] = true
		pieces[0]["flag"] = k == 0
		pieces.append_array(_props(foot, z, key, lot["cap"] - z))
		_alone(out, foot, pieces)
	if tower_at != Vector2.INF:
		var foot := Iso.square(tower_at, half)
		var m: Dictionary = s["tall"]
		var key := id + "_pt"
		_alone(out, foot, _tower(foot, 0.0, _peak(lot), m, _crown(lot, m, key, true), lot, key,
			true))
	if court.size() >= 3:
		_garden(out, court, id, tower_at == Vector2.INF)
	out["base"] = "PAVE"
	out["trees"] = 70.0


# a stepped tower (a wedding cake): three or four tiers each set back, trim bands between, roof
# gardens on the terraces, a low pavilion on the plaza
static func _ziggurat(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var at := spots(poly, 1, clampf(sqrt(Iso.area(poly)) * 0.16, 7.0, 11.0), id + "z", 3.0, true)
	if at.is_empty():
		return
	var half := clampf(sqrt(Iso.area(poly)) * 0.16, 7.0, 11.0)
	while half > 5.0 and not Iso.contains(Iso.offset(poly, -3.0), Iso.square(at[0], half)):
		half -= 0.5
	var base := Iso.square(at[0], half)
	var peak := _peak(lot)
	var n := 4 if tier == 5 else 3
	var fr: Array[float] = [0.34, 0.6, 0.82, 1.0]
	if n == 3:
		fr = [0.45, 0.75, 1.0]
	var pieces: Array = []
	var z0 := 0.0
	var foot := base
	var trim: int = s["trim"]
	for k in n:
		var z1 := floorf(peak * fr[k])
		var m: Dictionary = s["tall"] if k >= n - 2 else s["alt"]
		if k == n - 1:
			var key := id + "_ztop"
			pieces.append_array(_tower(foot, z0, z1, m, _crown(lot, m, key, true), lot, key, true))
			break
		pieces.append(_box(foot, z0, z1, m, k == 0))
		var next := Iso.offset(foot, -2.0)
		if next.size() < 3 or Iso.area(next) < 30.0:
			pieces[pieces.size() - 1]["z1"] = peak
			pieces[pieces.size() - 1]["top"] = true
			break
		var lawn := Iso.offset(foot, -0.9)
		if lawn.size() >= 3 and k > 0:
			pieces.append({"look": LAWN, "foot": lawn, "z1": z1})
			pieces.append_array(_terrace_trees(foot, next, z1, id + "zt%d" % k))
		pieces.append(_band(next, z1, 1.0, trim))
		z0 = z1 + 1.0
		foot = next
	_put(out, base, [pieces], true)
	_pavilions(out, lot, [base], 1)
	out["trees"] = 80.0
	out["base"] = "PAVE" if Iso.h01(id + "zb") < 0.5 else "GRASS"


# a long mid-rise slab along the main street and a slim tall tower beside it
static func _slim_wide(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var slab := _front_slab(lot, lerpf(12.0, 15.0, Iso.h01(id + "sd")), 0.7)
	if slab.size() < 3:
		return
	var rest := _rest(poly, slab, 3.0)
	if rest.size() < 3:
		return
	var half := clampf(sqrt(Iso.area(poly)) * 0.07, 4.5, 6.0)
	var at := spots(rest, 1, half, id + "sw", 3.0, false, true)
	if at.is_empty():
		return
	var m: Dictionary = s["mid"] if Iso.h01(id + "swm") < 0.6 else s["alt"]
	var z := _mid_z(lot, id + "slab") + 4.0
	var pieces: Array = [_box(slab, 0.0, z, m)]
	pieces[0]["top"] = true
	pieces.append_array(_props(slab, z, id + "slab", lot["cap"] - z))
	_alone(out, slab, pieces)
	var foot := Iso.square(at[0], half)
	var tm: Dictionary = s["tall"]
	var key := id + "_sw"
	_alone(out, foot, _tower(foot, 0.0, _peak(lot), tm, _crown(lot, tm, key, true), lot, key,
		true))
	var garden := Iso.offset(rest, -1.5)
	if garden.size() >= 3 and Iso.area(garden) > 80.0:
		_garden(out, garden, id, false)
	out["base"] = "PAVE"
	out["trees"] = 75.0


# a podium of shops and a stone or concrete tower on it that steps back twice under bands of
# trim, a spire or a mast on top
static func _deco(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var podium := _rect_in(poly, 3.0, 0.78)
	if podium.size() < 3 or Iso.area(podium) < 200.0:
		return
	var pr := Iso.min_rect(podium)
	if pr.size() >= 4 and Iso.area(podium) > 900.0:
		var capped := AreaBuilder._cap_rect(pr, 38.0, 28.0)
		if Iso.contains(Iso.offset(poly, -2.0), capped):
			podium = Iso.clean(capped)
	var inset := Iso.offset(podium, -3.0)
	if inset.size() < 3:
		return
	var rect := Iso.min_rect(inset)
	if rect.size() < 4:
		return
	rect = AreaBuilder._cap_rect(rect, 22.0, 16.0)
	if not Iso.contains(inset, rect):
		return
	var pz := 10.0
	var m: Dictionary = s["tall"] if int(s["tall"]["k"]) != M_GLASS else s["alt"]
	if int(m["k"]) == M_GLASS or int(m["k"]) == M_OFFICE:
		m = _mat([M_GRID, "STN", 3], s["roof"])
	var pm := _mat([M_OFFICE, ["STN", "CRM", "OCH"][int(Iso.h01(id + "dp") * 3.0)]], s["roof"])
	var masses: Array = [[_box(podium, 0.0, pz, pm)]]
	var ring := Iso.offset(podium, -0.9)
	if ring.size() >= 3:
		masses[0].append({"look": LAWN, "foot": ring, "z1": pz,
			"deck": Iso.h01(id + "dl") < 0.6})
	var peak := _peak(lot)
	var key := id + "_deco"
	var crown := C_SPIRE if tier == 5 else (C_ANTENNA if Iso.h01(key) < 0.5 else C_SETBACK)
	var tower: Array = []
	var f1 := Iso.offset(rect, -2.0)
	var a := floorf(pz + (peak - pz) * 0.55)
	tower.append(_box(rect, pz, a, m, false))
	tower.append(_band(rect, a, 2.0, Pal.ramp_of("GLD") if s["gold"] else s["trim"]))
	if f1.size() >= 3 and Iso.area(f1) > 40.0:
		tower.append_array(_tower(f1, a + 2.0, peak, m, crown, lot, key, true))
	else:
		tower[0]["z1"] = peak
		tower[0]["top"] = true
	masses.append(tower)
	_put(out, podium, masses, true)
	out["base"] = "PAVE"
	out["trees"] = 110.0


# office slabs: a long one along the street and a second, taller one behind it, a plaza between;
# AC units, a rooftop sign; a rascacielos lot's back slab is the slab skyscraper with a helipad
static func _offices(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var front := _front_slab(lot, lerpf(11.0, 14.0, Iso.h01(id + "od")), 0.75)
	if front.size() < 3:
		return
	var rest := _rest(poly, front, 6.0)
	var back := PackedVector2Array()
	if rest.size() >= 3:
		var r := Iso.min_rect(Iso.offset(rest, -2.5), 1.0)
		if r.size() >= 4:
			back = AreaBuilder._cap_rect(r, 30.0, 12.0)
			if not Iso.contains(rest, back):
				back = PackedVector2Array()
	var mf: Dictionary = s["mid"] if int(s["mid"]["k"]) != M_APT else s["alt"]
	var zf := _mid_z(lot, id + "of")
	var pieces: Array = [_box(front, 0.0, zf, mf)]
	pieces[0]["top"] = true
	pieces.append_array(_props(front, zf, id + "of", lot["cap"] - zf))
	if back.size() < 3:
		return
	_alone(out, front, pieces)
	var mb: Dictionary = s["tall"]
	var key := id + "_ob"
	var crown := C_PAD if tier == 5 else C_ANTENNA
	_alone(out, back, _tower(back, 0.0, _peak(lot), mb, crown, lot, key, true))
	out["base"] = "PAVE"
	out["trees"] = 130.0


# a hotel: a low wide wing with a pool deck on its roof and a tower of balconies at one end
static func _hotel(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var wing := _front_slab(lot, lerpf(17.0, 21.0, Iso.h01(id + "hd")), 0.8, 50.0)
	if wing.size() < 3:
		return
	var rect := Iso.min_rect(wing, 1.0)
	if rect.size() < 4:
		return
	var long := rect[1] - rect[0]
	var short := rect[3] - rect[0]
	if long.length() < 26.0:
		return
	# the tower over the far end of the wing, the pool at the other
	var e0 := rect[0] + long * 0.04 + short * 0.15
	var tw := minf(long.length() * 0.38, 16.0)
	var td := short.length() * 0.7
	var tower := Iso.clean(PackedVector2Array([e0, e0 + long.normalized() * tw,
		e0 + long.normalized() * tw + short.normalized() * td, e0 + short.normalized() * td]))
	var e1 := rect[1] - long * 0.06 + short * 0.18
	var pw := minf(long.length() * 0.38, 14.0)
	var pd := short.length() * 0.55
	var pool := Iso.clean(PackedVector2Array([e1 - long.normalized() * pw, e1,
		e1 + short.normalized() * pd, e1 - long.normalized() * pw + short.normalized() * pd]))
	if Iso.depth(Iso.centroid(tower)) > Iso.depth(Iso.centroid(pool)):
		# the tower goes to whichever end is farther from the viewer
		var e2 := rect[1] - long.normalized() * tw - long * 0.04 + short * 0.15
		tower = Iso.clean(PackedVector2Array([e2, e2 + long.normalized() * tw,
			e2 + long.normalized() * tw + short.normalized() * td, e2 + short.normalized() * td]))
		var e3 := rect[0] + long * 0.06 + short * 0.18
		pool = Iso.clean(PackedVector2Array([e3, e3 + long.normalized() * pw,
			e3 + long.normalized() * pw + short.normalized() * pd, e3 + short.normalized() * pd]))
	if not Iso.contains(wing, tower) or not Iso.contains(wing, pool):
		return
	var wz := 10.0
	var wm := _mat([M_OFFICE, ["CRM", "STN", "SAL"][int(Iso.h01(id + "hw") * 3.0)]], s["roof"])
	var deck: Array = [_box(wing, 0.0, wz, wm)]
	var lawn := Iso.offset(wing, -1.0)
	if lawn.size() >= 3:
		deck.append({"look": LAWN, "foot": lawn, "z1": wz, "deck": true})
	deck.append({"look": POOL, "foot": pool, "z1": wz})
	var c := Iso.centroid(wing)
	# trees behind the tower go on the deck before it, the ones in front after it
	var near: Array = []
	for k in 5:
		var q := c + (Vector2(Iso.h01(id + "htx%d" % k), Iso.h01(id + "hty%d" % k)) - Vector2(0.5,
			0.5)) * Vector2(long.length(), short.length()).length() * 0.6
		if Geometry2D.is_point_in_polygon(q, Iso.offset(wing, -1.6)) \
				and not Geometry2D.is_point_in_polygon(q, Iso.offset(tower, 1.5)) \
				and not Geometry2D.is_point_in_polygon(q, Iso.offset(pool, 1.0)):
			var t := {"look": TREE, "at": q, "z": wz}
			if Iso.depth(q) < Iso.depth(Iso.centroid(tower)):
				deck.append(t)
			else:
				near.append(t)
	var m: Dictionary = s["tall"] if int(s["tall"]["k"]) == M_GRID else _mat([M_GRID,
		["CON", "CRM", "STN", "SAL"][int(Iso.h01(id + "ht") * 4.0)], 2], s["roof"])
	var key := id + "_hotel"
	var tp := _tower(tower, wz, _peak(lot), m, _crown(lot, m, key, true), lot, key, true)
	var masses: Array = [deck, tp]
	if not near.is_empty():
		masses.append(near)
	_put(out, wing, masses, true)
	out["built"].append(pool)
	out["base"] = "PAVE_L"
	out["trees"] = 90.0


# a corner lot's landmark: a chamfered tower right on the corner, lower wings along both streets
static func _corner(out: Dictionary, lot: Dictionary) -> void:
	if not lot["corner"]:
		return
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var ring := _ring_ccw(poly)
	var fronts := _fronts_of(lot, ring)
	# the convex corner between two street sides nearest the viewer
	var best := -INF
	var corner := Vector2.INF
	var bis := Vector2.ZERO
	var n := ring.size()
	for i in n:
		var prev := (i - 1 + n) % n
		if not (fronts.has(i) and fronts.has(prev)):
			continue
		var d0 := (ring[i] - ring[prev]).normalized()
		var d1 := (ring[(i + 1) % n] - ring[i]).normalized()
		if d0.dot(d1) > 0.7 or d0.cross(d1) <= 0.0:
			continue
		if Iso.depth(ring[i]) > best:
			best = Iso.depth(ring[i])
			corner = ring[i]
			bis = (d1 - d0).normalized()
	if corner == Vector2.INF:
		return
	var half := clampf(sqrt(Iso.area(poly)) * 0.1, 6.0, 8.5)
	var keep := Iso.offset(poly, -2.0)
	if keep.size() < 3:
		return
	# as close to the corner as the tower fits, a little in from both streets
	var at := Vector2.INF
	while half >= 5.0 and at == Vector2.INF:
		for extra in 8:
			var q := corner + bis * ((half + 2.5) * 1.42 + extra)
			if Iso.contains(keep, Iso.square(q, half)):
				at = q
				break
		if at == Vector2.INF:
			half -= 0.5
	if at == Vector2.INF:
		return
	var tower := _octagon(at, half)
	var sites := _street_sites(lot, lerpf(11.0, 13.0, Iso.h01(id + "cd")), Vector2(15.0, 26.0))
	var keep_off := Iso.offset(tower, 3.0)
	var k := 0
	for st: Dictionary in sites:
		for part in Geo.minus(Iso.offset(st["poly"], -0.4), keep_off):
			var foot := Iso.clean(part)
			if foot.size() < 3 or Iso.area(foot) < 60.0:
				continue
			var key := "%s_w%d" % [id, k]
			k += 1
			var z := _mid_z(lot, key) - 4.0
			var m: Dictionary = s["mid"] if k % 2 == 0 else _apt(key, s["roof"])
			var pieces: Array = [_box(foot, 0.0, z, m)]
			pieces[0]["top"] = true
			pieces.append_array(_props(foot, z, key, lot["cap"] - z))
			_alone(out, foot, pieces)
	var m: Dictionary = s["tall"]
	var key := id + "_corner"
	var crown := _crown(lot, m, key, true)
	if crown == C_PYRAMID:
		crown = C_GOLD if int(m["k"]) == M_GLASS else C_STEPS
	_alone(out, tower, _tower(tower, 0.0, _peak(lot), m, crown, lot, key, true))
	var court := Iso.offset(poly, -14.0)
	if court.size() >= 3 and Iso.area(court) > 60.0:
		_garden(out, court, id, false)
	out["base"] = "PAVE"
	out["trees"] = 90.0


# one continuous slab round the lot's streets (an L or a U, as many street sides as it has), its
# corner part rising higher, a pool and a garden in the courtyard
static func _lslab(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var tier: int = lot["tier"]
	var s: Dictionary = lot["s"]
	var depth := lerpf(12.0, 14.0, Iso.h01(id + "ld"))
	var sites := _street_sites(lot, depth, Vector2(26.0, 40.0))
	if sites.size() < 2:
		return
	var m: Dictionary = s["mid"] if Iso.h01(id + "lm") < 0.5 else s["alt"]
	if int(m["k"]) == M_GLASS:
		m = s["mid"]
	var z := _mid_z(lot, id + "lz") + 4.0
	var tallest := -1
	var best := -1.0
	for k in sites.size():
		var a := Iso.area(sites[k]["poly"]) * (3.0 if sites[k]["corner"] else 1.0)
		if a > best:
			best = a
			tallest = k
	for k in sites.size():
		var foot := Iso.offset(sites[k]["poly"], -0.3)
		if foot.size() < 3 or Iso.area(foot) < 50.0:
			continue
		var key := "%s_l%d" % [id, k]
		if k == tallest:
			var top := _peak(lot) if tier == 5 else z + 10.0
			var crown := C_STEPS if tier == 5 else C_SETBACK
			_alone(out, foot, _tower(foot, 0.0, top, m, crown, lot, key, true))
			continue
		# the slab steps a storey or two up and down along the street
		var zk := z + floorf((Iso.h01(key + "step") - 0.5) * 12.0)
		var mk: Dictionary = m if Iso.h01(key + "alt") < 0.7 else s["alt"]
		if int(mk["k"]) == M_GLASS:
			mk = m
		var pieces: Array = [_box(foot, 0.0, zk, mk)]
		pieces[0]["top"] = true
		pieces.append_array(_props(foot, zk, key, lot["cap"] - zk))
		_alone(out, foot, pieces)
	var court := Iso.offset(poly, -(depth + 2.5))
	if court.size() >= 3 and Iso.area(court) > 60.0:
		_garden(out, court, id, false)
		var r := Iso.min_rect(Iso.offset(court, -3.0), 0.7)
		if r.size() >= 4 and Iso.area(r) > 30.0:
			var pool := AreaBuilder._cap_rect(r, 16.0, 7.0)
			if Iso.contains(court, pool):
				out["ground"].append([pool, "CREAM"])
				out["ground"].append([Iso.offset(pool, -0.7), "CYAN_M"])
				out["ground"].append([Iso.offset(pool, -1.3), "CYAN"])
				out["built"].append(pool)
	out["base"] = "PAVE"
	out["trees"] = 70.0


# a tower on a plaza, a low pavilion or two beside it (once a pyramid-roofed tower)
static func _pyramid(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var half := clampf(sqrt(Iso.area(poly)) * 0.11, 6.0, 9.0)
	var at := spots(poly, 1, half, id + "py", 3.0, false, true)
	if at.is_empty():
		return
	while half > 5.0 and not Iso.contains(Iso.offset(poly, -3.0), Iso.square(at[0], half)):
		half -= 0.5
	var foot := Iso.square(at[0], half)
	var m: Dictionary = s["tall"]
	var key := id + "_pyr"
	# Oscar did not like the gold pyramid roofs: the tower wears an ordinary crown
	_alone(out, foot, _tower(foot, 0.0, _peak(lot), m, _crown(lot, m, key, true), lot, key,
		true))
	_pavilions(out, lot, [foot], 2)
	out["trees"] = 85.0
	out["base"] = "PAVE_L" if Iso.h01(id + "yb") < 0.5 else "PAVE"


# up to n low buildings (shops, a café, a gym) on the lot's open ground, apart from `keep`
static func _pavilions(out: Dictionary, lot: Dictionary, keep: Array, n: int) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var free := Iso.offset(poly, -2.0)
	for f: PackedVector2Array in keep:
		var parts := Geo.minus(free, Iso.offset(f, 4.0))
		free = PackedVector2Array()
		for p in parts:
			if free.size() < 3 or Iso.area(p) > Iso.area(free):
				free = p
		if free.size() < 3:
			return
	var at := spots(free, n, 5.0, id + "pv", 5.0)
	for k in at.size():
		var key := "%s_v%d" % [id, k]
		var foot := Iso.square(at[k], 4.0 + Iso.h01(key) * 1.5)
		if not Iso.contains(free, foot):
			continue
		var z := floorf(lerpf(LOW_Z.x, LOW_Z.y, Iso.h01(key + "z")))
		var m := _apt(key, s["roof"]) if Iso.h01(key + "m") < 0.5 else _mat([M_OFFICE,
			APT_FACADES[int(Iso.h01(key + "f") * 4.0)]], s["roof"])
		var pieces: Array = [_box(foot, 0.0, z, m)]
		pieces[0]["top"] = true
		pieces.append_array(_props(foot, z, key, 3.0, true))
		_alone(out, foot, pieces)


# the city fabric round the archetype: along the lot's streets, wherever nothing stands yet, lower
# buildings of their own heights and facades (some sites left open as plazas), so a grown district
# keeps the mid tiers' fine grain under its towers
static func _fill(out: Dictionary, lot: Dictionary) -> void:
	var id: String = lot["id"]
	var s: Dictionary = lot["s"]
	var taken: Array[PackedVector2Array] = []
	for b: PackedVector2Array in out["built"]:
		taken.append(Iso.offset(b, 3.0))
	for g: Array in out["ground"]:
		taken.append(Iso.offset(g[0], 1.0))
	var depth := lerpf(10.0, 13.0, Iso.h01(id + "fd"))
	var open := 0.25 + Iso.h01(id + "fo") * 0.25
	for st: Dictionary in _street_sites(lot, depth, Vector2(12.0, 20.0)):
		var parts: Array[PackedVector2Array] = [Iso.offset(st["poly"], -0.5)]
		for t in taken:
			var next: Array[PackedVector2Array] = []
			for part in parts:
				if part.size() < 3:
					continue
				if Geo.bounds(part).intersects(Geo.bounds(t)):
					next.append_array(Geo.minus(part, t))
				else:
					next.append(part)
			parts = next
		for part in parts:
			var foot := Iso.clean(part)
			if foot.size() < 3 or foot.size() > 8 or Iso.area(foot) < 70.0:
				continue
			var r := Iso.min_rect(foot)
			if r.size() < 4 or minf(r[0].distance_to(r[1]), r[1].distance_to(r[2])) < 6.0:
				continue
			var key := "%s_f%d" % [id, int(Iso.depth(Iso.centroid(foot)) * 10.0)]
			if Iso.h01(key + "open") < open:
				continue
			var low := Iso.h01(key + "low") < 0.35
			var z := floorf(lerpf(LOW_Z.x, LOW_Z.y, Iso.h01(key + "z"))) if low \
				else _mid_z(lot, key) - 4.0
			var pick := Iso.h01(key + "pm")
			var m: Dictionary = _apt(key, s["roof"]) if pick < 0.5 else (s["mid"] if pick < 0.8
				else s["alt"])
			if low and int(m["k"]) == M_GLASS:
				m = _apt(key, s["roof"])
			var pieces: Array = [_box(foot, 0.0, z, m)]
			pieces[0]["top"] = true
			pieces.append_array(_props(foot, z, key, minf(4.0, lot["cap"] - z), true))
			_alone(out, foot, pieces)
			taken.append(Iso.offset(foot, 0.6))


# nothing else fits: one plain tower in the middle
static func _one_tower(out: Dictionary, lot: Dictionary) -> void:
	var poly: PackedVector2Array = lot["poly"]
	var id: String = lot["id"]
	var at := spots(poly, 1, 5.0, id + "one", 3.0, true)
	var c: Vector2 = at[0] if not at.is_empty() else Iso.centroid(poly)
	var foot := Iso.square(c, 4.0 if at.is_empty() else 5.0)
	var m: Dictionary = lot["s"]["tall"]
	var key := id + "_one"
	out["kind"] = CLUSTER
	_alone(out, foot, _tower(foot, 0.0, _peak(lot), m, _crown(lot, m, key, true), lot, key, true))


# --- geometry helpers -----------------------------------------------------------------------------

static func _ring_ccw(poly: PackedVector2Array) -> PackedVector2Array:
	var ring := poly
	if Geo.area(ring) < 0.0:
		ring = ring.duplicate()
		ring.reverse()
	return ring


static func _fronts_of(lot: Dictionary, ring: PackedVector2Array) -> PackedInt32Array:
	var fronts: PackedInt32Array = lot["fronts"]
	if fronts.is_empty():
		fronts = PackedInt32Array()
		for i in ring.size():
			fronts.append(i)
	return fronts


# building sites along the lot's streets (Plotter.sites), drawing-clean, with their corner flag
static func _street_sites(lot: Dictionary, depth: float, front: Vector2) -> Array[Dictionary]:
	var ring := _ring_ccw(lot["poly"])
	var out: Array[Dictionary] = []
	for st in Plotter.sites(ring, _fronts_of(lot, ring), depth, front, lot["id"] + "sky"):
		var p := Iso.clean(st["poly"])
		if p.size() >= 3:
			out.append({"poly": p, "corner": st["corner"]})
	return out


# a slab along the lot's longest street side: `depth` deep, `share` of the side long, centred
static func _front_slab(lot: Dictionary, depth: float, share: float,
		cap: float = 44.0) -> PackedVector2Array:
	var ring := _ring_ccw(lot["poly"])
	var fronts := _fronts_of(lot, ring)
	var best := -1.0
	var side := -1
	for i in fronts:
		if i < 0 or i >= ring.size():
			continue
		var l := ring[i].distance_to(ring[(i + 1) % ring.size()])
		if l > best:
			best = l
			side = i
	if side < 0 or best < 20.0:
		return PackedVector2Array()
	var a := ring[side]
	var b := ring[(side + 1) % ring.size()]
	var t := (b - a).normalized()
	var nrm := Vector2(-t.y, t.x)
	var mid := (a + b) * 0.5 + nrm * 2.5
	var half := minf(best * share, cap) * 0.5
	var slab := PackedVector2Array([mid - t * half, mid + t * half, mid + t * half + nrm * depth,
		mid - t * half + nrm * depth])
	var keep := Iso.offset(lot["poly"], -1.5)
	if keep.size() < 3:
		return PackedVector2Array()
	var out := PackedVector2Array()
	for part in Geo.clip(slab, keep):
		if out.size() < 3 or Iso.area(part) > Iso.area(out):
			out = part
	if out.size() < 3 or Iso.area(out) < 120.0:
		return PackedVector2Array()
	return Iso.clean(out)


# the biggest part of the lot left once `taken` (grown by `gap`) is cut out
static func _rest(poly: PackedVector2Array, taken: PackedVector2Array,
		gap: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for part in Geo.minus(Iso.offset(poly, -1.0), Iso.offset(taken, gap)):
		if out.size() < 3 or Iso.area(part) > Iso.area(out):
			out = part
	return Iso.clean(out) if out.size() >= 3 else out


# a square with its corners cut off: the corner landmark's plan
static func _octagon(at: Vector2, half: float) -> PackedVector2Array:
	var c := half * 0.42
	return Iso.clean(PackedVector2Array([at + Vector2(-half + c, -half),
		at + Vector2(half - c, -half), at + Vector2(half, -half + c), at + Vector2(half, half - c),
		at + Vector2(half - c, half), at + Vector2(-half + c, half), at + Vector2(-half, half - c),
		at + Vector2(-half, -half + c)]))


# the k-th tower's roof, farthest first: the tallest steps down, each a little off by hash
static func _stagger(top: float, k: int, id: String) -> float:
	var f: float = STAGGER[mini(k, STAGGER.size() - 1)]
	if k > 0:
		f += (Iso.h01(id + "st%d" % k) - 0.5) * 0.06
	return floorf(top * f)


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
# picked by hash (the one nearest the middle when `central`, the farthest from the viewer when
# `far`); smaller when nothing fits
static func spots(poly: PackedVector2Array, n: int, half: float, seed: String, gap: float,
		central: bool = false, far: bool = false) -> Array[Vector2]:
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
		elif far:
			cand.sort_custom(func(p: Array, q: Array) -> bool:
				return Iso.depth(p[1]) + p[0] * 6.0 < Iso.depth(q[1]) + q[0] * 6.0)
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
