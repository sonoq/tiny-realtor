class_name OfficeView
extends Screen

# One office's saved area, style A: BlockView draws the whole disc once into a texture (a frame
# or two after opening) and this screen shows it through a sprite, so panning only moves the
# sprite. Drag to pan, wheel or - + to zoom (each art pixel 1, 2 or 3 screen pixels; 2 is the
# mockup's). Over it, the HUD of the mockup: back button and the neighbourhood's name, how many
# lots are yours, the office level with its radius bar and the OpenStreetMap credit. No street
# names are written on the map: clicking a street, a pavement or other open ground shows a plate
# with the nearest street's name and kind for a few seconds (or until the next click). Pointing at a lot outlines everything it shows (BlockView's pick pass:
# cyan, grey when it is outside the office's radius); clicking it selects it (gold) and opens a
# card with its street, zone, size, tier and asking price; Esc or the card's X closes the card.
# A saved v2 area (small plots) is re-parcelled into lots when it is opened, and saved back.
# The office has no building: a gold pin marks where it was placed; pointing at it names it and
# clicking it opens the office tab. The game itself (money, cards with buy / build buttons,
# markers, the bank and the office tab) is OfficePlay, a layer drawn over this one that gets
# every input first; the lots are drawn as the
# game has them (Game.apply) and one lot is redrawn when it changes (BlockView.redraw_lot).
# Traffic drives cars over the drawing, as a child of its sprite; it hides them behind whatever
# the drawing's depth pass holds, which lot redraws keep up to date, and follows a level-up.

const ZOOMS: Array[int] = [1, 2, 3]
const START_ZOOM := 1
const VIEW_TOP := 0.0
const VIEW_BOTTOM := Ui.CANVAS.y
# where on screen the office sits: a little below the middle, under the HUD's title
const ANCHOR := Vector2(300, 330)
# how long a clicked street's name plate stays up (ms)
const STREET_SHOW_MS := 4000
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

var _view: BlockView
var _sprite: Sprite2D
var _over: Node2D
var _zoom_i := START_ZOOM
var _pan := Vector2.ZERO
var _stats: Dictionary = {}
var _lot_count := 0
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
# the clicked street's plate: {"name", "kind", "at" (ground metres on its line), "until" (ms)},
# empty when none is up
var street := {}
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
	_view.active_radius = game.radius(id)
	if not _view.set_block(block):
		return false
	_stats = block.get("stats", {})
	_lot_count = block["plots"].size()
	_play = OfficePlay.new()
	_play.setup(self, game, id, block)
	# the office's free lot learns its multipliers from the area (a new office, an old save)
	if game.fill_lots(id, _play.infos):
		game.save()
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


# a full-window panel (bank, office tab) hides the map: the cars wait under it and drive on when
# it closes
func _process(_delta: float) -> void:
	if not street.is_empty() and Time.get_ticks_msec() > int(street["until"]):
		street = {}
		_over.queue_redraw()
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
	# once: a minigame acts on the press
	var own := _play.press(at)
	_press_ui = own or _play.over_ui(at)
	return own or Ui.BACK_RECT.has_point(at)


func click(at: Vector2) -> void:
	# any click puts the street plate away; a click on open ground may bring up another
	street = {}
	if _play.click(at):
		_over.queue_redraw()
		return
	if Ui.BACK_RECT.has_point(at):
		back()
	else:
		var lot := lot_under(at)
		select(lot)
		if lot < 0:
			name_street(at)
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


# true when a canvas point is on the office's pin, or close enough round it to be easy to hit at
# any zoom, but not on something standing in front of it
func on_mark(at: Vector2) -> bool:
	if not is_drawn() or at.y < MAP_TOP or at.y > MAP_BOTTOM:
		return false
	if at.x > MAP_RIGHT and at.y < BUTTONS_BOTTOM:
		return false
	var box := _view.mark_box
	var grow := maxf(0.0, (Ui.MIN_HIT / _zoom() - minf(box.size.x, box.size.y)) * 0.5)
	return _view.points_at_mark((at - _pan) / _zoom(), grow)


# the top middle of the office's pin on the canvas
func mark_on_screen() -> Vector2:
	var box := _view.mark_box
	return _pan + Vector2(box.get_center().x, box.position.y) * _zoom()


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


func drag(at: Vector2, rel: Vector2) -> void:
	if _play.blocks_map():
		_play.drag(at)
	elif not _press_ui:
		pan_by(rel)


func hover(at: Vector2) -> void:
	hot = at
	_play.hover(at)
	_hover = -1 if _play.blocks_map() or on_mark(at) or _play.over_ui(at) else lot_under(at)
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


# a click on open ground (a street, a pavement, a park): the nearest street's name plate
func name_street(at: Vector2) -> void:
	street = {}
	if not is_drawn() or _play.blocks_map() or at.y < MAP_TOP or at.y > MAP_BOTTOM \
			or at.x > MAP_RIGHT and at.y < BUTTONS_BOTTOM:
		return
	var hit := StreetNames.nearest(_block, ground_at(at))
	if hit.is_empty():
		return
	var name: String = hit["name"]
	street = {"name": name if name != "" else "Sin nombre", "kind": StreetNames.kind(hit["road"]),
		"at": hit["at"], "until": Time.get_ticks_msec() + STREET_SHOW_MS}


# the ground point (metres) under a canvas point, on the ground plane
func ground_at(at: Vector2) -> Vector2:
	var q := (at - _pan) / _zoom() - _view.project(Vector2.ZERO)
	var sum := q.x / Iso.S
	var diff := 2.0 * q.y / Iso.S
	return Vector2((sum + diff) * 0.5, (sum - diff) * 0.5)


func _draw_over() -> void:
	if not is_drawn():
		Ui.text_in(_over, Rect2(0, 260, 600, 60), "Dibujando el barrio…", Ui.TEXT, Ui.MUTED)
	else:
		_draw_outlines()
		_draw_street()
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


# the clicked street's plate: its kind in the micro font over its name, on a dark chip just
# above the spot on the street (below it when there is no room), a short stem down to it
func _draw_street() -> void:
	if street.is_empty() or _play.blocks_map():
		return
	var foot := (_pan + _view.project(street["at"]) * _zoom()).round()
	if foot.y < MAP_TOP or foot.y > MAP_BOTTOM:
		return
	var name: String = street["name"]
	var size := Ui.TEXT
	if Ui.text_width(name, size, Ui.NARROW) > 540.0:
		name = StreetNames.short(name)
	var kind := StreetNames.plain(street["kind"])
	var w := maxf(Ui.text_width(name, size, Ui.NARROW), Ui.micro_width(kind)) + 24.0
	var h := 50.0
	var x := clampf(foot.x - w * 0.5, 8.0, Ui.CANVAS.x - 8.0 - w)
	var y := foot.y - h - 14.0
	var stem := Rect2(foot.x - 1.0, y + h, 2.0, foot.y - y - h)
	if y < MAP_TOP:
		y = foot.y + 14.0
		stem = Rect2(foot.x - 1.0, foot.y, 2.0, y - foot.y)
	var r := Rect2(roundf(x), roundf(y), roundf(w), h)
	_over.draw_rect(stem.grow(1.0), Ui.VOID)
	_over.draw_rect(stem, Ui.GOLD)
	_over.draw_rect(Rect2(foot - Vector2(3, 3), Vector2(6, 6)), Ui.VOID)
	_over.draw_rect(Rect2(foot - Vector2(2, 2), Vector2(4, 4)), Ui.GOLD)
	Ui.chip(_over, r.grow(2.0), Ui.VOID, Ui.VOID)
	Ui.chip(_over, r, Ui.PLATE, Ui.RIM_DIM)
	Ui.micro(_over, r.position + Vector2(12, 8), kind, Ui.GOLD)
	Ui.text(_over, r.position + Vector2(12, 41), name, size, Ui.CREAM, Ui.NARROW, false)
