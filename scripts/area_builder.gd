class_name AreaBuilder
extends RefCounted

# Turns a baked office area (format v2) into what BlockView draws, as ops in low-res pixels:
#   ground  - palette indices for the ground pass (pavement, roads, parks, water, lots, marks)
#   shadows - the cast-shadow mask (white polygons)
#   pre     - drawn in colour over the ground before any object (the slab's earth cut, the ring)
#   objects - buildings, trees, cars, lamps, people: each with its ops, footprint hull and
#             screen box, put in painter's order by DepthSort and outlined in ink when drawn
#   post    - drawn last, over everything (price tags)
# The building recipes per tier are the mockup's (gen_battlegrounds.py build_tier, office,
# roof_props, car_obj...), fed by the plot's own polygon, tier, levels, zone and owned flag.
# Street furniture (trees, lamps, cars, people) is placed from the blocks and roads with stable
# hashes, so the same area always looks the same.

const DISC_SIDES := 192
const SLAB_DEPTH := 14.0
const FACADES: Array[String] = ["CRM", "OCH", "SAL", "STN", "CRM", "OCH"]
# the share of empty plots with a "for sale" sign inside the active radius, and how many of the
# nearest get a price tag over them
const SIGN_EVERY := 0.15
const TAGS := 5
# placeholder asking price per square metre, until the game has an economy
const PRICE_M2 := 300.0
const STREET_TREE_EVERY := 9.0
const LAMP_EVERY := 17.0
const DASH_CLEAR := 14.0
const CAR_EVERY := 38.0
const CAR_CHANCE := 0.45
const GREEN_KIND := {"pitch": "GRASS_L", "playground": "GRASS_L", "golf_course": "GRASS_L",
	"forest": "GRASS_D", "wood": "GRASS_D", "scrub": "GRASS_D", "heath": "GRASS_D",
	"cemetery": "GRASS_D", "sand": "DIRT_L", "beach": "DIRT_L"}
const DENSE_TREES := ["forest", "wood", "scrub", "park", "cemetery", "nature_reserve"]

var iso: Iso
var radius := 0.0
var active := 0.0
var ground: Array = []
var shadows: Array = []
var pre: Array = []
var objects: Array = []
var post: Array = []
# where income pops rise from: over the roofs of what the player owns
var pops: Array[Vector2] = []
# the highest pixel any object reaches above its ground point, for the drawing's bounds
var tallest := 40.0

var _block: Dictionary
var _pt: Painter
var _junctions: Array[Dictionary] = []
var _lots: Array[Dictionary] = []
# screen boxes price tags must keep clear of (the office's sign)
var _keep_clear: Array[Rect2] = []


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
	_ground_plots()
	_ground_marks()
	_slab()
	var office: String = _block.get("office_plot", "")
	var has_office := false
	for plot: Dictionary in _block["plots"]:
		if plot["id"] == office:
			_office(plot)
			has_office = true
		elif int(plot["built_tier"]) > 0:
			_building(plot)
	if not has_office:
		_kiosk()
	_trees()
	_street_furniture()
	_cars()
	_tags()
	_ring()


# the top of the tallest thing in a plot of this tier, in pixels
static func top_of(tier: int, levels: int) -> float:
	match tier:
		1, 2:
			return 30.0
		3:
			return 6.0 + (clampi(levels, 4, 9) - 1) * 4.0 + 2.0 + 6.0
		4:
			return _tower_floors(levels) * 3.0 + 7.0 + 7.0 + 12.0
		5:
			return _sky_floors(levels) * 3.0 + 9.0 + 33.0 + 18.0
	return 16.0


static func _tower_floors(levels: int) -> int:
	return clampi(levels + 6, 14, 22)


static func _sky_floors(levels: int) -> int:
	return clampi(levels, 20, 35)


# --- ground --------------------------------------------------------------------------------------

func _g_poly(poly: PackedVector2Array, name: String) -> void:
	var pts := iso.poly(poly)
	if pts.size() >= 3 and not Geometry2D.triangulate_polygon(pts).is_empty():
		ground.append([Painter.OP_POLY, pts, Pal.i(name)])


func _g_dot(at: Vector2, name: String) -> void:
	ground.append([Painter.OP_RECT, Rect2(at, Vector2.ONE), Pal.i(name)])


func _g_line(a: Vector2, b: Vector2, name: String) -> void:
	for r in Painter.line_runs(iso.pv(a), iso.pv(b)):
		ground.append([Painter.OP_RECT, r, Pal.i(name)])


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


# every plot's own ground: dirt lots with fence posts and tufts, gardens with a hedge, plazas
func _ground_plots() -> void:
	var office: String = _block.get("office_plot", "")
	for plot: Dictionary in _block["plots"]:
		var poly := _pts(plot["poly"])
		var tier := int(plot["built_tier"])
		var id: String = plot["id"]
		if id == office:
			continue
		if tier == 0:
			_lot(plot, poly)
		elif tier in [1, 2] and plot["zone"] != "industrial":
			_g_poly(poly, "GRASS")
			var hedge := Iso.offset(poly, -0.6)
			for i in hedge.size():
				_g_line(hedge[i], hedge[(i + 1) % hedge.size()], "GRASS_DD")
		elif tier == 1:
			_g_poly(poly, "PAVE_S")
		elif tier >= 4:
			_g_poly(poly, "PAVE_L")


func _lot(plot: Dictionary, poly: PackedVector2Array) -> void:
	var id: String = plot["id"]
	var zone: String = plot["zone"]
	_g_poly(poly, "PAVE_S" if zone == "industrial" else "DIRT")
	# fence posts along the edges
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var m := int(a.distance_to(b) / 2.5)
		for j in m + 1:
			_g_dot(iso.pv(a.lerp(b, float(j) / maxi(1, m))), "DIRT_D")
	# dirt clods and grass tufts
	var c := Iso.centroid(poly)
	var inner := Iso.offset(poly, -1.5)
	for j in 14:
		var q := c + Vector2(Iso.h01(id + "x%d" % j) - 0.5, Iso.h01(id + "y%d" % j) - 0.5) * 16.0
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
	if active > 0.0 and c.length() > active:
		return
	if Iso.h01(id + "sign") > SIGN_EVERY:
		return
	# the sign stands half way to the corner nearest the viewer
	var front := poly[0]
	for q in poly:
		if Iso.depth(q) > Iso.depth(front):
			front = q
	var at := c.lerp(front, 0.5)
	_object("sale" + id, Iso.square(at, 0.4), true, false)
	_pt.tex("sale", iso.pv(at))
	_close(0.0)
	_lots.append({"at": c, "area": float(plot["area_m2"])})


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
	_cur = {"foot": foot, "outline": outline, "shadow": shadow, "h": 0.0}
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
	_cur["fade"] = active > 0.0 and c.length() > active + 2.0
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
	shadows.append(iso.poly(ring))
	shadows.append(iso.poly(Iso.moved(ring, by)))
	for i in ring.size():
		var a := ring[i]
		var b := ring[(i + 1) % ring.size()]
		var q := PackedVector2Array([a, b, b + by, a + by])
		if absf(Geo.area(q)) > 0.01:
			shadows.append(iso.poly(Iso.clean(q)))


# --- buildings -----------------------------------------------------------------------------------

func _building(plot: Dictionary) -> void:
	var id: String = plot["id"]
	var poly := Iso.clean(_pts(plot["poly"]))
	var tier := int(plot["built_tier"])
	var owned: bool = plot.get("owned", false)
	var levels := int(plot.get("levels", 4))
	var facade := Pal.ramp_of(FACADES[int(Iso.h01(id + "fac") * FACADES.size())])
	var roof := Pal.ramp_of("TEAL" if owned else "TER")
	if owned:
		pops.append(iso.pv(Iso.centroid(poly), top_of(tier, levels)))
	if tier <= 2 and plot["zone"] == "industrial":
		_shed(id, poly, owned)
	elif tier <= 2:
		_house(id, poly, tier, facade, owned)
	elif tier == 3:
		var hz := 6.0 + (clampi(levels, 4, 9) - 1) * 4.0 + 2.0
		_object(id, poly)
		_pt.prism(poly, 0.0, hz, WorldShader.STYLE_APT, facade, roof)
		_roof_props(id, poly, hz, owned, false)
		_close(hz)
		tallest = maxf(tallest, hz + 16.0)
	elif tier == 4:
		_tower(id, poly, levels, owned)
	else:
		_sky(id, poly, levels, owned)


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


func _sky(id: String, poly: PackedVector2Array, levels: int, owned: bool) -> void:
	var b0 := Iso.offset(poly, -1.0)
	if b0.size() < 3:
		b0 = poly
	var b1 := Iso.offset(b0, -1.6)
	var b2 := Iso.offset(b1, -1.8) if b1.size() >= 3 else PackedVector2Array()
	var z0 := 6.0 + _sky_floors(levels) * 3.0 + 3.0
	var z1 := z0 + 21.0
	var z2 := z1 + 12.0
	var con := Pal.ramp_of("CON")
	var teal := Pal.ramp_of("TEAL")
	var sty := WorldShader.STYLE_SKY
	_object(id, b0)
	_pt.prism(b0, 0.0, z0, sty, 0, teal if owned else con, true, 1 | (1 << 1))
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
	_close(top, b0)
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


# the player's office: stone, a cyan shop front, a teal roof, the REALTOR sign and a flag
func _office(plot: Dictionary) -> void:
	var poly := Iso.clean(_pts(plot["poly"]))
	_office_at(plot["id"], poly)


func _office_at(id: String, poly: PackedVector2Array) -> void:
	var hz := 7.0 + 5.0 * 5.0 + 2.0
	_object(id, poly)
	_pt.prism(poly, 0.0, hz, WorldShader.STYLE_OFFICE, Pal.ramp_of("STN"), Pal.ramp_of("TEAL"))
	var c := Iso.centroid(poly)
	_pt.tex("billboard", iso.pv(c, hz))
	var sign := Sprites.get_sprite("billboard")
	_keep_clear.append(Rect2(iso.pv(c, hz) + sign[1], sign[2]).grow(4.0))
	# the flag on the leftmost corner, or on the sign when the building is too narrow for both
	var left := poly[0]
	var right := poly[0]
	for q in poly:
		if q.x + q.y < left.x + left.y:
			left = q
		if q.x + q.y > right.x + right.y:
			right = q
	if iso.pv(right).x - iso.pv(left).x > 56.0:
		_pt.tex("flag:9:cyan", iso.pv(left + (c - left).normalized() * 1.2, hz))
	else:
		_pt.tex("flag:7:cyan", iso.pv(c, hz) + Vector2(17, -20))
	pops.append(iso.pv(c, hz + 24.0))
	_close(hz)
	tallest = maxf(tallest, hz + 30.0)


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
		_scatter(_pts(c["poly"]), "c%d" % objects.size(), 150.0)
	for g: Dictionary in _block["greens"]:
		var kind: String = g["kind"]
		if kind in ["pitch", "sand", "beach", "golf_course"]:
			continue
		_scatter(_pts(g["poly"]), "g" + kind + str(objects.size()),
			45.0 if kind in DENSE_TREES else 120.0)
	# plane trees down the pavements, one every few metres, not in the corners
	for b: Dictionary in _block["blocks"]:
		var poly := Iso.clean(_pts(b["poly"]))
		_along(poly, 1.6, STREET_TREE_EVERY, 3.0, func(q: Vector2, k: int) -> void:
			_tree(q, "st%s_%d" % [b["id"], k], false))


# trees scattered at random inside a polygon, about one per `every` square metres, never two
# closer than half the spacing, so a garden reads as a grove rather than a grid
func _scatter(poly: PackedVector2Array, seed: String, every: float) -> void:
	var inner := Iso.offset(poly, -2.0)
	if inner.size() < 3:
		return
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


# parked and passing cars in the lanes, a few per street, never in a junction
func _cars() -> void:
	var tints := ["RED", "CREAM", "CYAN_M", "taxi", "GOLD", "SL5"]
	var k := 0
	for road: Dictionary in _block["roads"]:
		var w := float(road["width"])
		if road["kind"] == "pedestrian" or w < 7.0:
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
				var lane := 1.0 if Iso.h01(seed + "l") < 0.5 else -1.0
				q += dir.orthogonal() * lane * maxf(1.6, w * 0.22)
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
	_lots.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return (p["at"] as Vector2).length() < (q["at"] as Vector2).length())
	var placed: Array[Rect2] = _keep_clear.duplicate()
	for lot in _lots:
		if placed.size() >= TAGS + _keep_clear.size():
			break
		var price := maxi(1, roundi(float(lot["area"]) * PRICE_M2 / 1000.0))
		var key := "tag:$%dK" % price
		var at := iso.pv(lot["at"])
		var sp := Sprites.get_sprite(key)
		var box := Rect2(at + sp[1], sp[2]).grow(3.0)
		var free := true
		for q in placed:
			free = free and not q.intersects(box)
		if free:
			placed.append(box)
			post.append([Painter.OP_TEX, key, at])


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
