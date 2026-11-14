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
# The game itself (money, cards with buy / build buttons, markers, the bank and the manager) is
# OfficePlay, a layer drawn over this one that gets every input first; the lots are drawn as the
# game has them (Game.apply) and one lot is redrawn when it changes (BlockView.redraw_lot).
# Traffic drives cars over the drawing, as a child of its sprite; it hides them behind whatever
# the drawing's depth pass holds, which lot redraws keep up to date, and follows a level-up.

const ZOOMS: Array[int] = [1, 2, 3]
const START_ZOOM := 1
const VIEW_TOP := 0.0
const VIEW_BOTTOM := Ui.CANVAS.y
# where on screen the office sits: a little below the middle, under the HUD's title
const ANCHOR := Vector2(300, 330)
# how street names show (StreetNames: MICRO A, PAINTED B, PLATES C, HOVER D); Oscar's pick
const LABEL_STYLE := StreetNames.PAINTED
# street names are sheared along the street when it runs at most this steep on screen
const SHEAR_MAX := 0.75
# at most this many street plates at once (PLATES)
const PLATES_MAX := 5
# the pointer names a street this close to it, in screen pixels (HOVER)
const HOVER_REACH := 14.0
# the selected lot's card (OfficePlay draws it)
const CARD := OfficePlay.CARD
# the map takes pointing only between the header and the next-move bar, left of the buttons
const MAP_TOP := 110.0
const MAP_BOTTOM := 480.0
const MAP_RIGHT := 528.0
const BUTTONS_BOTTOM := 330.0
# where the title must end, left of the money
const TITLE_RIGHT := 360.0
const TIERS: Array[String] = ["Solar", "Casas", "Urbanización", "Bloque de pisos", "Torres",
	"Rascacielos"]
const ZONES := {"residential": "Residencial", "commercial": "Comercial",
	"industrial": "Industrial"}

var office: Dictionary = {}
var game: Game
# the street names' look in use; tools that compare the options switch it
static var labels: int = LABEL_STYLE

var _view: BlockView
var _sprite: Sprite2D
var _over: Node2D
var _zoom_i := START_ZOOM
var _pan := Vector2.ZERO
var _stats: Dictionary = {}
var _street_spots: Array[Dictionary] = []
var _lot_count := 0
var _office_lot := ""
var _block: Dictionary = {}
var _play: OfficePlay
# the drawing being made after a level-up, shown once it is ready, and the lots that changed
# while it was being made (redrawn on it once it is in)
var _next_view: BlockView
var _late: Array[int] = []
# the press started on the game's buttons or cards: dragging from there does not pan
var _press_ui := false
# the lot under the pointer and the selected one, -1 for none
var _hover := -1
var _picked := -1
# the street names placed for the view as it is ("zoom|pan" -> labels), and every named
# street's straight runs in drawing pixels ([short name, a, b]) for the pointer to name one
var _labels := {}
var _labels_key := ""
var _runs_px: Array = []
# the street under the pointer (HOVER): its short name and where on it the pointer is (screen)
var _hover_name := ""
var _hover_at := Vector2.ZERO
var _traffic: Traffic
# the traffic is paused under a panel
var _paused := false


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
	if game == null:
		game = Game.new("")
		game.fresh(game.now())
	var id: String = meta["id"]
	# an office from before the game existed starts now, with its own lot
	if not game.has_office(id):
		game.add_office(id, block.get("office_plot", ""))
	game.state["last_office"] = id
	game.apply(id, block)
	_block = block
	_view = BlockView.new()
	_view.live = true
	_view.names = labels == StreetNames.PAINTED
	_view.active_radius = game.radius(id)
	if not _view.set_block(block):
		return false
	_stats = block.get("stats", {})
	_office_lot = block.get("office_plot", "")
	_lot_count = block["plots"].size()
	_street_spots = _view.street_labels()
	for run: Array in StreetNames.runs(block):
		_runs_px.append([StreetNames.short(run[0]), _view.project(run[1]), _view.project(run[2])])
	_play = OfficePlay.new()
	_play.setup(self, game, id, block)
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
	add_child(_play)
	_view.drawn.connect(_on_drawn)
	add_child(_view)
	_set_zoom(_zoom_i)


# a full-window panel (bank, manager) hides the map: the cars wait under it and drive on when
# it closes
func _process(_delta: float) -> void:
	var hidden := _play.panel_kind() != ""
	if hidden != _paused:
		_paused = hidden
		_traffic.frozen = hidden
		_traffic.visible = not hidden


func _on_drawn() -> void:
	_sprite.texture = _view.texture
	_traffic.attach(_view, _view.active_radius)
	print("OfficeView: %s drawn %dx%d, build %d ms, gpu %d ms" % [office.get("id", ""),
		roundi(_view.size.x), roundi(_view.size.y), _view.build_ms, _view.draw_ms])
	_over.queue_redraw()


func _zoom() -> float:
	return float(ZOOMS[_zoom_i])


# puts ground point (0, 0), the office, at ANCHOR
func center() -> void:
	_pan_to(ANCHOR - _view.focus * _zoom())


func set_zoom_step(i: int) -> void:
	_set_zoom(i)


func zoom_step() -> int:
	return _zoom_i


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
	if _play != null:
		_play.queue_redraw()


func press(at: Vector2) -> bool:
	_press_ui = _play.press(at) or _play.over_ui(at)
	return _play.press(at) or Ui.BACK_RECT.has_point(at)


func click(at: Vector2) -> void:
	if _play.click(at):
		_over.queue_redraw()
		return
	if Ui.BACK_RECT.has_point(at):
		back()
	else:
		select(lot_under(at))
	_over.queue_redraw()
	_play.queue_redraw()


# the lot drawn under a canvas point, -1 for none or when the point is on the HUD
func lot_under(at: Vector2) -> int:
	if not is_drawn() or at.y < MAP_TOP or at.y > MAP_BOTTOM:
		return -1
	if _picked >= 0 and CARD.has_point(at):
		return -1
	if at.x > MAP_RIGHT and at.y < BUTTONS_BOTTOM:
		return -1
	return _view.lot_at((at - _pan) / _zoom())


# selects a lot (-1 clears); a lot hidden under the card is slid up into view
func select(lot: int) -> void:
	_picked = lot
	_over.queue_redraw()
	if _play != null:
		_play.queue_redraw()
	if lot < 0:
		return
	var box: Rect2 = _view.lots[lot]["box"]
	var mid := _pan + box.get_center() * _zoom()
	if mid.y > CARD.position.y - 30.0:
		pan_by(Vector2(0, CARD.position.y - 120.0 - mid.y))
	_hover = lot_under(hot)


# pans so a lot's ground middle sits in the open part of the map, above where a card opens
func focus_lot(lot: int) -> void:
	if lot < 0 or lot >= _view.lots.size():
		return
	pan_by(Vector2(270, 200) - screen_of_lot(lot))


func is_card_open() -> bool:
	return _picked >= 0


func picked() -> int:
	return _picked


# --- for OfficePlay ------------------------------------------------------------------------------

# the lots as the drawing laid them out (BlockView.lots)
var lots: Array[Dictionary]:
	get:
		return _view.lots


# a point of the drawing (low-res pixels) on the canvas
func drawing_to_screen(p: Vector2) -> Vector2:
	return _pan + p * _zoom()


func redraw_lot(i: int) -> void:
	if _next_view != null and not i in _late:
		_late.append(i)
	_view.redraw_lot(i)


# the office levelled up: the whole area is drawn again with the new radius (lamps, people,
# sale signs, the dim outside it all change), off screen, and swapped in when it is ready
func relevel(radius: float) -> void:
	if _next_view != null:
		_next_view.queue_free()
	var nv := BlockView.new()
	nv.live = true
	nv.names = _view.names
	nv.active_radius = radius
	if not nv.set_block(_block):
		return
	_next_view = nv
	nv.drawn.connect(func() -> void:
		if _next_view != nv:
			return
		var old := _view
		_view = nv
		_next_view = null
		_sprite.texture = nv.texture
		# the cars now hide behind the new drawing and fade outside the new radius
		_traffic.attach(nv, radius)
		_outline_cache_clear()
		old.queue_free()
		for i in _late:
			_view.redraw_lot(i)
		_late.clear()
		print("OfficeView: %s redrawn for radius %d m, build %d ms, gpu %d ms" % [
			office.get("id", ""), roundi(radius), nv.build_ms, nv.draw_ms])
		_over.queue_redraw())
	add_child(nv)


func _outline_cache_clear() -> void:
	_hover = lot_under(hot)
	_play.queue_redraw()


# works that finished while this office is open (from App)
func on_built(lot_id: String, tier: int) -> void:
	_play.on_built(lot_id, tier)


func on_started(lot_id: String) -> void:
	_play.on_started(lot_id)


func play() -> OfficePlay:
	return _play


# brings the game up to date before an action (after a sleep the first click can come before
# the next tick)
func sync() -> void:
	if app != null:
		app.tick_game()


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
	if not _play.blocks_map() and not _press_ui:
		pan_by(rel)


func hover(at: Vector2) -> void:
	hot = at
	_play.hover(at)
	_hover = -1 if _play.blocks_map() else lot_under(at)
	if labels != StreetNames.MICRO:
		_street_under(at)
	_over.queue_redraw()


func wheel(_at: Vector2, steps: int) -> void:
	if not _play.blocks_map():
		_set_zoom(_zoom_i + steps)


func back() -> bool:
	if _play.back():
		return true
	if _picked >= 0:
		_picked = -1
		_over.queue_redraw()
		return true
	app.game.save()
	app.open_city(office["city"])
	return true


func _draw() -> void:
	Ui.backdrop(self)


# the street names for the view as it is: each name once, the ones nearest the middle of the
# view first, none overlapping another or the office's sign, all inside the map (A: along the
# street, sheared; C: flat plates, a few)
func _labels_now() -> Array:
	var key := "%d|%d|%d" % [_zoom_i, roundi(_pan.x), roundi(_pan.y)]
	if key == _labels_key:
		return _labels[key]
	var z := _zoom()
	var mid := Vector2(Ui.CANVAS.x * 0.5, (MAP_TOP + MAP_BOTTOM) * 0.5)
	var view := Rect2(8, MAP_TOP + 4, Ui.CANVAS.x - 16, MAP_BOTTOM - MAP_TOP - 8)
	var spots := _street_spots.duplicate()
	spots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (_pan + a["at"] * z).distance_to(mid) < (_pan + b["at"] * z).distance_to(mid))
	var placed: Array[Rect2] = []
	if _view.sign_box.size != Vector2.ZERO:
		placed.append(Rect2(_pan + _view.sign_box.position * z, _view.sign_box.size * z).grow(6.0))
	var named := {}
	var out: Array = []
	for s: Dictionary in spots:
		if named.has(s["text"]) or s["text"] == "":
			continue
		if labels == StreetNames.PLATES and out.size() >= PLATES_MAX:
			break
		var w := Ui.micro_width(s["text"])
		var at: Vector2 = (_pan + s["at"] * z).round()
		var slope := tan(float(s["angle"]))
		var boxes: Array[Rect2] = []
		# where it must find street, not a lot or a building (the pick image)
		var feet: Array[Vector2] = [at]
		if labels == StreetNames.PLATES:
			slope = 0.0
			boxes.append(Rect2(at - Vector2(w * 0.5 + 6.0, 9.0), Vector2(w + 12.0, 18.0)))
		else:
			# a name may overhang its stretch of street a little, not run across the map, and
			# follows only a street it can lie along
			if w > float(s["room"]) * z * 1.3 or absf(slope) > SHEAR_MAX:
				continue
			for k in 7:
				var x := (k / 6.0 - 0.5) * w
				feet.append(at + Vector2(x, x * slope))
			# a sheared name is a thin slanted band: a few small boxes along it
			var parts := 5
			var step := (w + 8.0) / parts
			for k in parts:
				var x := -w * 0.5 - 4.0 + step * (k + 0.5)
				boxes.append(Rect2(at + Vector2(x, x * slope) - Vector2(step * 0.5, 8.0),
					Vector2(step, 16.0)))
		var free := true
		for b in boxes:
			free = free and view.encloses(b)
			for q in placed:
				free = free and not q.intersects(b)
		# a tree or a roof corner over a bit of it is fine, a building across it is not
		var off := 0
		for f in feet:
			off += 1 if _view.lot_at((f - _pan) / z) >= 0 else 0
		free = free and off <= feet.size() / 4
		if free:
			placed.append_array(boxes)
			named[s["text"]] = true
			out.append({"at": at, "slope": slope, "text": s["text"], "w": w})
	_labels.clear()
	_labels[key] = out
	_labels_key = key
	return out


# the named street nearest the pointer, if it is within HOVER_REACH (HOVER)
func _street_under(at: Vector2) -> void:
	_hover_name = ""
	if not is_drawn() or _play.blocks_map() or at.y < MAP_TOP or at.y > MAP_BOTTOM:
		return
	var z := _zoom()
	var best := HOVER_REACH
	for run: Array in _runs_px:
		var q := Geometry2D.get_closest_point_to_segment(at, _pan + run[1] * z, _pan + run[2] * z)
		var d := q.distance_to(at)
		if d < best and run[0] != "":
			best = d
			_hover_name = run[0]
			_hover_at = q


func _draw_over() -> void:
	if not is_drawn():
		Ui.text_in(_over, Rect2(0, 260, 600, 60), "Dibujando el barrio…", Ui.TEXT, Ui.MUTED)
	else:
		_draw_outlines()
		_draw_names()
	var city := CityDb.get_city(office["city"])
	Ui.header(_over, office.get("name", "Oficina"), true, hot, TITLE_RIGHT)
	Ui.text(_over, Vector2(Ui.BACK_RECT.end.x + Ui.HEAD_GAP, 98), "%s · %d / %s tuyos" % [
		city.get("name", ""), game.owned_count(office["id"]), Ui.count(_lot_count)], Ui.TEXT,
		Ui.MUTED, Ui.NARROW)
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


# the street names over the map, as LABEL_STYLE says (PAINTED ones are in the drawing itself)
func _draw_names() -> void:
	match labels:
		StreetNames.MICRO, StreetNames.PLATES:
			# at x1 the art is half size and the names would bury it
			if _zoom_i == 0:
				return
			var shown := {}
			for l: Dictionary in _labels_now():
				shown[l["text"]] = true
				if labels == StreetNames.PLATES:
					_plate(l["at"], l["text"])
					continue
				# sheared to the street's slope, so the letters keep their vertical strokes
				var shear := Transform2D(Vector2(1, l["slope"]), Vector2(0, 1), l["at"])
				_over.draw_set_transform_matrix(shear)
				Ui.micro(_over, Vector2(-roundf(float(l["w"]) * 0.25) * 2.0, -4), l["text"],
					Ui.CREAM, 2.0, true)
				_over.draw_set_transform_matrix(Transform2D.IDENTITY)
			# the street under the pointer gets its plate too
			if labels == StreetNames.PLATES and _hover_name != "" and not shown.has(_hover_name):
				_plate((_hover_at + Vector2(0, -22)).round(), _hover_name)
		_:
			# painted names (in the drawing) and the hover look: the street under the pointer
			if _hover_name != "":
				_plate((_hover_at + Vector2(0, -22)).round(), _hover_name)


# a street-name plate: a dark chip with a thin rim, the name in cream, centred on `at`
func _plate(at: Vector2, text: String) -> void:
	var w := Ui.micro_width(text)
	var r := Rect2((at - Vector2(roundf(w * 0.25) * 2.0 + 6.0, 9.0)).round(), Vector2(w + 12.0, 18.0))
	Ui.chip(_over, r.grow(2.0), Ui.VOID, Ui.VOID)
	Ui.chip(_over, r, Ui.PLATE, Ui.RIM_DIM)
	Ui.micro(_over, r.position + Vector2(6, 4), text, Ui.CREAM)
