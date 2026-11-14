class_name OfficeView
extends Screen

# One office's saved area, style A: BlockView draws the whole disc once into a texture (a frame
# or two after opening) and this screen shows it through a sprite, so panning only moves the
# sprite. Drag to pan, wheel or - + to zoom (each art pixel 1, 2 or 3 screen pixels; 2 is the
# mockup's). Over it, the HUD of the mockup: back button and the neighbourhood's name, how many
# lots are yours, the office level with its radius bar, street names along the streets and the
# OpenStreetMap credit. Pointing at a lot outlines everything it shows (BlockView's pick pass:
# cyan, grey when it is outside the office's radius); clicking it selects it (gold) and opens a
# card with its street, zone, size, tier and asking price; Esc or the card's X closes the card.
# A saved v2 area (small plots) is re-parcelled into lots when it is opened, and saved back.
# Traffic drives cars over the drawing, as a child of its sprite.

const ZOOMS: Array[int] = [1, 2, 3]
const START_ZOOM := 1
const VIEW_TOP := 0.0
const VIEW_BOTTOM := Ui.CANVAS.y
const ZOOM_OUT := Rect2(476, 14, 52, 52)
const ZOOM_IN := Rect2(536, 14, 52, 52)
const LEVEL_BAR := Rect2(12, 552, 576, 20)
# where on screen the office sits: a little below the middle, under the HUD's title
const ANCHOR := Vector2(300, 330)
# street names are sheared along the street when it runs at most this steep on screen
const SHEAR_MAX := 1.0
const POP_EVERY := 2.4
const POP_LIFE := 1.4
const POP_RISE := 16.0
# the selected lot's card, above the level bar, and its close button
const CARD := Rect2(12, 372, 576, 154)
const CARD_X := Rect2(528, 380, 52, 52)
# the map takes pointing only between the header and the level bar
const MAP_TOP := 110.0
const MAP_BOTTOM := 530.0
const TIERS: Array[String] = ["Solar", "Casas", "Urbanización", "Bloque de pisos", "Torres",
	"Rascacielos"]
const ZONES := {"residential": "Residencial", "commercial": "Comercial",
	"industrial": "Industrial"}

var office: Dictionary = {}

var _view: BlockView
var _sprite: Sprite2D
var _over: Node2D
var _zoom_i := START_ZOOM
var _pan := Vector2.ZERO
var _stats: Dictionary = {}
var _street_spots: Array[Dictionary] = []
var _owned := 1
var _lot_count := 0
var _office_lot := ""
# the lot under the pointer and the selected one, -1 for none
var _hover := -1
var _picked := -1
# zoom step -> labels that fit without overlapping at that zoom
var _labels := {}
# income pops: a gold "+$" rising off the roofs the player owns, one after another
var _pop_t := 0.0
var _traffic: Traffic


# false when the saved file is missing or unreadable
func setup(meta: Dictionary) -> bool:
	office = meta
	var path := Store.office_path(meta["id"])
	var block: Variant = Store.read_json(path)
	if not block is Dictionary:
		push_error("OfficeView: cannot read " + path)
		return false
	if int(block.get("format_version", 0)) == 2 and block.has("blocks"):
		var t0 := Time.get_ticks_msec()
		block = BlockBaker.upgrade(block)
		Store.write_json(path, block)
		print("OfficeView: %s upgraded from v2 to v%d: %d lots in %d ms" % [meta["id"],
			BlockBaker.VERSION, block["plots"].size(), Time.get_ticks_msec() - t0])
	_view = BlockView.new()
	_view.active_radius = float(meta.get("active_radius", Rules.active_radius(1)))
	if not _view.set_block(block):
		return false
	_stats = block.get("stats", {})
	_owned = 0
	_office_lot = block.get("office_plot", "")
	_lot_count = block["plots"].size()
	for p: Dictionary in block["plots"]:
		if p.get("owned", false) or p["id"] == _office_lot:
			_owned += 1
	_owned = maxi(_owned, 1)
	_street_spots = _view.street_labels()
	_traffic = Traffic.new()
	_traffic.setup(block, _view.focus, meta["id"])
	return true


# true once the area has been drawn and is on screen
func is_drawn() -> bool:
	return _view != null and _view.texture != null


func _ready() -> void:
	_sprite = Sprite2D.new()
	_sprite.centered = false
	add_child(_sprite)
	_sprite.add_child(_traffic)
	_over = Node2D.new()
	_over.draw.connect(_draw_over)
	add_child(_over)
	_view.drawn.connect(_on_drawn)
	add_child(_view)
	_set_zoom(_zoom_i)


func _on_drawn() -> void:
	_sprite.texture = _view.texture
	_traffic.attach(_view, _view.active_radius)
	print("OfficeView: %s drawn %dx%d, build %d ms, gpu %d ms" % [office.get("id", ""),
		roundi(_view.size.x), roundi(_view.size.y), _view.build_ms, _view.draw_ms])
	_over.queue_redraw()


func _process(delta: float) -> void:
	if is_drawn() and not _view.pops.is_empty():
		var before := int(_pop_t * 10.0)
		_pop_t += delta
		# the pop moves in whole steps, ten a second, like the rest of the pixel art
		if int(_pop_t * 10.0) != before:
			_over.queue_redraw()


func _zoom() -> float:
	return float(ZOOMS[_zoom_i])


# puts ground point (0, 0), the office, at ANCHOR
func center() -> void:
	_pan_to(ANCHOR - _view.focus * _zoom())


func set_zoom_step(i: int) -> void:
	_set_zoom(i)


func _set_zoom(i: int) -> void:
	_zoom_i = clampi(i, 0, ZOOMS.size() - 1)
	_sprite.scale = Vector2.ONE * _zoom()
	center()


# also used by tools/cloud/capture.gd to frame its shots
func pan_by(rel: Vector2) -> void:
	_pan_to(_pan + rel)


func _pan_to(at: Vector2) -> void:
	var size := _view.size * _zoom()
	var view := Rect2(0, VIEW_TOP, Ui.CANVAS.x, VIEW_BOTTOM - VIEW_TOP)
	_pan = at.clamp(view.position + view.size * 0.6 - size, view.position + view.size * 0.4)
	_pan = (_pan / _zoom()).round() * _zoom()
	_sprite.position = _pan
	_traffic.set_view(Rect2(-_pan / _zoom(), Ui.CANVAS / _zoom()))
	_over.queue_redraw()


func press(at: Vector2) -> bool:
	return Ui.BACK_RECT.has_point(at) or ZOOM_IN.has_point(at) or ZOOM_OUT.has_point(at)


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		back()
	elif ZOOM_IN.has_point(at):
		_set_zoom(_zoom_i + 1)
	elif ZOOM_OUT.has_point(at):
		_set_zoom(_zoom_i - 1)
	elif _picked >= 0 and CARD_X.has_point(at):
		_picked = -1
	elif _picked >= 0 and CARD.has_point(at):
		pass
	else:
		select(lot_under(at))
	_over.queue_redraw()


# the lot drawn under a canvas point, -1 for none or when the point is on the HUD
func lot_under(at: Vector2) -> int:
	if not is_drawn() or at.y < MAP_TOP or at.y > MAP_BOTTOM:
		return -1
	if _picked >= 0 and CARD.has_point(at):
		return -1
	if at.x > ZOOM_OUT.position.x - 8.0 and at.y < ZOOM_OUT.end.y + 8.0:
		return -1
	return _view.lot_at((at - _pan) / _zoom())


# selects a lot (-1 clears); a lot hidden under the card is slid up into view
func select(lot: int) -> void:
	_picked = lot
	if lot < 0:
		return
	var box: Rect2 = _view.lots[lot]["box"]
	var mid := _pan + box.get_center() * _zoom()
	if mid.y > CARD.position.y - 30.0:
		pan_by(Vector2(0, CARD.position.y - 120.0 - mid.y))
	_hover = lot_under(hot)


func is_card_open() -> bool:
	return _picked >= 0


# the canvas point over a lot's ground middle, for tools that point at lots like a player
func screen_of_lot(lot: int) -> Vector2:
	var poly: PackedVector2Array = _view.lots[lot]["poly"]
	return _pan + _view.project(Iso.centroid(poly)) * _zoom()


# lots by distance from the office, for tools
func lots_by_distance() -> Array[int]:
	var out: Array[int] = []
	for i in _view.lots.size():
		out.append(i)
	out.sort_custom(func(a: int, b: int) -> bool:
		return Iso.centroid(_view.lots[a]["poly"]).length() \
			< Iso.centroid(_view.lots[b]["poly"]).length())
	return out


func drag(_at: Vector2, rel: Vector2) -> void:
	pan_by(rel)


func hover(at: Vector2) -> void:
	hot = at
	_hover = lot_under(at)
	_over.queue_redraw()


func wheel(_at: Vector2, steps: int) -> void:
	_set_zoom(_zoom_i + steps)


func back() -> bool:
	if _picked >= 0:
		_picked = -1
		_over.queue_redraw()
		return true
	app.open_city(office["city"])
	return true


func _draw() -> void:
	Ui.backdrop(self)


# street names placed greedily, nearest the office first, so none overlap at this zoom
func _labels_for(i: int) -> Array:
	if _labels.has(i):
		return _labels[i]
	var z := float(ZOOMS[i])
	var spots := _street_spots.duplicate()
	# nearest the office first: that is where the player looks
	spots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["metres"] as Vector2).length() < (b["metres"] as Vector2).length())
	var placed: Array[Rect2] = []
	if _view.sign_box.size != Vector2.ZERO:
		placed.append(Rect2(_view.sign_box.position * z, _view.sign_box.size * z).grow(6.0))
	var out: Array = []
	for s: Dictionary in spots:
		var w := Ui.text_width(s["text"], Ui.TEXT, Ui.NARROW)
		# a street label may overhang its stretch of street a little, not run across the map
		if w > float(s["room"]) * z * 1.5:
			continue
		var at: Vector2 = s["at"] * z
		var slope := tan(float(s["angle"]))
		var sheared := absf(slope) <= SHEAR_MAX
		if not sheared:
			slope = 0.0
		# a sheared label is a thin slanted band: cover it with a few small boxes along it
		var boxes: Array[Rect2] = []
		var parts := 6
		var step := (w + 16.0) / parts
		for k in parts:
			var x := -w * 0.5 - 8.0 + step * (k + 0.5)
			boxes.append(Rect2(at + Vector2(x, x * slope) - Vector2(step * 0.5, 14.0),
				Vector2(step, 22.0)))
		var free := true
		for b in boxes:
			for q in placed:
				if q.intersects(b):
					free = false
					break
			if not free:
				break
		if free:
			placed.append_array(boxes)
			out.append({"at": at, "slope": slope, "text": s["text"], "w": w})
	_labels[i] = out
	return out


func _draw_over() -> void:
	if not is_drawn():
		Ui.text_in(_over, Rect2(0, 260, 600, 60), "Dibujando el barrio…", Ui.TEXT, Ui.MUTED)
	else:
		# at x1 the art is half size and the names would bury it
		if _zoom_i > 0:
			_draw_streets()
		_draw_outlines()
		_draw_pops()
	var city := CityDb.get_city(office["city"])
	Ui.header(_over, office.get("name", "Oficina"), true, hot)
	Ui.text(_over, Vector2(Ui.BACK_RECT.end.x + Ui.HEAD_GAP, 98), "%s · %d / %s tuyas" % [
		city.get("name", ""), _owned, Ui.count(_lot_count)], Ui.TEXT, Ui.MUTED)
	Ui.arrow(_over, ZOOM_OUT, "-", hot, _zoom_i == 0)
	Ui.arrow(_over, ZOOM_IN, "+", hot, _zoom_i == ZOOMS.size() - 1)
	# the office level and how much of the downloaded disc its radius covers
	var level: int = office.get("level", 1)
	var active := roundi(_view.active_radius)
	var full := roundi(float(office.get("max_radius", Rules.MAX_RADIUS)))
	Ui.text(_over, Vector2(LEVEL_BAR.position.x, LEVEL_BAR.position.y - 10),
		"Nv %d oficina" % level, Ui.TEXT, Ui.GOLD)
	Ui.text_right(_over, Vector2(LEVEL_BAR.end.x, LEVEL_BAR.position.y - 10),
		"Radio %d / %d m" % [active, full], Ui.TEXT, Ui.MUTED)
	Ui.bar(_over, LEVEL_BAR, float(active) / maxf(1.0, full))
	if _picked >= 0:
		_draw_card()
	Ui.footer(_over, "")


# the pointed-at lot in cyan (grey when out of reach), the selected one in gold, each ringed in
# ink so it reads on any ground
func _draw_outlines() -> void:
	if _hover >= 0 and _hover != _picked:
		var free: bool = _view.lots[_hover]["active"]
		_draw_ring(_hover, Ui.CYAN if free else Ui.MUTED)
	if _picked >= 0:
		_draw_ring(_picked, Ui.GOLD)


func _draw_ring(lot: int, color: Color) -> void:
	var rings := _view.outline(lot)
	var z := _zoom()
	for k in 2:
		var ink := color if k == 0 else Ui.VOID
		for r: Rect2 in rings[k]:
			_over.draw_rect(Rect2(_pan + r.position * z, r.size * z), ink)


# the selected lot's card: its address, zone and tier, size, and asking price or who has it
func _draw_card() -> void:
	var lot: Dictionary = _view.lots[_picked]
	var data: Dictionary = lot["data"]
	var mine: bool = data["id"] == _office_lot
	var owned: bool = mine or data.get("owned", false)
	Ui.panel(_over, CARD, Ui.GOLD)
	var x := CARD.position.x + 18.0
	var y := CARD.position.y + 36.0
	var room := CARD_X.position.x - x - 8.0
	var street: String = data.get("street", "")
	_fit_text(Vector2(x, y), street if street != "" else "Calle sin nombre", room, Ui.CREAM)
	var tier := clampi(int(data.get("built_tier", 0)), 0, TIERS.size() - 1)
	var kind: String = TIERS[tier]
	if data["zone"] == "industrial" and tier in [1, 2]:
		kind = "Naves"
	if mine:
		kind = "Tu oficina"
	var line2 := "%s · %s" % [ZONES.get(data["zone"], data["zone"]), kind]
	_fit_text(Vector2(x, y + 32.0), line2, room, Ui.MUTED)
	var line3 := "%s m2 · %d m de fachada" % [Ui.count(int(data.get("area_m2", 0))),
		roundi(float(data.get("front_m", 0.0)))]
	if data.get("corner", false):
		line3 += " · esquina"
	_fit_text(Vector2(x, y + 64.0), line3, CARD.end.x - x - 18.0, Ui.MUTED)
	var price := AreaBuilder.price_of(float(data.get("area_m2", 0)))
	Ui.coin(_over, Vector2(x, y + 84.0))
	Ui.text(_over, Vector2(x + 22.0, y + 98.0), "$" + Ui.count(price), Ui.TEXT, Ui.GOLD)
	var state := "En venta"
	var tone := Ui.GOLD
	if owned:
		state = "Tuyo"
		tone = Ui.CYAN
	elif not lot["active"]:
		state = "Fuera de tu radio"
		tone = Ui.BLOOD
	Ui.text_right(_over, Vector2(CARD.end.x - 18.0, y + 98.0), state, Ui.TEXT, tone)
	Ui.button(_over, CARD_X, "X", hot)


# one line of card text, narrowed and then cut short with an ellipsis to fit `room`
func _fit_text(at: Vector2, s: String, room: float, color: Color) -> void:
	var kind := Ui.BOLD
	if Ui.text_width(s, Ui.TEXT, kind) > room:
		kind = Ui.NARROW
	var line := s
	var cut := s.length()
	while cut > 3 and Ui.text_width(line, Ui.TEXT, kind) > room:
		cut -= 1
		line = s.left(cut).strip_edges() + "…"
	Ui.text(_over, at, line, Ui.TEXT, color, kind)


func _draw_pops() -> void:
	var spots := _view.pops
	for k in mini(spots.size(), 6):
		var t := fposmod(_pop_t - k * 0.7, POP_EVERY)
		if t > POP_LIFE:
			continue
		var px := maxf(2.0, _zoom())
		var rise := floorf(t * 10.0) / (POP_LIFE * 10.0) * POP_RISE * px * 0.5
		var w := Ui.micro_width("+$", px)
		var at := (_pan + spots[k] * _zoom() - Vector2(w * 0.5, rise)).round()
		Ui.micro(_over, at, "+$", Ui.GOLD, px, true)


# street names written along their streets: sheared to the street's slope, so the letters keep
# their vertical strokes and lie on the iso grid like painted road signs
func _draw_streets() -> void:
	var view := Rect2(8, 120, Ui.CANVAS.x - 16, 400)
	for l: Dictionary in _labels_for(_zoom_i):
		var at: Vector2 = (_pan + l["at"]).round()
		var half := Vector2(float(l["w"]) * 0.5, float(l["w"]) * 0.5 * float(l["slope"]))
		if not view.has_point(at - half) or not view.has_point(at + half):
			continue
		var w: float = l["w"]
		var slope: float = l["slope"]
		var shear := Transform2D(Vector2(1, slope), Vector2(0, 1), at)
		_over.draw_set_transform_matrix(shear)
		Ui.text(_over, Vector2(-roundf(w * 0.5 / 2.0) * 2.0, 7), l["text"], Ui.TEXT, Ui.CREAM,
			Ui.NARROW, false)
		_over.draw_set_transform_matrix(Transform2D.IDENTITY)
