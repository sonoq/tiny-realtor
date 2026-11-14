class_name OfficePlay
extends Node2D

# The game over an office's map (docs/GAMEPLAY.md): OfficeView shows and pans the drawing and
# points at lots; this layer, drawn above it, is everything with money in it. Top right the
# cash and the rent per minute (and the debt), the bank and manager buttons under the zoom; on
# the map price tags over lots for sale, gold arrows over lots that can be built on now, a bar
# over each works and "+$" pops over the roofs while the pointer is over the window; at the
# bottom the next move and the office level bar. The selected lot's card buys, builds and
# borrows; the office's own card levels the office up and switches its builder on. A purchase
# or works can be undone for a few seconds. The bank and the manager are full-window panels
# (BankPanel, TeamPanel); coming back after a while shows what was earned away.
# OfficeView hands it every input first (press / click / hover / back); true = taken.

const MONEY_AT := Vector2(588, 40)
const ZOOM_IN := Rect2(536, 88, 52, 52)
const ZOOM_OUT := Rect2(536, 146, 52, 52)
const BANK_BTN := Rect2(536, 212, 52, 52)
const TEAM_BTN := Rect2(536, 270, 52, 52)
const NEXT := Rect2(12, 484, 576, 46)
const LEVEL_BAR := Rect2(12, 558, 576, 16)
const LEVEL_ZONE := Rect2(0, 534, 600, 44)
const CARD := Rect2(12, 286, 576, 244)
const CARD_X := Rect2(528, 294, 52, 52)
const MAIN_BTN := Rect2(30, 432, 340, 52)
const SIDE_BTN := Rect2(380, 432, 190, 52)
const TOAST := Rect2(12, 112, 516, 48)
const UNDO_BTN := Rect2(376, 114, 148, 44)
const AWAY := Rect2(60, 150, 480, 300)
const AWAY_OK := Rect2(200, 384, 200, 52)
const UNDO_S := 6.0
const TOAST_S := 4.0
const POP_EVERY := 3.0
const POP_LIFE := 1.6
const POP_RISE := 18.0
const MAX_TAGS := 10
const MAX_POPS := 8

var view: OfficeView
var game: Game
var id := ""
var block: Dictionary
var infos: Array[Dictionary] = []
# lot id -> index in plots[] / infos / view.lots
var index := {}
var hot := Vector2(-100, -100)

var _panel: RefCounted = null
var _toast := ""
var _toast_until := 0.0
# important messages (level-ups, a new manager) waiting for the toast; a minor one ("¡Comprado!")
# just replaces whatever minor one is showing
var _toasts: Array[String] = []
var _toast_big := false
var _undo := {}
var _clock := 0.0
var _pop_t := 0.0
var _best := {}
var _best_t := -1.0
var _shown_level := 1


func setup(the_view: OfficeView, the_game: Game, office_id: String, area: Dictionary) -> void:
	view = the_view
	game = the_game
	id = office_id
	block = area
	infos = Economy.lot_infos(block)
	for i in infos.size():
		index[infos[i]["id"]] = i
	_shown_level = game.level(id)


func _process(delta: float) -> void:
	_clock += delta
	_pop_t += delta
	for n in game.news:
		say(n, true)
	game.news.clear()
	if _clock >= _toast_until and not _toasts.is_empty():
		_toast = _toasts.pop_front()
		_toast_until = _clock + TOAST_S
		_toast_big = true
	# a tenth of a second is enough for the counters and the pixel-stepped pops
	if int(_clock * 10.0) != int((_clock - delta) * 10.0):
		queue_redraw()
		if _panel != null:
			_panel.call("tick")


func _now() -> float:
	return game.now()


func say(text: String, big: bool = false) -> void:
	if _clock < _toast_until and _toast_big:
		if big:
			_toasts.append(text)
		return
	_toast = text
	_toast_until = _clock + TOAST_S
	_toast_big = big
	queue_redraw()


# --- input -------------------------------------------------------------------------------------

func blocks_map() -> bool:
	return _panel != null or not game.away.is_empty()


func press(at: Vector2) -> bool:
	if blocks_map():
		return true
	return ZOOM_IN.has_point(at) or ZOOM_OUT.has_point(at) or _buttons_shown() \
		and (BANK_BTN.has_point(at) or TEAM_BTN.has_point(at)) \
		or _undo_visible() and UNDO_BTN.has_point(at)


# the bank and manager buttons hide under an open card
func _buttons_shown() -> bool:
	return not view.is_card_open()


func hover(at: Vector2) -> void:
	hot = at
	if _panel != null:
		_panel.set("hot", at)
	queue_redraw()


func click(at: Vector2) -> bool:
	if not game.away.is_empty():
		game.away = {}
		queue_redraw()
		return true
	if _panel != null:
		_panel.call("click", at)
		if _panel.call("wants_close"):
			_panel = null
		_best_t = -1.0
		queue_redraw()
		return true
	if _undo_visible() and UNDO_BTN.has_point(at):
		_do_undo()
		return true
	if ZOOM_IN.has_point(at):
		view.set_zoom_step(view.zoom_step() + 1)
		return true
	if ZOOM_OUT.has_point(at):
		view.set_zoom_step(view.zoom_step() - 1)
		return true
	if _buttons_shown() and BANK_BTN.has_point(at):
		open_panel("bank")
		return true
	if _buttons_shown() and TEAM_BTN.has_point(at):
		open_panel("team")
		return true
	if view.is_card_open() and CARD.has_point(at):
		if CARD_X.has_point(at):
			view.select(-1)
		elif MAIN_BTN.has_point(at):
			_card_action(false)
		elif SIDE_BTN.has_point(at):
			_card_action(true)
		queue_redraw()
		return true
	if not view.is_card_open() and NEXT.has_point(at):
		_follow_best()
		return true
	if LEVEL_ZONE.has_point(at):
		_select_office()
		return true
	return false


func back() -> bool:
	if not game.away.is_empty():
		game.away = {}
		return true
	if _panel != null:
		if not _panel.call("back"):
			_panel = null
		queue_redraw()
		return true
	return false


func open_panel(kind: String) -> void:
	if kind == "bank":
		_panel = BankPanel.new(game)
	else:
		_panel = TeamPanel.new(game, id)
	_panel.set("hot", hot)
	queue_redraw()


func panel_kind() -> String:
	if _panel is BankPanel:
		return "bank"
	if _panel is TeamPanel:
		return "team"
	return ""


# --- actions -----------------------------------------------------------------------------------

func _lot_id(i: int) -> String:
	return infos[i]["id"]


func _is_office(i: int) -> bool:
	return _lot_id(i) == block.get("office_plot", "")


func _select_office() -> void:
	var i: int = index.get(block.get("office_plot", ""), -1)
	if i >= 0:
		view.focus_lot(i)
		view.select(i)
	queue_redraw()


# what the card's buttons do: [label, enabled, callable, note] for the main and side button
func _card_buttons(i: int) -> Array:
	var lid := _lot_id(i)
	var info := infos[i]
	var none := ["", false, Callable(), ""]
	if _is_office(i):
		var lv := game.level(id)
		var main := none
		if lv < Economy.max_level():
			var c := Economy.level_cost(lv)
			var why := game.can_level_up(id)
			main = ["SUBIR A NV %d · %s" % [lv + 1, Economy.money(c)], why == "",
				_level_up, _short(why, c)]
		else:
			main = ["NIVEL MÁXIMO", false, Callable(), ""]
		var side := none
		if game.auto_open(id):
			side = ["AUTO: " + ("SÍ" if game.auto_on(id) else "NO"), true,
				func() -> void:
					game.set_auto(id, not game.auto_on(id))
					game.save()
					if game.auto_on(id):
						say("Tu oficina construirá sola")
					_after_change(-1), ""]
		else:
			side = ["AUTO EN NV %d" % Economy.AUTO_LEVEL, false, Callable(), ""]
		return [main, side]
	if not game.owns(id, lid):
		var price := game.buy_price(id, info)
		var why := game.can_buy(id, info)
		var main := ["COMPRAR " + Economy.money(price), why == "", _buy.bind(i), _short(why, price)]
		if why == "Fuera de tu radio":
			main = ["FUERA DE TU RADIO", false, Callable(), "Sube la oficina para llegar"]
		return [main, _loan_button(price, _buy.bind(i)) if why.begins_with("Te faltan") else none]
	var l := game.lot(id, lid)
	if l.has("end"):
		return [["EN OBRAS · " + Economy.duration(float(l["end"]) - _now()), false, Callable(),
			""], none]
	if int(l["t"]) >= int(l["mx"]):
		var cap := "AL MÁXIMO" if int(l["mx"]) >= 5 else "NO CABE MÁS"
		return [[cap, false, Callable(), "Este terreno no admite más"], none]
	var to := int(l["t"]) + 1
	var c := game.build_cost(id, l, to)
	var why := game.can_build(id, lid, to)
	var main := ["%s · %s" % [_tier_caps(to), Economy.money(c)], why == "", _build.bind(i, to),
		_short(why, c) if why != "" else "Tarda " + Economy.duration(game.build_time(id,
		int(l["t"]), to))]
	var top := game.best_target(id, lid)
	var side := none
	if why == "" and top > to:
		side = ["HASTA " + _tier_caps(top, true), true, _build.bind(i, top), ""]
	elif why.begins_with("Te faltan"):
		side = _loan_button(c, _build.bind(i, to))
	return [main, side]


# the card's side button when money is short: borrow just what is missing (the cheapest loan
# that has room), then do it
func _loan_button(cost: float, then: Callable) -> Array:
	var need := ceilf((cost - game.money()) / 1000.0) * 1000.0
	for def in Economy.LOANS:
		if game.loan_room(def["id"]) >= need and game.can_borrow(def["id"], need) == "":
			var kind: String = def["id"]
			return ["PRESTAR " + Economy.money(need), true, func() -> void:
				if game.borrow(kind, need) == "":
					say("Préstamo %s: %s" % [def["name"], Economy.money(need)])
					then.call(), ""]
	return ["", false, Callable(), ""]


func _card_action(side: bool) -> void:
	if view.picked() < 0:
		return
	var b: Array = _card_buttons(view.picked())[1 if side else 0]
	if b[1] and (b[2] as Callable).is_valid():
		(b[2] as Callable).call()


func _remember(i: int) -> void:
	_undo = {"state": game.state.duplicate(true), "lot": i, "until": _clock + UNDO_S}


func _buy(i: int) -> void:
	_remember(i)
	if game.buy(id, infos[i]) == "":
		say("¡Comprado!")
		_after_change(i)
	else:
		_undo = {}


func _build(i: int, to: int) -> void:
	_remember(i)
	if game.build(id, _lot_id(i), to) == "":
		say("Obras: %s" % Economy.TIER_NAMES[to])
		_after_change(i)
	else:
		_undo = {}


func _level_up() -> void:
	if game.level_up(id) != "":
		return
	_undo = {}
	var lv := game.level(id)
	say("¡Oficina Nv %d! Radio %d m" % [lv, roundi(game.radius(id))], true)
	game.save()
	view.relevel(game.radius(id))


func _undo_visible() -> bool:
	return not _undo.is_empty() and _clock < float(_undo["until"])


func _do_undo() -> void:
	var i: int = _undo["lot"]
	game.state = _undo["state"]
	_undo = {}
	say("Deshecho")
	_after_change(i)


# saves, redraws the lot (if any) and refreshes the hints
func _after_change(i: int) -> void:
	game.save()
	_best_t = -1.0
	if i >= 0:
		refresh_lot(i)
	queue_redraw()


# writes the game's state of a lot into the drawing's plot and redraws that lot
func refresh_lot(i: int) -> void:
	var plot: Dictionary = block["plots"][i]
	var l := game.lot(id, _lot_id(i))
	if l.is_empty():
		plot["owned"] = false
		plot.erase("works")
		plot["built_tier"] = int(infos[i]["base_tier"])
	elif not l.get("office", false):
		plot["owned"] = true
		plot["built_tier"] = int(l["t"])
		if l.has("to"):
			plot["works"] = int(l["to"])
		else:
			plot.erase("works")
	plot["levels"] = BlockBaker.levels_for(plot["id"], int(plot["built_tier"]))
	view.redraw_lot(i)


# works that finished (App hands them over from Game.advance)
func on_built(lot_id: String, tier: int) -> void:
	var i: int = index.get(lot_id, -1)
	if i < 0:
		return
	refresh_lot(i)
	_best_t = -1.0
	say("¡%s terminado!" % Economy.TIER_NAMES[tier] if tier in [3] \
		else "¡%s terminadas!" % Economy.TIER_NAMES[tier] if tier in [1, 4] \
		else "¡%s terminada!" % Economy.TIER_NAMES[tier])


# works the office's builder started on its own
func on_started(lot_id: String) -> void:
	var i: int = index.get(lot_id, -1)
	if i >= 0:
		refresh_lot(i)


func _follow_best() -> void:
	var b := _best_move()
	match b.get("kind", ""):
		"buy", "build":
			var i: int = index.get(b["info"]["id"] if b["kind"] == "buy" else b["lot"], -1)
			if i >= 0:
				view.focus_lot(i)
				view.select(i)
		"level":
			_select_office()
		"hire":
			open_panel("team")
	queue_redraw()


func _best_move() -> Dictionary:
	if _best_t < 0.0 or _clock - _best_t > 1.0:
		_best = game.best_move(id, infos)
		_best_t = _clock
	return _best


# --- text ----------------------------------------------------------------------------------------

static func _tier_caps(t: int, short: bool = false) -> String:
	var n: String = Economy.TIER_NAMES[t]
	if short and t == 3:
		n = "Bloque"
	return n


# a reason for the card, with how long the rent takes to cover what is missing
func _short(why: String, cost: float) -> String:
	if not why.begins_with("Te faltan"):
		return why
	var need := cost - game.money()
	var inc := game.income() * (1.0 - game.autopay() if game.total_debt() > 0.0 else 1.0)
	if inc <= 0.0:
		return why
	return "%s · ~%s" % [why, Economy.duration(need / inc * 60.0)]


func _street(i: int) -> String:
	var s: String = block["plots"][i].get("street", "")
	return s if s != "" else "calle sin nombre"


func _best_text(b: Dictionary) -> String:
	match b.get("kind", ""):
		"buy":
			var i: int = index.get(b["info"]["id"], 0)
			var t := int(b["info"]["base_tier"])
			return "Compra %s en %s" % ["un solar" if t == 0 else Economy.TIER_NAMES[t].to_lower(),
				_street(i)]
		"build":
			return "%s en %s" % [Economy.TIER_NAMES[int(b["to"])], _street(index.get(b["lot"], 0))]
		"level":
			return "Sube la oficina a Nv %d" % (game.level(id) + 1)
		"hire":
			return "Contrata un gerente"
	return ""


# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if _panel != null:
		_panel.call("draw", self)
		return
	if view.is_drawn():
		_draw_markers()
		_draw_pops()
	_draw_money()
	Ui.arrow(self, ZOOM_OUT, "-", hot, view.zoom_step() == 0)
	Ui.arrow(self, ZOOM_IN, "+", hot, view.zoom_step() == OfficeView.ZOOMS.size() - 1)
	if _buttons_shown():
		_draw_icon_button(BANK_BTN, "bank")
		_draw_icon_button(TEAM_BTN, "team")
	if view.is_card_open():
		_draw_card(view.picked())
	else:
		_draw_next()
	_draw_level()
	if _clock < _toast_until or _undo_visible():
		_draw_toast()
	if not game.away.is_empty():
		_draw_away()


func _draw_money() -> void:
	var cash := Economy.money(game.money())
	var w := Ui.text_width(cash, Ui.TEXT)
	Ui.coin(self, MONEY_AT + Vector2(-w - 22, -14))
	Ui.text_right(self, MONEY_AT, cash, Ui.TEXT, Ui.GOLD)
	var inc := "+%s/min" % Economy.money(game.income())
	Ui.text_right(self, MONEY_AT + Vector2(0, 24), inc, Ui.SMALL, Ui.MINT)
	if game.total_debt() > 0.0:
		Ui.text_right(self, MONEY_AT + Vector2(0, 45), "Deuda " + Economy.money(game.total_debt()),
			Ui.SMALL, Ui.BLOOD, Ui.TEN)


# the bank and manager buttons: steel squares with a pixel "$" or the manager's face
func _draw_icon_button(r: Rect2, kind: String) -> void:
	var over := r.has_point(hot)
	Ui.plate(self, r, Ui.STEEL.lightened(Ui.HOT_LIFT) if over else Ui.STEEL,
		Ui.CYAN if over else Ui.RIM_DIM, 15)
	if kind == "bank":
		var rows: Array[String] = ["..1..", ".1111", "1.1..", ".111.", "..1.1", "1111.", "..1.."]
		var px := 4.0
		var at := (r.get_center() - Vector2(5, 7) * px * 0.5).round()
		for j in rows.size():
			for i in rows[j].length():
				if rows[j][i] == "1":
					draw_rect(Rect2(at + Vector2(i, j) * px, Vector2(px, px)), Ui.GOLD)
		if game.total_debt() > 0.0:
			draw_rect(Rect2(r.end - Vector2(14, 14), Vector2(8, 8)), Ui.BLOOD)
	else:
		var m: Variant = game.manager(id)
		if m is Dictionary:
			Faces.draw(self, (r.get_center() - Vector2(32, 32) * 0.5).round(), 2.0,
				int(m["face"]))
		else:
			Ui.text_in(self, r, "?", Ui.TEXT, Ui.MUTED if not game.managers_open(id) else Ui.GOLD)


# price tags, build arrows and works bars over the map, only between the header and the bottom
func _draw_markers() -> void:
	var view_r := Rect2(8, OfficeView.MAP_TOP, 520, NEXT.position.y - OfficeView.MAP_TOP - 8)
	var tags: Array = []
	for i in infos.size():
		var lid := _lot_id(i)
		var lot: Dictionary = view.lots[i]
		var l := game.lot(id, lid)
		if l.is_empty():
			if float(infos[i]["dist"]) <= game.radius(id):
				var at := view.screen_of_lot(i)
				if view_r.has_point(at):
					tags.append([at.distance_to(view_r.get_center()), i, at])
			continue
		if not lot.has("roof"):
			continue
		var roof: Vector2 = view.drawing_to_screen(lot["roof"])
		if not view_r.has_point(roof):
			continue
		if l.has("end"):
			var f := game.progress(id, lid)
			var bar := Rect2((roof + Vector2(-22, -26)).round(), Vector2(44, 8))
			draw_rect(bar, Ui.VOID)
			draw_rect(Rect2(bar.position + Vector2(2, 2), Vector2(floorf(40.0 * f / 2.0) * 2.0,
				4)), Ui.GOLD)
			var left := Economy.duration(float(l["end"]) - _now())
			var w := Ui.micro_width(left, 2.0)
			Ui.micro(self, (roof + Vector2(-w * 0.5, -42)).round(), left, Ui.CREAM, 2.0, true)
		elif not l.get("office", false) and game.can_build(id, lid) == "":
			_arrow_mark(roof + Vector2(0, -12))
	# price tags: the lots for sale nearest the middle of the view, never one over another
	tags.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	var placed: Array[Rect2] = []
	for t: Array in tags:
		if placed.size() >= MAX_TAGS:
			break
		var i: int = t[1]
		var price := game.buy_price(id, infos[i])
		var text := Economy.money(price)
		var w := Ui.micro_width(text, 2.0) + 8.0
		var box := Rect2(((t[2] as Vector2) - Vector2(w * 0.5, 30)).round(), Vector2(roundf(w), 18))
		var free := true
		for q in placed:
			free = free and not q.grow(2.0).intersects(box)
		if not free:
			continue
		placed.append(box)
		var rich := game.money() >= price
		draw_rect(box, Ui.VOID)
		draw_rect(box.grow(-2.0), Ui.SL1)
		draw_rect(box.grow(-1.0), Ui.GOLD if rich else Ui.RIM_DIM, false, 2.0)
		Ui.micro(self, box.position + Vector2(4, 4), text, Ui.GOLD if rich else Ui.MUTED, 2.0)
		draw_rect(Rect2(box.get_center().x - 1, box.end.y, 2, 6), Ui.GOLD if rich else Ui.RIM_DIM)


# a small gold up arrow: something can be built here now
func _arrow_mark(at: Vector2) -> void:
	var rows: Array[String] = ["..1..", ".111.", "11111", ".111.", ".111."]
	var px := 3.0
	var o := (at - Vector2(7.5, 15)).round()
	for j in rows.size():
		for i in rows[j].length():
			if rows[j][i] == "1":
				draw_rect(Rect2(o + Vector2(i, j) * px - Vector2(1, 1), Vector2(px + 2, px + 2)),
					Ui.VOID)
	for j in rows.size():
		for i in rows[j].length():
			if rows[j][i] == "1":
				draw_rect(Rect2(o + Vector2(i, j) * px, Vector2(px, px)), Ui.GOLD)


# "+$1,2K" rising off the owned roofs in turn, only while the pointer is over the window (a
# widget in a corner should not flicker while you work)
func _draw_pops() -> void:
	if not Rect2(Vector2.ZERO, Ui.CANVAS).has_point(hot):
		return
	var roofs: Array = []
	for lid: String in game.office(id).get("lots", {}):
		var i: int = index.get(lid, -1)
		if i < 0 or not view.lots[i].has("roof"):
			continue
		var l := game.lot(id, lid)
		if l.has("end"):
			continue
		var rent := game.lot_rent(id, l)
		if rent <= 0.0:
			continue
		roofs.append([i, rent])
	var n := mini(roofs.size(), MAX_POPS)
	for k in n:
		var t := fposmod(_pop_t - k * POP_EVERY / maxf(1.0, n), POP_EVERY)
		if t > POP_LIFE:
			continue
		var r: Array = roofs[(k + int(_pop_t / POP_EVERY) * n) % roofs.size()]
		var roof: Vector2 = view.drawing_to_screen(view.lots[r[0]]["roof"])
		if roof.y < OfficeView.MAP_TOP + 20 or roof.y > NEXT.position.y:
			continue
		var rise := floorf(t * 10.0) / (POP_LIFE * 10.0) * POP_RISE
		var text := "+" + Economy.money(float(r[1]) * POP_EVERY / 60.0)
		var w := Ui.micro_width(text, 2.0)
		Ui.micro(self, (roof - Vector2(w * 0.5, 14 + rise)).round(), text, Ui.MINT, 2.0, true)


func _draw_next() -> void:
	var b := _best_move()
	if b.is_empty():
		return
	var cost := float(b["cost"])
	var rich := game.money() >= cost
	var over := NEXT.has_point(hot)
	Ui.plate(self, NEXT, Ui.SHEET if not over else Ui.STEEL, Ui.GOLD if rich else Ui.RIM_DIM, 13)
	var tail := Economy.money(cost)
	if not rich:
		var inc := game.income() * (1.0 - game.autopay() if game.total_debt() > 0.0 else 1.0)
		if inc > 0.0:
			tail = "~" + Economy.duration((cost - game.money()) / inc * 60.0)
	var x := NEXT.position.x + 14.0
	var y := NEXT.position.y + 32.0
	Ui.text(self, Vector2(x, y), ">", Ui.TEXT, Ui.GOLD if rich else Ui.MUTED)
	var tw := Ui.text_width(tail, Ui.TEXT, Ui.NARROW)
	Ui.text_right(self, Vector2(NEXT.end.x - 14.0, y), tail, Ui.TEXT, Ui.GOLD if rich else Ui.MUTED,
		Ui.NARROW)
	_fit(Vector2(x + 24.0, y), _best_text(b), NEXT.size.x - 70.0 - tw, Ui.CREAM if rich else Ui.MUTED)


func _draw_level() -> void:
	var lv := game.level(id)
	var left := "Nv %d" % lv
	Ui.text(self, Vector2(LEVEL_BAR.position.x, LEVEL_BAR.position.y - 10), left, Ui.TEXT, Ui.GOLD)
	# free cranes: the main signal that something can be started
	var free := game.cranes(id) - game.cranes_busy(id)
	Ui.text(self, Vector2(LEVEL_BAR.position.x + Ui.text_width(left, Ui.TEXT) + 12,
		LEVEL_BAR.position.y - 10), "grúas %d/%d" % [free, game.cranes(id)], Ui.TEXT,
		Ui.CYAN if free > 0 else Ui.MUTED, Ui.NARROW)
	var right := "Radio %d m · máximo" % roundi(game.radius(id))
	var frac := 1.0
	if lv < Economy.max_level():
		var c := Economy.level_cost(lv)
		frac = game.money() / c
		if game.can_level_up(id) == "":
			right = "¡Subir a Nv %d!" % (lv + 1)
		else:
			right = "Nv %d: %s" % [lv + 1, _short(game.can_level_up(id), c).replace("Te faltan ",
				"faltan ")]
	var ready := frac >= 1.0 and lv < Economy.max_level()
	Ui.text_right(self, Vector2(LEVEL_BAR.end.x, LEVEL_BAR.position.y - 10), right, Ui.TEXT,
		Ui.GOLD if ready else Ui.MUTED, Ui.NARROW)
	Ui.bar(self, LEVEL_BAR, minf(frac, 1.0), Ui.GOLD if not ready else Ui.CYAN)


func _draw_toast() -> void:
	Ui.plate(self, TOAST, Ui.PLATE, Ui.GOLD, 13)
	var text := _toast if _clock < _toast_until else ""
	if _undo_visible():
		Ui.button(self, UNDO_BTN, "Deshacer", hot)
		_fit(TOAST.position + Vector2(14, 33), text, UNDO_BTN.position.x - TOAST.position.x - 22,
			Ui.CREAM)
	else:
		_fit(TOAST.position + Vector2(14, 33), text, TOAST.size.x - 28, Ui.CREAM)


func _draw_away() -> void:
	draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color(Ui.VOID, 0.6))
	Ui.panel(self, AWAY, Ui.GOLD)
	var a := game.away
	var x := AWAY.position.x + 24.0
	Ui.text(self, Vector2(x, AWAY.position.y + 44), "Mientras no estabas", Ui.TEXT, Ui.CREAM)
	var gone := Economy.duration(float(a["seconds"]))
	var line := "Fuera %s" % gone
	if a.get("capped", false):
		line += " · cobrado %s" % Economy.duration(float(a["paid_s"]))
	Ui.text(self, Vector2(x, AWAY.position.y + 80), line, Ui.SMALL, Ui.MUTED, Ui.TEN)
	Ui.coin(self, Vector2(x, AWAY.position.y + 110))
	Ui.text(self, Vector2(x + 24, AWAY.position.y + 132), "+" + Economy.money(float(a["money"])),
		Ui.BIG, Ui.GOLD)
	var y := AWAY.position.y + 176
	if int(a.get("built", 0)) > 0:
		Ui.text(self, Vector2(x, y), "%d obras terminadas" % int(a["built"]), Ui.SMALL, Ui.MINT,
			Ui.TEN)
		y += 26
	if float(a.get("repaid", 0.0)) > 0.0:
		Ui.text(self, Vector2(x, y), "Al banco: %s" % Economy.money(float(a["repaid"])), Ui.SMALL,
			Ui.MUTED, Ui.TEN)
	Ui.button(self, AWAY_OK, "¡Bien!", hot, true)


func _draw_card(i: int) -> void:
	var info := infos[i]
	var plot: Dictionary = block["plots"][i]
	var lid := _lot_id(i)
	Ui.panel(self, CARD, Ui.GOLD)
	var x := CARD.position.x + 18.0
	var y := CARD.position.y + 38.0
	var room := CARD_X.position.x - x - 8.0
	if _is_office(i):
		var lv := game.level(id)
		_fit(Vector2(x, y), "Tu oficina · Nv %d" % lv, room, Ui.CREAM)
		var r0 := roundi(game.radius(id))
		var radius := "Radio %d m" % r0
		if lv < Economy.max_level():
			radius += " > %d m" % roundi(Rules.active_radius(lv + 1))
		_fit(Vector2(x, y + 32), "%s · grúas %d/%d" % [radius, game.cranes_busy(id),
			game.cranes(id)], CARD.size.x - 36, Ui.MUTED)
		var m: Variant = game.manager(id)
		var who := "sin gerente" if not m is Dictionary else "gerente " + String(m["name"])
		_fit(Vector2(x, y + 62), "Cobro sin conexión %d h · %s" % [roundi(game.offline_cap_s()
			/ 3600.0), who], CARD.size.x - 36, Ui.MUTED)
		Ui.text(self, Vector2(x, y + 92), "Alquiler %s/min" % Economy.money(game.lot_rent(id,
			game.lot(id, lid))), Ui.TEXT, Ui.MINT)
	else:
		_fit(Vector2(x, y), _street(i) if plot.get("street", "") != "" else "Calle sin nombre",
			room, Ui.CREAM)
		var l := game.lot(id, lid)
		var tier := int(l["t"]) if not l.is_empty() else int(info["base_tier"])
		var kind: String = Economy.TIER_NAMES[tier]
		if info["zone"] == "industrial" and tier in [1, 2]:
			kind = "Naves"
		_fit(Vector2(x, y + 32), "%s · %s · %s m2" % [OfficeView.ZONES.get(info["zone"],
			info["zone"]), kind, Ui.count(int(info["area"]))], CARD.size.x - 36, Ui.MUTED)
		var mods := ""
		for m: Array in info["mods"]:
			mods += ("%s%s %+d%%" % [" · " if mods != "" else "", m[0], roundi(float(m[1]) * 100.0)])
		if mods == "":
			mods = "Sin extras"
		_fit(Vector2(x, y + 62), mods, CARD.size.x - 36, Ui.MINT if mods != "Sin extras" else Ui.MUTED)
		var rent := game.lot_rent(id, l) if not l.is_empty() else Economy.rent(tier, info)
		if rent > 0.0:
			Ui.text(self, Vector2(x, y + 92), "Alquiler %s/min" % Economy.money(rent), Ui.TEXT,
				Ui.MINT)
		else:
			# a solar pays nothing yet: what it would with houses on it
			Ui.text(self, Vector2(x, y + 92), "Con casas %s/min" % Economy.money(Economy.rent(1,
				info)), Ui.TEXT, Ui.MUTED, Ui.NARROW)
		var state := "En venta"
		var tone := Ui.GOLD
		if not l.is_empty():
			state = "Tuyo"
			tone = Ui.CYAN
		elif float(info["dist"]) > game.radius(id):
			state = "Fuera de tu radio"
			tone = Ui.BLOOD
		Ui.text_right(self, Vector2(CARD.end.x - 18.0, y + 92), state, Ui.TEXT, tone)
		if l.has("end"):
			Ui.bar(self, Rect2(MAIN_BTN.position + Vector2(0, -10), Vector2(MAIN_BTN.size.x +
				SIDE_BTN.size.x + 10, 8)), game.progress(id, lid))
	var buttons := _card_buttons(i)
	var main: Array = buttons[0]
	var side: Array = buttons[1]
	if main[0] != "":
		Ui.button(self, MAIN_BTN, main[0], hot, main[1], not main[1], Ui.NARROW)
	if side[0] != "":
		Ui.button(self, SIDE_BTN, side[0], hot, false, not side[1], Ui.NARROW)
	var note: String = main[3]
	if note != "":
		_fit(Vector2(x + 12, CARD.end.y - 14), note, CARD.size.x - 60, Ui.MUTED, Ui.SMALL)
	Ui.button(self, CARD_X, "X", hot)


# one line, narrowed and then cut short with an ellipsis to fit `room`
func _fit(at: Vector2, s: String, room: float, color: Color, size: int = Ui.TEXT) -> void:
	var kind := Ui.BOLD if size == Ui.TEXT else Ui.TEN
	if Ui.text_width(s, size, kind) > room:
		kind = Ui.NARROW if size == Ui.TEXT else Ui.TEN
	var line := s
	var cut := s.length()
	while cut > 3 and Ui.text_width(line, size, kind) > room:
		cut -= 1
		line = s.left(cut).strip_edges() + "…"
	Ui.text(self, at, line, size, color, kind)
