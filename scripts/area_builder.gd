class_name AreaBuilder
extends RefCounted

# Turns a baked office area (format v3) into what BlockView draws, as ops in low-res pixels:
#   ground  - palette indices for the ground pass (pavement, roads, parks, water, lots, marks)
#   shadows - the cast-shadow mask (white polygons)
#   pre     - drawn in colour over the ground before any object (the slab's earth cut, the ring)
#   objects - buildings, trees, cars, lamps, people: each with its ops, footprint hull and
#             screen box, put in painter's order by DepthSort and outlined in ink when drawn
#   post    - drawn last, over everything (price tags; `tags` false leaves them to the caller)
# What belongs to one lot (its ground ops in `lot_ground`, its shadows in `lot_shadows`, its
# objects tagged with its index) can be thrown away and laid out again by `rebuild_lot`, so the
# game can redraw a lot it bought or built on without redrawing the whole area. A lot whose
# plot has "works" (the tier being built) is drawn as a building site with scaffolding.
# Each lot ("terreno", the file's plots[]) is drawn as a little development of its tier, laid
# out here from the lot's own polygon, street sides, tier, levels, zone and owned flag, so a lot
# can be rebuilt at any tier without touching the file: 0 an empty fenced lot with a sale sign,
# 1 a row of houses with gardens, 2 bigger houses with pools, 3 apartment blocks around a
# courtyard, 4 one to three towers on a plaza, 5 a skyscraper on a podium; industrial lots get
# sheds in a yard. The building recipes are the mockup's (gen_battlegrounds.py build_tier,
# office, roof_props, car_obj...). Every object remembers its lot, for the pick pass.
# Street furniture (trees, lamps, cars, people) is placed from the blocks and roads with stable
# hashes, so the same area always looks the same.

const DISC_SIDES := 192
const SLAB_DEPTH := 14.0
const FACADES: Array[String] = ["CRM", "OCH", "SAL", "STN", "CRM", "OCH"]
# how many of the empty lots nearest the office get a price tag over their sale sign
const TAGS := 5
# placeholder asking price per square metre, until the game has an economy
const PRICE_M2 := 300.0
# a skyscraper's podium, in pixels
const PODIUM_Z := 11.0
const STREET_TREE_EVERY := 9.0
const LAMP_EVERY := 17.0
const DASH_CLEAR := 14.0
const CAR_EVERY := 38.0
const CAR_CHANCE := 0.45
const GREEN_KIND := {"pitch": "GRASS_L", "playground": "GRASS_L", "golf_course": "GRASS_L",
	"forest": "GRASS_D", "wood": "GRASS_D", "scrub": "GRASS_D", "heath": "GRASS_D",
	"cemetery": "GRASS_D", "sand": "DIRT_L", "beach": "DIRT_L"}
const DENSE_TREES := ["forest", "wood", "scrub", "park", "cemetery", "nature_reserve"]
# building sites along a lot's streets by tier: depth and frontage width ranges (m)
const SITE_DEPTH := [Vector2(0, 0), Vector2(13, 17), Vector2(21, 27), Vector2(14, 18)]
const SITE_FRONT := [Vector2(0, 0), Vector2(9, 12), Vector2(16, 22), Vector2(14, 24)]
const SHED_DEPTH := Vector2(22, 30)
const SHED_FRONT := Vector2(18, 30)
# garden and plaza trees: one per this many square metres
const GARDEN_TREE := 70.0
const PLAZA_TREE := 120.0
# the office building's largest footprint (m), long x short side
const OFFICE_SIZE := Vector2(17, 12)
# the office stands on a site at most this much farther from the clicked point than the nearest
const OFFICE_NEAR := 30.0

var iso: Iso
var radius := 0.0
var active := 0.0
var ground: Array = []
var shadows: Array = []
var pre: Array = []
var objects: Array = []
var post: Array = []
# per lot (the file's plots[] index): its ground ops, drawn after `ground`, and its shadows
var lot_ground: Array = []
var lot_shadows: Array = []
# price tags over the signed lots nearest the office; the game draws its own, live
var tags := true
# where income pops rise from: over the roofs of what the player owns
var pops: Array[Vector2] = []
# one entry per lot (index = the file's plots[] index): "data" (the plot), "poly" (ground
# metres), "screen" (its ground in drawing pixels), "box" (drawing pixels it and its buildings
# cover), "active" (inside the office's radius), "roof" (where its income pops rise, owned lots)
var lots: Array[Dictionary] = []
# the highest pixel any object reaches above its ground point, for the drawing's bounds
var tallest := 40.0

var _block: Dictionary
var _pt: Painter
var _junctions: Array[Dictionary] = []
var _for_sale: Array[Dictionary] = []
# the lot being built (its objects remember it) and whether its buildings are faded, -1 = none
var _lot_now := -1
var _lot_fade := -1
# screen boxes price tags and labels must keep clear of (the office's sign)
var keep_clear: Array[Rect2] = []


func _init(camera: Iso, block: Dictionary, active_radius: float) -> void:
	iso = camera
	_block = block
	radius = float(block["radius_m"])
	active = active_radius
	_pt = Painter.new(iso)


# --- everything, in order ------------------------------------------------------------------------

func build() -> void:
	_find_junctions()
	_ground_base()
	_ground_marks()
	_slab()
	var office: String = _block.get("office_plot", "")
	var has_office := false
	var plots: Array = _block["plots"]
	lot_ground.resize(plots.size())
	lot_shadows.resize(plots.size())
	for i in plots.size():
		var plot: Dictionary = plots[i]
		var poly := _pts(plot["poly"])
		var c := Iso.centroid(poly)
		lots.append({"data": plot, "poly": poly, "screen": iso.poly(poly),
			"active": active <= 0.0 or c.length() <= active})
		_lay_out(i)
		has_office = has_office or plot["id"] == office
	if not has_office:
		_kiosk()
	_trees()
	_street_furniture()
	_cars()
	if tags:
		_tags()
	_ring()
	_lot_boxes()


# one lot's ground, shadows and objects, recorded under its index
func _lay_out(i: int) -> void:
	var plot: Dictionary = lots[i]["data"]
	var poly: PackedVector2Array = lots[i]["poly"]
	lot_ground[i] = []
	lot_shadows[i] = []
	lots[i].erase("roof")
	_lot_now = i
	_lot_fade = 0 if lots[i]["active"] else 1
	if plot["id"] == _block.get("office_plot", ""):
		_develop_office(plot, poly)
	else:
		_develop(plot, poly)
	_lot_now = -1
	_lot_fade = -1


# throws away what lot i shows and lays it out again from its plot (bought, built, works
# started or done); its new objects go at the end of `objects`, so the caller re-sorts
func rebuild_lot(i: int) -> void:
	objects = objects.filter(func(o: Dictionary) -> bool: return o["lot"] != i)
	_lay_out(i)
	_lot_box(i)


# the top of the tallest thing in a lot of this tier, in pixels
static func top_of(tier: int, levels: int) -> float:
	match tier:
		1, 2:
			return 30.0
		3:
			return _apt_top(levels + 1) + 6.0
		4:
			return _tower_floors(levels + 3) * 3.0 + 7.0 + 7.0 + 12.0
		5:
			return PODIUM_Z + _sky_floors(levels) * 3.0 + 9.0 + 33.0 + 18.0
	return 16.0


static func _apt_top(levels: int) -> float:
	return 6.0 + (clampi(levels, 4, 9) - 1) * 4.0 + 2.0


static func _tower_floors(levels: int) -> int:
	return clampi(levels + 6, 14, 22)


static func _sky_floors(levels: int) -> int:
	return clampi(levels, 20, 35)


# --- ground --------------------------------------------------------------------------------------

# where ground ops go: the lot being laid out keeps its own
func _gsink() -> Array:
	return lot_ground[_lot_now] if _lot_now >= 0 else ground


func _g_poly(poly: PackedVector2Array, name: String) -> void:
	var pts := iso.poly(poly)
	if pts.size() >= 3 and not Geometry2D.triangulate_polygon(pts).is_empty():
		_gsink().append([Painter.OP_POLY, pts, Pal.i(name)])


func _g_dot(at: Vector2, name: String) -> void:
	_gsink().append([Painter.OP_RECT, Rect2(at, Vector2.ONE), Pal.i(name)])


func _g_line(a: Vector2, b: Vector2, name: String) -> void:
	var sink := _gsink()
	for r in Painter.line_runs(iso.pv(a), iso.pv(b)):
		sink.append([Painter.OP_RECT, r, Pal.i(name)])


func _ground_base() -> void:
	_g_poly(Geo.circle(radius, DISC_SIDES), "PAVE")
	for w: Dictionary in _block["water"]:
		_g_poly(_pts(w["poly"]), "CYAN_D")
	for l: Dictionary in _block["land"]:
		_g_poly(_pts(l["poly"]), "PAVE")
	for g: Dictionary in _block["greens"]:
		_g_poly(_pts(g["poly"]), GREEN_KIND.get(g["kind"], "GRASS"))
	# pedestrian streets are paved, the rest asphalt over them
	var roads: Array = _block["roads"]
	for pass_i in 2:
		for road: Dictionary in roads:
			var walk: bool = road["kind"] == "pedestrian"
			if walk != (pass_i == 0):
				continue
			_road_shape(road, float(road["width"]) * 0.5, "PAVE_L" if walk else "ASPH")
	_rails()
	for b: Dictionary in _block["blocks"]:
		_g_poly(_pts(b["poly"]), "PAVE")
	for c: Dictionary in _block["courts"]:
		_g_poly(_pts(c["poly"]), "GRASS")


func _road_shape(road: Dictionary, half: float, name: String) -> void:
	var line := _pts(road["line"])
	if line.size() < 2:
		return
	var parts := Geometry2D.offset_polyline(line, half, Geometry2D.JOIN_ROUND,
		Geometry2D.END_ROUND)
	var outer_cw := false
	var biggest := 0.0
	for part: PackedVector2Array in parts:
		var a := absf(Geo.area(part))
		if a > biggest:
			biggest = a
			outer_cw = Geometry2D.is_polygon_clockwise(part)
	var holes: Array[PackedVector2Array] = []
	for part: PackedVector2Array in parts:
		if Geometry2D.is_polygon_clockwise(part) != outer_cw:
			holes.append(part)
			continue
		for piece in _in_disc(part):
			_g_poly(piece, name)
	for hole in holes:
		_g_poly(hole, "PAVE")


# a gravel bed with sleepers and two rails; trams only the rails, set in the street
func _rails() -> void:
	for rail: Dictionary in _block["rails"]:
		var line := _pts(rail["line"])
		var tram: bool = rail["kind"] == "tram"
		if not tram:
			for part: PackedVector2Array in Geometry2D.offset_polyline(line, 2.6):
				for piece in _in_disc(part):
					_g_poly(piece, "PAVE_S")
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			var d := b - a
			var length := d.length()
			if length < 0.5:
				continue
			var side := d.normalized().orthogonal()
			if not tram:
				var s := 0.0
				while s < length:
					var c := a + d * (s / length)
					if c.length() < radius - 1.0:
						_g_line(c - side * 1.6, c + side * 1.6, "WOOD")
					s += 1.8
			for off: float in [-0.7, 0.7]:
				var p0 := a + side * off
				var p1 := b + side * off
				if p0.length() < radius - 1.0 and p1.length() < radius - 1.0:
					_g_line(p0, p1, "SL3")


# lane dashes down the streets and zebra crossings at the junctions
func _ground_marks() -> void:
	for road: Dictionary in _block["roads"]:
		var w := float(road["width"])
		if w < 10.0 or road["kind"] == "pedestrian":
			continue
		var line := _pts(road["line"])
		var lanes: Array[float] = [0.0]
		if w >= 18.0:
			lanes = [-w * 0.25, w * 0.25]
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			var length := a.distance_to(b)
			if length < 1.0:
				continue
			var step := (b - a) / length
			var side := step.orthogonal()
			var d := 2.0
			while d < length - 3.0:
				var p := a + step * d
				d += 7.0
				if p.length() > radius - 4.0 or _near_junction(p, DASH_CLEAR):
					continue
				for off in lanes:
					_g_line(p + side * off, p + step * 3.0 + side * off, "CREAM")
	for j in _junctions:
		var at: Vector2 = j["at"]
		if at.length() > radius - 8.0:
			continue
		var arms: Array = j["arms"]
		for arm: Dictionary in arms:
			if arm["walk"] or float(arm["width"]) < 8.0:
				continue
			var other := 0.0
			for o: Dictionary in arms:
				if o != arm and o["road"] != arm["road"]:
					other = maxf(other, float(o["width"]) * 0.5)
			if other <= 0.0:
				continue
			_zebra(at, arm["dir"], float(arm["width"]), other + 2.6)


func _zebra(at: Vector2, dir: Vector2, width: float, dist: float) -> void:
	var across := dir.orthogonal()
	var mid := at + dir * dist
	var k := -width * 0.5 + 1.2
	while k < width * 0.5 - 1.2:
		var q := PackedVector2Array([mid + across * k - dir * 1.6,
			mid + across * (k + 1.1) - dir * 1.6, mid + across * (k + 1.1) + dir * 1.6,
			mid + across * k + dir * 1.6])
		if mid.length() < radius - 4.0:
			_g_poly(Iso.clean(q), "CREAM")
		k += 2.4


# where two or more roads meet: points shared by road lines, with each road's arms out of it
func _find_junctions() -> void:
	var hits := {}
	var roads: Array = _block["roads"]
	for ri in roads.size():
		var line := _pts(roads[ri]["line"])
		for i in line.size():
			var key := Vector2i(roundi(line[i].x * 2.0), roundi(line[i].y * 2.0))
			if not hits.has(key):
				hits[key] = []
			hits[key].append([ri, i])
	for key: Vector2i in hits:
		var list: Array = hits[key]
		var arms: Array = []
		var at := Vector2(key) * 0.5
		for h: Array in list:
			var road: Dictionary = roads[h[0]]
			var line := _pts(road["line"])
			var i: int = h[1]
			for nb: int in [i - 1, i + 1]:
				if nb < 0 or nb >= line.size():
					continue
				var d := line[nb] - line[i]
				if d.length() < 12.0:
					continue
				arms.append({"road": h[0], "dir": d.normalized(), "width": road["width"],
					"walk": road["kind"] == "pedestrian"})
		if arms.size() >= 3:
			_junctions.append({"at": at, "arms": arms})


func _near_junction(p: Vector2, clear: float) -> bool:
	for j in _junctions:
		if (j["at"] as Vector2).distance_to(p) < clear:
			return true
	return false


# the earth cut under the disc's near half
func _slab() -> void:
	var edge := Iso.clean(Geo.circle(radius, DISC_SIDES))
	_pt.begin("slab")
	for i in edge.size():
		var a := edge[i]
		var b := edge[(i + 1) % edge.size()]
		var nrm := Vector2(-(b.y - a.y), -(b.x - a.x)).normalized()
		if nrm.x + nrm.y <= 0.0:
			continue
		var k := 1 if Iso.shade(Vector3(nrm.x, nrm.y, 0.0)) <= 1 else 3
		_pt.wall(a, b, -SLAB_DEPTH, 0.0, WorldShader.STYLE_SLAB, k, 0)
	pre.append_array(_pt.ops)


# the dashed gold ring on the edge of the active radius: ten metres on, five off
func _ring() -> void:
	if active <= 0.0:
		return
	var steps := ceili(TAU * active * Iso.S * 2.0)
	var seen := {}
	for k in steps:
		var a := TAU * k / steps
		var s := a * active
		if int(floorf(s / 5.0)) % 3 == 2:
			continue
		var q := iso.pi(cos(a) * active, sin(a) * active)
		if seen.has(q):
			continue
		seen[q] = true
		pre.append([Painter.OP_RECT, Rect2(q, Vector2.ONE), Pal.i("GOLD")])
		pre.append([Painter.OP_RECT, Rect2(q + Vector2(0, -1), Vector2.ONE), Pal.i("GOLD")])
		pre.append([Painter.OP_RECT, Rect2(q + Vector2(0, 1), Vector2.ONE), Pal.i("GOLD_D")])


# --- objects -------------------------------------------------------------------------------------

var _cur: Dictionary = {}


# starts recording an object standing on `foot` (ground metres)
func _object(key: String, foot: PackedVector2Array, outline: bool = true,
		shadow: bool = true) -> void:
	_cur = {"foot": foot, "outline": outline, "shadow": shadow, "h": 0.0, "lot": _lot_now}
	_cur["ops"] = _pt.begin(key)


# finishes the object: its screen box, hull, depth key, fade and shadow
func _close(h: float, shadow_foot: PackedVector2Array = PackedVector2Array()) -> void:
	var foot: PackedVector2Array = _cur["foot"]
	var c := Iso.centroid(foot)
	var uv := PackedVector2Array()
	for q in foot:
		uv.append(Vector2(q.x, -q.y))
	var hull := Geometry2D.convex_hull(uv)
	if hull.size() > 1:
		hull = hull.slice(0, -1)
	var box := _ops_box(_cur["ops"])
	if box.size == Vector2.ZERO:
		return
	_cur["hull"] = hull
	_cur["rect"] = box.grow(1.0)
	_cur["key"] = c.x - c.y
	_cur["fade"] = _lot_fade == 1 if _lot_fade >= 0 else active > 0.0 and c.length() > active + 2.0
	objects.append(_cur)
	if _cur["shadow"] and h > 0.0:
		_shadow(shadow_foot if shadow_foot.size() >= 3 else foot, minf(h, 40.0))


func _ops_box(ops: Array) -> Rect2:
	var box := Rect2()
	var first := true
	for op: Array in ops:
		var r := Rect2()
		match op[0]:
			Painter.OP_POLY:
				var pts: PackedVector2Array = op[1]
				r = Rect2(pts[0], Vector2.ZERO)
				for q in pts:
					r = r.expand(q)
			Painter.OP_WALL:
				var quad: PackedVector2Array = op[1]
				r = Rect2(quad[0], Vector2.ZERO)
				for q in quad:
					r = r.expand(q)
			Painter.OP_RECT:
				r = op[1]
			Painter.OP_TEX:
				var sp := Sprites.get_sprite(op[1])
				r = Rect2(op[2] + sp[1], sp[2])
		box = r if first else box.merge(r)
		first = false
	return box


# the mockup's cast shadow: the footprint, the footprint slid by the height and the walls between
func _shadow(foot: PackedVector2Array, h: float) -> void:
	var by := Vector2(0.33, 0.20) * h
	var ring := Iso.clean(foot)
	var sink: Array = lot_shadows[_lot_now] if _lot_now >= 0 else shadows
	sink.append(iso.poly(ring))
	sink.append(iso.poly(Iso.moved(ring, by)))
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var q := PackedVector2Array([a, b, b + by, a + by])
		if absf(Geo.area(q)) > 0.01:
			sink.append(iso.poly(Iso.clean(q)))


# --- buildings -----------------------------------------------------------------------------------

# a lot's development: ground, then its buildings on sites along its streets
func _develop(plot: Dictionary, poly: PackedVector2Array) -> void:
	var id: String = plot["id"]
	var tier := int(plot["built_tier"])
	var zone: String = plot["zone"]
	var owned: bool = plot.get("owned", false)
	var levels := int(plot.get("levels", 4))
	if plot.has("works"):
		_works(plot, poly, int(plot["works"]))
		return
	if tier <= 0:
		_lot(plot, poly)
		return
	if owned:
		_roof(iso.pv(Iso.centroid(poly), top_of(tier, levels)))
	if zone == "industrial" and tier <= 2:
		_g_poly(poly, "PAVE_S")
		for s: Dictionary in _sites(plot, poly, SHED_DEPTH, SHED_FRONT):
			_shed(s["id"], Iso.clean(s["poly"]), owned)
		return
	match tier:
		1, 2:
			_g_poly(poly, "GRASS")
			var built: Array[PackedVector2Array] = []
			for s: Dictionary in _sites(plot, poly, SITE_DEPTH[tier], SITE_FRONT[tier]):
				var site := Iso.clean(s["poly"])
				var hedge := Iso.offset(site, -0.6)
				for i in hedge.size():
					_g_line(hedge[i], hedge[(i + 1) % hedge.size()], "GRASS_DD")
				_house(s["id"], site, tier, _facade(s["id"]), owned)
				built.append(site)
			_scatter(poly, id + "g", GARDEN_TREE * 1.6, built)
		3:
			_g_poly(poly, "GRASS")
			var built := _apartments(plot, poly, owned, "")
			_scatter(poly, id + "g", GARDEN_TREE, built)
		4:
			_plaza(poly, id)
			var n := clampi(int(Iso.area(poly) / 1900.0), 1, 3)
			var half := clampf(sqrt(Iso.area(poly)) * 0.13, 6.0, 9.0)
			var built: Array[PackedVector2Array] = []
			var spots := _spots(poly, n, half, id)
			for k in spots.size():
				var foot := Iso.square(spots[k], half)
				var lv := levels + int(Iso.h01(id + "tl%d" % k) * 7.0) - 3
				_tower("%s_t%d" % [id, k], foot, lv, owned)
				built.append(foot)
			_scatter(poly, id + "p", PLAZA_TREE, built)
		_:
			_plaza(poly, id)
			var half := clampf(sqrt(Iso.area(poly)) * 0.18, 8.0, 13.0)
			var spots := _spots(poly, 1, half, id, true)
			var built: Array[PackedVector2Array] = []
			if not spots.is_empty():
				var foot := Iso.square(spots[0], half)
				var podium := _podium(poly, spots[0], half + 4.0)
				_sky(id, foot, levels, owned, podium)
				built.append(podium if podium.size() >= 3 else foot)
			_scatter(poly, id + "p", PLAZA_TREE, built)


# the player's office lot: apartment blocks round a courtyard (owned colours) and the modest
# office building on a site near the clicked point
func _develop_office(plot: Dictionary, poly: PackedVector2Array) -> void:
	_g_poly(poly, "GRASS")
	var built := _apartments(plot, poly, true, "office")
	_scatter(poly, plot["id"] + "g", GARDEN_TREE, built)


# --- building sites ------------------------------------------------------------------------------

# a lot being built up to tier `to`: bare earth inside a fence, each new building's footprint as
# the concrete floors already standing under a skeleton of the floors to come, scaffolding on the
# faces the camera sees (the mockup's construction), and a tower crane for blocks and taller
func _works(plot: Dictionary, poly: PackedVector2Array, to: int) -> void:
	var id: String = plot["id"]
	var zone: String = plot["zone"]
	var lv := BlockBaker.levels_for(id, to)
	_g_poly(poly, "DIRT")
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var m := int(a.distance_to(b) / 2.0)
		for j in m + 1:
			_g_dot(iso.pv(a.lerp(b, float(j) / maxi(1, m))), "WOOD")
	var feet: Array[PackedVector2Array] = []
	var goal := 0.0
	if zone == "industrial" and to <= 2:
		for st: Dictionary in _sites(plot, poly, SHED_DEPTH, SHED_FRONT):
			feet.append(Iso.offset(Iso.clean(st["poly"]), -1.0))
		goal = 13.0
	elif to <= 2:
		for st: Dictionary in _sites(plot, poly, SITE_DEPTH[to], SITE_FRONT[to]):
			var rect := Iso.min_rect(Iso.offset(Iso.clean(st["poly"]), -1.6), 0.8)
			if rect.size() >= 4:
				feet.append(_cap_rect(rect, 11.0 if to == 1 else 14.0, 8.0 if to == 1 else 10.0))
		goal = 11.0 if to == 1 else 16.0
	elif to == 3:
		for st: Dictionary in _sites(plot, poly, SITE_DEPTH[3], SITE_FRONT[3]):
			feet.append(Iso.offset(Iso.clean(st["poly"]), -0.8))
		goal = _apt_top(lv)
	elif to == 4:
		var n := clampi(int(Iso.area(poly) / 1900.0), 1, 3)
		var half := clampf(sqrt(Iso.area(poly)) * 0.13, 6.0, 9.0)
		for at in _spots(poly, n, half, id):
			feet.append(Iso.offset(Iso.square(at, half), -1.2))
		goal = 5.0 + _tower_floors(lv) * 3.0 + 2.0
	else:
		var half := clampf(sqrt(Iso.area(poly)) * 0.18, 8.0, 13.0)
		var spots := _spots(poly, 1, half, id, true)
		if not spots.is_empty():
			feet.append(Iso.offset(Iso.square(spots[0], half), -1.0))
		goal = PODIUM_Z + 6.0 + _sky_floors(lv) * 3.0 + 3.0
	var con := Pal.ramp_of("CON")
	var up := 0.0
	for k in feet.size():
		var foot := Iso.clean(feet[k])
		if foot.size() < 3 or Iso.area(foot) < 4.0:
			continue
		var h0 := floorf(goal * 0.35)
		var h1 := maxf(h0 + 4.0, floorf(goal * 0.7))
		_object("%s_w%d" % [id, k], foot)
		_pt.prism(foot, 0.0, h0, WorldShader.STYLE_PLAIN, con, con, false)
		_open_walls(foot, h0, h1, WorldShader.STYLE_SKELETON, 0.0)
		_open_walls(foot, 0.0, h1 - 2.0, WorldShader.STYLE_SCAFFOLD, 0.9)
		_close(h1)
		up = maxf(up, h1)
	var c := Iso.centroid(poly)
	if to >= 3 and up > 0.0:
		var far := poly[0]
		for q in poly:
			if Iso.depth(q) < Iso.depth(far):
				far = q
		_crane(id, c.lerp(far, 0.45), up)
	_roof(iso.pv(c, up + 6.0))
	tallest = maxf(tallest, up + 30.0)


# see-through walls (skeleton or scaffolding) on the faces the camera sees, `out` metres out from
# the footprint; no ink silhouette, it would fill the gaps
func _open_walls(foot: PackedVector2Array, z0: float, z1: float, style: int, out: float) -> void:
	for i in foot.size():
		var a := foot[i]
		var b := foot[(i + 1) % foot.size()]
		var nrm := Vector2(-(b.y - a.y), -(b.x - a.x)).normalized()
		if nrm.x + nrm.y <= 1e-3:
			continue
		var push := Vector2(nrm.x, -nrm.y) * out
		var k := maxi(1, Iso.shade(Vector3(nrm.x, nrm.y, 0.0)))
		_pt.wall(a + push, b + push, z0, z1, style, k, 0, 0, false, true)


# the mockup's tower crane: a gold lattice mast, a jib with its counterweight and cab, a hook on
# a line with a beam hanging from it
func _crane(id: String, at: Vector2, top: float) -> void:
	_object("crane" + id, Iso.square(at, 0.6), true, false)
	var base := iso.pi(at.x, at.y)
	var x := base.x
	var y := base.y
	var ch := int(top + 26.0)
	for k in ch:
		_pt.dot(Vector2(x, y - k), Pal.i("GOLD") if k % 3 else Pal.i("GOLD_M"))
		_pt.dot(Vector2(x + 1, y - k), Pal.i("GOLD_M") if k % 3 else Pal.i("WOOD"))
		if k % 3 == 1:
			_pt.dot(Vector2(x + (k / 3) % 2, y - k), Pal.i("INK"))
	var jy := y - ch
	_pt.block(Rect2(x - 12, jy, 38, 1), Pal.i("GOLD"))
	for dx in range(-12, 26):
		_pt.dot(Vector2(x + dx, jy + 1), Pal.i("GOLD_M") if dx % 3 else Pal.i("INK"))
	_pt.block(Rect2(x - 12, jy + 2, 6, 2), Pal.i("STN2"))
	_pt.block(Rect2(x - 12, jy + 4, 6, 1), Pal.i("STN3"))
	_pt.block(Rect2(x, jy - 1, 2, 1), Pal.i("GOLD"))
	_pt.dot(Vector2(x, jy - 2), Pal.i("GOLD_M"))
	_pt.block(Rect2(x - 2, jy + 2, 5, 3), Pal.i("CYAN_M"))
	_pt.dot(Vector2(x - 1, jy + 3), Pal.i("CYAN"))
	var hx := x + 18
	_pt.block(Rect2(hx, jy + 2, 1, 16), Pal.i("SL2"))
	_pt.dot(Vector2(hx, jy + 18), Pal.i("GOLD"))
	_pt.dot(Vector2(hx - 1, jy + 18), Pal.i("GOLD_M"))
	_pt.dot(Vector2(hx - 1, jy + 19), Pal.i("GOLD_M"))
	_pt.block(Rect2(hx - 3, jy + 20, 7, 1), Pal.i("CON2"))
	_close(0.0)
	tallest = maxf(tallest, ch + 4.0)


# apartment blocks on the lot's street sites, each its own height and facade, so a lot reads
# as a row of buildings; `office` puts the office on a site near (0, 0) instead
func _apartments(plot: Dictionary, poly: PackedVector2Array, owned: bool,
		office: String) -> Array[PackedVector2Array]:
	var levels := int(plot.get("levels", 5))
	var sites := _sites(plot, poly, SITE_DEPTH[3], SITE_FRONT[3])
	var mine := -1
	if office != "":
		# the office takes a site near the clicked point, the one nearest the viewer among them,
		# so the lot's taller blocks do not hide it
		var near := INF
		for k in sites.size():
			near = minf(near, Iso.centroid(sites[k]["poly"]).length())
		var best := -INF
		for k in sites.size():
			var c := Iso.centroid(sites[k]["poly"])
			if c.length() <= near + OFFICE_NEAR and Iso.depth(c) > best:
				best = Iso.depth(c)
				mine = k
	var built: Array[PackedVector2Array] = []
	for k in sites.size():
		var site := Iso.clean(sites[k]["poly"])
		var sid: String = sites[k]["id"]
		_g_poly(site, "PAVE")
		built.append(site)
		if k == mine:
			_office_at(plot["id"], site)
			continue
		var lv := levels + int(Iso.h01(sid + "lv") * 3.0) - 1
		var hz := _apt_top(lv)
		var roof := Pal.ramp_of("TEAL" if owned else "TER")
		_object(sid, site)
		_pt.prism(site, 0.0, hz, WorldShader.STYLE_APT, _facade(sid), roof)
		_roof_props(sid, site, hz, owned, false)
		_close(hz)
		tallest = maxf(tallest, hz + 16.0)
	if owned and office == "":
		_roof(iso.pv(Iso.centroid(poly), _apt_top(levels + 1)))
	return built


# the lot's building sites (Plotter.sites) with ids; a lot whose file names no street sides
# builds along all of them
func _sites(plot: Dictionary, poly: PackedVector2Array, depth: Vector2,
		front: Vector2) -> Array[Dictionary]:
	var id: String = plot["id"]
	var ring := poly
	if Geo.area(ring) < 0.0:
		ring = ring.duplicate()
		ring.reverse()
	var fronts := PackedInt32Array(plot.get("fronts", []))
	if fronts.is_empty():
		for i in ring.size():
			fronts.append(i)
	var d := lerpf(depth.x, depth.y, Iso.h01(id + "depth"))
	var out := Plotter.sites(ring, fronts, d, front, id)
	for k in out.size():
		out[k]["id"] = "%s_%d" % [id, k]
	return out


func _facade(key: String) -> int:
	return Pal.ramp_of(FACADES[int(Iso.h01(key + "fac") * FACADES.size())])


# a paved plaza with a planted border
func _plaza(poly: PackedVector2Array, id: String) -> void:
	_g_poly(poly, "PAVE_L")
	var ring := Iso.clean(poly)
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var m := int(a.distance_to(b) / 3.0)
		for j in m:
			if Iso.h01(id + "pl%d_%d" % [i, j]) < 0.5:
				continue
			var q := iso.pv(a.lerp(b, (j + 0.5) / maxi(1, m)))
			_g_dot(q, "GRASS_D")


# up to n square building spots of half-size `half` well inside the lot, a street-width apart,
# picked by hash (or the one nearest the middle when `central`); smaller when nothing fits
func _spots(poly: PackedVector2Array, n: int, half: float, seed: String,
		central: bool = false) -> Array[Vector2]:
	var out: Array[Vector2] = []
	var inner := Iso.offset(poly, -3.0)
	if inner.size() < 3:
		return out
	var box := Geo.bounds(inner)
	var h := half
	while h >= 5.0 and out.is_empty():
		var step := h * 2.0 + 7.0
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


# a skyscraper's podium: a square round its tower, cut to the lot
func _podium(poly: PackedVector2Array, at: Vector2, half: float) -> PackedVector2Array:
	var inner := Iso.offset(poly, -2.0)
	if inner.size() < 3:
		return PackedVector2Array()
	var best := PackedVector2Array()
	for part in Geo.clip(Iso.square(at, half), inner):
		if best.size() < 3 or Iso.area(part) > Iso.area(best):
			best = part
	return Iso.clean(best) if best.size() >= 3 else best


# an empty lot: dirt (a yard in industrial zones) inside fence posts, with clods and tufts, and
# a sale sign when it is inside the office's radius
func _lot(plot: Dictionary, poly: PackedVector2Array) -> void:
	var id: String = plot["id"]
	var zone: String = plot["zone"]
	_g_poly(poly, "PAVE_S" if zone == "industrial" else "DIRT")
	var c := Iso.centroid(poly)
	var inner := Iso.offset(poly, -1.5)
	var box := Geo.bounds(poly)
	# weeds take over patches of a big lot: rough blobs, darker at the rim
	if zone != "industrial" and inner.size() >= 3:
		for j in int(Iso.area(poly) / 260.0):
			var at := box.position + box.size * Vector2(Iso.h01(id + "wx%d" % j),
				Iso.h01(id + "wy%d" % j))
			var r := 3.0 + Iso.h01(id + "wr%d" % j) * 6.0
			var blob := PackedVector2Array()
			for k in 9:
				var a := TAU * k / 9.0
				blob.append(at + Vector2(cos(a), sin(a)) * r * (0.7 + 0.5 * Iso.h01(id + "w%d_%d" % [j, k])))
			for part in Geo.clip(blob, inner):
				_g_poly(Iso.clean(part), "GRASS_D")
				var core := Iso.offset(part, -1.2)
				if core.size() >= 3:
					_g_poly(core, "GRASS")
	# fence posts along the edges
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var m := int(a.distance_to(b) / 2.5)
		for j in m + 1:
			_g_dot(iso.pv(a.lerp(b, float(j) / maxi(1, m))), "DIRT_D")
	# dirt clods and grass tufts, about one per 12 square metres
	var want := int(Iso.area(poly) / 12.0)
	for j in want:
		var q := box.position + box.size * Vector2(Iso.h01(id + "x%d" % j), Iso.h01(id + "y%d" % j))
		if inner.size() < 3 or not Geometry2D.is_point_in_polygon(q, inner):
			continue
		var t := iso.pv(q)
		if j % 3 == 0:
			_g_dot(t, "GRASS")
			_g_dot(t + Vector2(-1, 0), "GRASS_D")
			_g_dot(t + Vector2(0, -1), "GRASS_L")
			_g_dot(t + Vector2(1, 0), "GRASS_D")
		elif zone != "industrial":
			_g_dot(t, "DIRT_L")
			_g_dot(t + Vector2(1, 0), "DIRT_D")
	# a few bushes come up in a big empty lot
	var bushes := int(Iso.area(poly) / 450.0)
	var deep := Iso.offset(poly, -3.0)
	for j in bushes:
		var q := box.position + box.size * Vector2(Iso.h01(id + "bx%d" % j), Iso.h01(id + "by%d" % j))
		if deep.size() >= 3 and Geometry2D.is_point_in_polygon(q, deep):
			_tree(q, id + "bush%d" % j, false)
	if active > 0.0 and c.length() > active:
		return
	# the sign stands half way to the corner nearest the viewer
	var front := poly[0]
	for q in poly:
		if Iso.depth(q) > Iso.depth(front):
			front = q
	var at := c.lerp(front, 0.5)
	# a solar the player owns flies his flag instead of the sale sign
	if plot.get("owned", false):
		_object("own" + id, Iso.square(at, 0.4), true, false)
		_pt.tex("flag:9:cyan", iso.pv(at))
		_close(0.0)
		_roof(iso.pv(at, 10.0))
		return
	_object("sale" + id, Iso.square(at, 0.4), true, false)
	_pt.tex("sale", iso.pv(at))
	_close(0.0)
	_for_sale.append({"at": c, "area": float(plot["area_m2"])})


# each lot's box in the drawing: its ground and everything standing on it
func _lot_boxes() -> void:
	for i in lots.size():
		lots[i]["box"] = _ground_box(i)
	for obj: Dictionary in objects:
		var k: int = obj["lot"]
		if k >= 0:
			lots[k]["box"] = (lots[k]["box"] as Rect2).merge(obj["rect"])


func _lot_box(i: int) -> void:
	var box := _ground_box(i)
	for obj: Dictionary in objects:
		if obj["lot"] == i:
			box = box.merge(obj["rect"])
	lots[i]["box"] = box


func _ground_box(i: int) -> Rect2:
	var pts: PackedVector2Array = lots[i]["screen"]
	var box := Rect2(pts[0], Vector2.ZERO) if not pts.is_empty() else Rect2()
	for q in pts:
		box = box.expand(q)
	return box


# where an owned lot's income pops rise
func _roof(at: Vector2) -> void:
	pops.append(at)
	if _lot_now >= 0:
		lots[_lot_now]["roof"] = at


func _shed(id: String, poly: PackedVector2Array, owned: bool) -> void:
	var base := Iso.offset(poly, -1.0)
	if base.size() < 3:
		base = poly
	var hz := 13.0
	_object(id, base)
	_pt.prism(base, 0.0, hz, WorldShader.STYLE_SHED, Pal.ramp_of("CON"),
		Pal.ramp_of("TEAL" if owned else "CON"))
	_close(hz)


func _house(id: String, poly: PackedVector2Array, tier: int, facade: int, owned: bool) -> void:
	var inner := Iso.offset(poly, -1.6 if tier == 1 else -1.2)
	if inner.size() < 3:
		inner = poly
	var rect := Iso.min_rect(inner, 0.78 if tier == 1 else 0.86)
	if rect.size() < 4:
		return
	rect = _cap_rect(rect, 11.0 if tier == 1 else 14.0, 8.0 if tier == 1 else 10.0)
	# pushed toward the back of the plot when it still fits
	var push := Vector2(-1.2, 1.6) if tier == 1 else Vector2(-1.6, 2.0)
	var moved := Iso.moved(rect, push)
	if Iso.contains(inner, moved):
		rect = moved
	var floors := 2 if tier == 1 else 3
	var hz := floors * 5.0 + 1.0
	var rr := Pal.ramp_of("TEAL" if owned else "TIL")
	_object(id, rect)
	var ridge := _pt.pitched(rect, 0.0, hz, facade, rr, 6.0 if tier == 1 else 8.0,
		0.0 if tier == 1 else 0.28, WorldShader.STYLE_HOUSE)
	var r1: Vector2 = ridge[0]
	var r2: Vector2 = ridge[1]
	var zt: float = ridge[2]
	var ch := r1.lerp(r2, 0.7) + Vector2(0.8, 0.8)
	var stn := Pal.ramp_of("STN")
	_pt.prism(Iso.square(ch, 0.7), zt - 3.0, zt + 2.0, WorldShader.STYLE_PLAIN, stn, stn, false)
	if owned:
		_pt.tex("flag:7:cyan", iso.pv(r1, zt))
	_close(hz + 4.0, rect)
	if tier == 2:
		_pool(id, poly, rect)
	# a couple of garden trees away from the house
	var room := Iso.offset(poly, -1.5)
	var c := Iso.centroid(poly)
	var n := 0
	for j in 4:
		var q := c + Vector2(Iso.h01(id + "tx%d" % j) - 0.5, Iso.h01(id + "ty%d" % j) - 0.5) * 16.0
		if room.size() < 3 or not Geometry2D.is_point_in_polygon(q, room):
			continue
		if Geometry2D.is_point_in_polygon(q, Iso.offset(rect, 2.0)):
			continue
		_tree(q, id + str(j), false)
		n += 1
		if n >= 2:
			break


# a rectangle (A->B its long side) shrunk about its middle to at most long x short metres, so a
# house stays house-sized on a deep site
static func _cap_rect(rect: PackedVector2Array, long: float, short: float) -> PackedVector2Array:
	var c := (rect[0] + rect[2]) * 0.5
	var e := rect[1] - rect[0]
	var f := rect[3] - rect[0]
	var he := e.normalized() * minf(e.length(), long) * 0.5
	var hf := f.normalized() * minf(f.length(), short) * 0.5
	return PackedVector2Array([c - he - hf, c + he - hf, c + he + hf, c - he + hf])


# a pool in the leftover garden of an estate, cream rim and cyan water
func _pool(id: String, poly: PackedVector2Array, rect: PackedVector2Array) -> void:
	var room := Iso.offset(poly, -1.6)
	if room.size() < 3:
		return
	var away := Iso.offset(rect, 1.4)
	var best := PackedVector2Array()
	var best_a := 0.0
	for part in Geo.minus(room, away):
		var a := Iso.area(part)
		if a > best_a:
			best_a = a
			best = part
	if best_a < 12.0:
		return
	var box := Iso.min_rect(best, 0.8 if best_a > 60.0 else 1.0)
	if box.size() < 4:
		return
	_g_poly(box, "CREAM")
	var water := Iso.offset(box, -0.7)
	if water.size() >= 3:
		_g_poly(water, "CYAN_M")
		var deep := Iso.offset(water, -0.6)
		if deep.size() >= 3:
			_g_poly(deep, "CYAN")


func _tower(id: String, poly: PackedVector2Array, levels: int, owned: bool) -> void:
	var base := Iso.offset(poly, -1.2)
	if base.size() < 3:
		base = poly
	var top := Iso.offset(base, -2.2)
	var hz := 5.0 + _tower_floors(levels) * 3.0 + 2.0
	var hz2 := hz + 7.0
	var con := Pal.ramp_of("CON")
	var teal := Pal.ramp_of("TEAL")
	_object(id, base)
	_pt.prism(base, 0.0, hz, WorldShader.STYLE_TOWER, con, teal if owned else con)
	var crown := hz
	if top.size() >= 3 and Iso.area(top) > 6.0:
		_pt.prism(top, hz, hz2, WorldShader.STYLE_TOWER, con, teal if owned else con, true, 1)
		_roof_props(id, top, hz2, owned, true)
		crown = hz2
	_close(crown, base)
	tallest = maxf(tallest, crown + 16.0)


func _sky(id: String, poly: PackedVector2Array, levels: int, owned: bool,
		podium: PackedVector2Array = PackedVector2Array()) -> void:
	var b0 := Iso.offset(poly, -1.0)
	if b0.size() < 3:
		b0 = poly
	var b1 := Iso.offset(b0, -1.6)
	var b2 := Iso.offset(b1, -1.8) if b1.size() >= 3 else PackedVector2Array()
	var base := PODIUM_Z if podium.size() >= 3 else 0.0
	var z0 := base + 6.0 + _sky_floors(levels) * 3.0 + 3.0
	var z1 := z0 + 21.0
	var z2 := z1 + 12.0
	var con := Pal.ramp_of("CON")
	var teal := Pal.ramp_of("TEAL")
	var sty := WorldShader.STYLE_SKY
	_object(id, podium if podium.size() >= 3 else b0)
	if podium.size() >= 3:
		_pt.prism(podium, 0.0, base, WorldShader.STYLE_TOWER, con, teal if owned else con)
	_pt.prism(b0, base, z0, sty, 0, teal if owned else con, true, 1 | (1 << 1), base == 0.0)
	var top := z0
	var crown := b0
	if b1.size() >= 3 and Iso.area(b1) > 6.0:
		_pt.prism(b1, z0, z1, sty, 0, teal if owned else con, true, 1 << 1)
		top = z1
		crown = b1
		if b2.size() >= 3 and Iso.area(b2) > 4.0:
			_pt.prism(b2, z1, z2, sty, 0, teal if owned else Pal.ramp_of("GLS"), true, 2 << 1)
			top = z2
			crown = b2
	var cc := Iso.centroid(crown)
	var tip := iso.pv(cc, top)
	for k in 14:
		_pt.dot(tip + Vector2(0, -k), Pal.i("SL5") if k % 4 else Pal.i("SL3"))
	_pt.dot(tip + Vector2(0, -14), Pal.i("RED"))
	_pt.dot(tip + Vector2(0, -15), Pal.i("RED"))
	if owned:
		var far := crown[0]
		for q in crown:
			if q.x + q.y < far.x + far.y:
				far = q
		_pt.tex("flag:6:cyan", iso.pv(far, top) + Vector2(1, 1))
	_close(top, podium if podium.size() >= 3 else b0)
	tallest = maxf(tallest, top + 20.0)


# stairwell huts and water tanks on a flat roof (the Eixample's "casetes"), a flag when owned
func _roof_props(id: String, g: PackedVector2Array, hz: float, owned: bool, modern: bool) -> void:
	var gi := Iso.offset(g, -1.6)
	if gi.size() < 3:
		return
	var c := Iso.centroid(gi)
	var area := Iso.area(gi)
	var n := 1 + int(Iso.h01(id + "np") * 2.0) + (1 if area > 250.0 else 0)
	var props: Array = []
	for k in n * 3:
		if props.size() >= n:
			break
		var w := (3.2 if k % 3 == 0 else 1.8) if not modern else (2.4 if k % 2 == 0 else 1.6)
		var at := c + Vector2(Iso.h01(id + "px%d" % k) - 0.5,
			Iso.h01(id + "py%d" % k) - 0.5) * sqrt(area) * 0.9
		var bx := Iso.square(at, w * 0.5)
		if not Iso.contains(gi, bx):
			continue
		var clear := true
		for p: Array in props:
			var o: Vector2 = p[0]
			if absf(o.x - at.x) < (w + float(p[1])) * 0.5 + 0.6 \
					and absf(o.y - at.y) < (w + float(p[1])) * 0.5 + 0.6:
				clear = false
		if clear:
			props.append([at, w])
	props.sort_custom(func(p: Array, q: Array) -> bool:
		return Iso.depth(p[0]) < Iso.depth(q[0]))
	for p: Array in props:
		var bx := Iso.square(p[0], float(p[1]) * 0.5)
		if float(p[1]) > 3.0:
			_pt.prism(bx, hz, hz + 4.0, WorldShader.STYLE_PLAIN, Pal.ramp_of("CRM"),
				Pal.ramp_of("STN"), false)
		elif modern:
			_pt.prism(bx, hz, hz + 2.0, WorldShader.STYLE_PLAIN, Pal.ramp_of("CON"),
				Pal.ramp_of("CON"), false)
		else:
			_pt.prism(bx, hz, hz + 3.0, WorldShader.STYLE_PLAIN, Pal.ramp_of("STN"),
				Pal.ramp_of("STN"), false)
	if owned:
		var far := gi[0]
		for q in gi:
			if Iso.depth(q) < Iso.depth(far):
				far = q
		_pt.tex("flag:7:cyan", iso.pv(far, hz))


# the player's office: a modest three-storey building on its site (capped in size, so it reads
# as one office among ordinary blocks), a cyan shop front, a teal roof, a small REALTOR plate on
# the roof and a flag
func _office_at(id: String, poly: PackedVector2Array) -> void:
	var inner := Iso.offset(poly, -1.5)
	if inner.size() < 3:
		inner = poly
	var foot := Iso.min_rect(inner, 0.92)
	if foot.size() >= 4:
		foot = _cap_rect(foot, OFFICE_SIZE.x, OFFICE_SIZE.y)
	else:
		foot = inner
	var hz := 7.0 + 5.0 * 2.0 + 2.0
	_object(id, foot)
	_pt.prism(foot, 0.0, hz, WorldShader.STYLE_OFFICE, Pal.ramp_of("STN"), Pal.ramp_of("TEAL"))
	var c := Iso.centroid(foot)
	var at := iso.pv(c, hz)
	_pt.tex("plate", at)
	var sign := Sprites.get_sprite("plate")
	keep_clear.append(Rect2(at + sign[1], sign[2]).grow(4.0))
	var left := foot[0]
	for q in foot:
		if q.x + q.y < left.x + left.y:
			left = q
	_pt.tex("flag:7:cyan", iso.pv(left + (c - left).normalized() * 1.0, hz))
	_roof(iso.pv(c, hz + 14.0))
	_close(hz)
	tallest = maxf(tallest, hz + 16.0)


# when the clicked spot has no plot near it, a small office stands on the pavement
func _kiosk() -> void:
	_office_at("kiosk", Iso.square(Vector2.ZERO, 5.0))


# --- greenery and street life --------------------------------------------------------------------

func _tree(at: Vector2, seed: String, big: bool) -> void:
	_object("t" + seed, Iso.square(at, 0.8))
	_pt.tex("tree:%d:%s" % [int(Iso.h01(seed + "v") * 4.0), "big" if big else "small"],
		iso.pv(at))
	_close(5.0, Iso.square(at, 1.4))


func _trees() -> void:
	for c: Dictionary in _block["courts"]:
		_scatter(_pts(c["poly"]), "c%d" % _block["courts"].find(c), 80.0)
	for g: Dictionary in _block["greens"]:
		var kind: String = g["kind"]
		if kind in ["pitch", "sand", "beach", "golf_course"]:
			continue
		_scatter(_pts(g["poly"]), "g" + kind + str(_block["greens"].find(g)),
			45.0 if kind in DENSE_TREES else 120.0)
	# plane trees down the pavements, one every few metres, not in the corners
	for b: Dictionary in _block["blocks"]:
		var poly := Iso.clean(_pts(b["poly"]))
		_along(poly, 1.6, STREET_TREE_EVERY, 3.0, func(q: Vector2, k: int) -> void:
			_tree(q, "st%s_%d" % [b["id"], k], false))


# trees scattered at random inside a polygon, about one per `every` square metres, never two
# closer than half the spacing, so a garden reads as a grove rather than a grid; never on or
# right next to the `avoid` footprints (buildings)
func _scatter(poly: PackedVector2Array, seed: String, every: float,
		avoid: Array[PackedVector2Array] = []) -> void:
	var inner := Iso.offset(poly, -2.0)
	if inner.size() < 3:
		return
	var keep_out: Array[PackedVector2Array] = []
	var boxes: Array[Rect2] = []
	for a in avoid:
		var grown := Iso.offset(a, 1.8)
		if grown.size() >= 3:
			keep_out.append(grown)
			boxes.append(Geo.bounds(grown))
	var box := Geo.bounds(inner)
	var want := int(Iso.area(inner) / every)
	var gap := sqrt(every) * 0.55
	var placed := PackedVector2Array()
	for k in want * 3:
		if placed.size() >= want:
			break
		var q := box.position + box.size * Vector2(Iso.h01(seed + "a%d" % k),
			Iso.h01(seed + "b%d" % k))
		if q.length() > radius - 3.0 or not Geometry2D.is_point_in_polygon(q, inner):
			continue
		var clear := true
		for j in keep_out.size():
			if boxes[j].has_point(q) and Geometry2D.is_point_in_polygon(q, keep_out[j]):
				clear = false
				break
		if not clear:
			continue
		for o in placed:
			if o.distance_to(q) < gap:
				clear = false
				break
		if not clear:
			continue
		placed.append(q)
		_tree(q, seed + str(k), Iso.h01(seed + "big%d" % k) < 0.3)


# calls fn at points every `every` m around a polygon grown by `out` m, away from its corners
func _along(poly: PackedVector2Array, out: float, every: float, start: float,
		fn: Callable) -> void:
	var ring := Iso.offset(poly, out)
	if ring.size() < 3:
		return
	var k := 0
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var length := a.distance_to(b)
		var d := start + 2.0
		while d < length - start - 2.0:
			var q := a.lerp(b, d / length)
			d += every
			k += 1
			if q.length() < radius - 3.0:
				fn.call(q, k)


func _street_furniture() -> void:
	if active <= 0.0:
		return
	for b: Dictionary in _block["blocks"]:
		var poly := Iso.clean(_pts(b["poly"]))
		var c := Iso.centroid(poly)
		if c.length() > active + 120.0:
			continue
		var bid: String = b["id"]
		_along(poly, 2.6, LAMP_EVERY, 6.0, func(q: Vector2, _k: int) -> void:
			if q.length() < active - 4.0:
				_object("lamp", Iso.square(q, 0.3), false, false)
				_pt.tex("lamp", iso.pv(q))
				_close(0.0))
		_along(poly, 1.0, 11.0, 4.0, func(q: Vector2, k: int) -> void:
			var seed := "%s_%d" % [bid, k]
			if q.length() < active and Iso.h01(seed + "ped") < 0.4:
				var at := q + Vector2(Iso.h01(seed + "jx") - 0.5, Iso.h01(seed + "jy") - 0.5) * 2.0
				_object("ped", Iso.square(at, 0.3), false, false)
				_pt.tex("ped:%d" % int(Iso.h01(seed + "sh") * 6.0), iso.pv(at))
				_close(0.0))


# cars parked along the kerb, a few per street, never in a junction; only where they leave
# Traffic's moving lanes clear: both kerbs of 12-18 m streets, one kerb of a narrow one-way street
# (whose single lane runs down the middle); narrower two-way and wider streets have none
func _cars() -> void:
	var tints := ["RED", "CREAM", "CYAN_M", "taxi", "GOLD", "SL5"]
	var k := 0
	for road: Dictionary in _block["roads"]:
		var w := float(road["width"])
		var both := w >= 12.0 and w < 18.0
		var one := int(road.get("oneway", 0)) != 0 and w >= 8.5 and w < 10.0
		if road["kind"] == "pedestrian" or not (both or one):
			continue
		var line := _pts(road["line"])
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			var length := a.distance_to(b)
			var d := CAR_EVERY * 0.5
			while d < length - 4.0:
				k += 1
				var seed := "car%d" % k
				var dir := (b - a) / length
				var q := a + dir * (d + (Iso.h01(seed + "j") - 0.5) * 10.0)
				d += CAR_EVERY
				if Iso.h01(seed) > CAR_CHANCE or q.length() > radius - 6.0:
					continue
				if _near_junction(q, 16.0):
					continue
				var lane := 1.0 if Iso.h01(seed + "l") < 0.5 or not both else -1.0
				q += dir.orthogonal() * lane * (w * 0.5 - 1.05)
				_car(q, dir, tints[int(Iso.h01(seed + "c") * tints.size())], seed)


func _car(at: Vector2, dir: Vector2, tint: String, seed: String) -> void:
	var side := dir.orthogonal()
	var foot := Iso.clean(PackedVector2Array([at - dir * 2.2 - side, at + dir * 2.2 - side,
		at + dir * 2.2 + side, at - dir * 2.2 + side]))
	var taxi := tint == "taxi"
	var body := Pal.car_ramp(Pal.CAR_TINTS.find("SL1" if taxi else tint))
	var top := Pal.car_ramp(Pal.CAR_TINTS.find("GOLD")) if taxi else body
	_object(seed, foot)
	_pt.prism(foot, 0.0, 2.0, WorldShader.STYLE_PLAIN, body, body, false)
	var cab := Iso.offset(foot, -0.45)
	if cab.size() >= 3:
		_pt.prism(cab, 2.0, 3.0, WorldShader.STYLE_CAB, body, top, false)
	_close(3.0)


# price tags over the signed lots nearest the office, never one over another
func _tags() -> void:
	_for_sale.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return (p["at"] as Vector2).length() < (q["at"] as Vector2).length())
	var placed: Array[Rect2] = keep_clear.duplicate()
	for lot in _for_sale:
		if placed.size() >= TAGS + keep_clear.size():
			break
		var key := "tag:" + price_tag(float(lot["area"]))
		var at := iso.pv(lot["at"])
		var sp := Sprites.get_sprite(key)
		var box := Rect2(at + sp[1], sp[2]).grow(3.0)
		var free := true
		for q in placed:
			free = free and not q.intersects(box)
		if free:
			placed.append(box)
			post.append([Painter.OP_TEX, key, at])


# the placeholder asking price of a lot, until the game has an economy
static func price_of(area_m2: float) -> int:
	return maxi(1000, roundi(area_m2 * PRICE_M2 / 1000.0) * 1000)


# the price as a short tag: $850K, $1.2M
static func price_tag(area_m2: float) -> String:
	var p := price_of(area_m2)
	if p >= 1000000:
		return "$%.1fM" % (p / 1000000.0)
	return "$%dK" % (p / 1000)


# --- helpers -------------------------------------------------------------------------------------

func _in_disc(poly: PackedVector2Array) -> Array[PackedVector2Array]:
	var r2 := radius * radius
	for q in poly:
		if q.length_squared() > r2:
			return Geo.clip(poly, Geo.circle(radius, DISC_SIDES))
	return [poly]


static func _pts(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in raw:
		out.append(Vector2(q[0], q[1]))
	return out
