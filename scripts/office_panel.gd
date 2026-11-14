class_name OfficePanel
extends RefCounted

# The office tab, a full-window panel over the office like the bank (docs/GAMEPLAY.md "Tu
# oficina"). The office is not a building but the business that runs the neighbourhood, so this
# is where it lives: two pages under the header. OFICINA: its level, radius, lots, works, cranes
# and income (the lots' rent and the office's own commissions); the next level and what it
# brings (radius, cranes, offline hours, commissions, the free manager, the builder) with the
# level-up button; the builder switch ("Obras solas", from AUTO_LEVEL); and greyed PRONTO rows
# for what comes later. GERENTE: the manager (TeamPanel). Opened from the HUD's briefcase, the
# level line, the next move and the office's pin on the map. OfficePlay draws it on its own
# canvas, hands it the input and notices a level-up (it redraws the area for the new radius).

enum { PAGE_OFFICE, PAGE_TEAM }
const TABS: Array[Rect2] = [Rect2(12, 82, 186, 44), Rect2(206, 82, 186, 44)]
const TAB_NAMES: Array[String] = ["Oficina", "Gerente"]
const STATUS := Rect2(12, 132, 576, 116)
const NEXT := Rect2(12, 256, 576, 190)
const LEVEL_BTN := Rect2(30, 378, 300, 52)
const AUTO := Rect2(12, 454, 576, 56)
const AUTO_BTN := Rect2(440, 458, 140, 48)
const SOON_Y := 518.0
const SOON_H := 52.0
# what the office will do later, shown greyed so the tab has visible room to grow
const SOON: Array[String] = ["Salir a bolsa", "Recalificar"]

var game: Game
var id := ""
var page := PAGE_OFFICE
var hot := Vector2(-100, -100):
	set(v):
		hot = v
		if _team != null:
			_team.hot = v
var _team: TeamPanel
var _close := false


func _init(the_game: Game, office_id: String, first_page: int = PAGE_OFFICE) -> void:
	game = the_game
	id = office_id
	page = first_page
	_team = TeamPanel.new(game, id)


func tick() -> void:
	_team.tick()


func back() -> bool:
	return false


func wants_close() -> bool:
	return _close


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		_close = true
		return
	for k in TABS.size():
		if TABS[k].has_point(at):
			page = k
			return
	if page == PAGE_TEAM:
		_team.click(at)
		return
	if LEVEL_BTN.has_point(at) and game.level(id) < Economy.max_level():
		if game.level_up(id) == "":
			game.save()
	elif AUTO_BTN.has_point(at) and game.auto_open(id):
		game.set_auto(id, not game.auto_on(id))
		game.save()


func draw(c: CanvasItem) -> void:
	Ui.backdrop(c)
	Ui.header(c, "Tu oficina", true, hot, 400.0)
	var cash := Economy.money(game.money())
	Ui.text_right(c, Vector2(588, 40), cash, Ui.TEXT, Ui.GOLD)
	Ui.coin(c, Vector2(588 - Ui.text_width(cash, Ui.TEXT) - 22, 26))
	for k in TABS.size():
		_tab(c, k)
	if page == PAGE_TEAM:
		_team.draw(c)
	else:
		_draw_status(c)
		_draw_next(c)
		_draw_auto(c)
		_draw_soon(c)
	Ui.footer(c, "")


# a tab: the open one lit with a cyan rim, the other dim; the manager's tab shows a gold dot
# while the office has no manager and could hire one
func _tab(c: CanvasItem, k: int) -> void:
	var r := TABS[k]
	var on := page == k
	var over := r.has_point(hot) and not on
	var back := Ui.STEEL if on else (Ui.SHEET.lightened(Ui.HOT_LIFT) if over else Ui.SHEET)
	Ui.plate(c, r, back, Ui.CYAN if on or over else Ui.RIM_DIM, 15)
	Ui.text_in(c, r, TAB_NAMES[k], Ui.TEXT, Ui.CREAM if on else Ui.MUTED, Ui.BOLD, on)
	if k == PAGE_TEAM and game.managers_open(id) and game.manager(id) == null:
		c.draw_rect(Rect2(r.end - Vector2(14, 14), Vector2(8, 8)), Ui.GOLD)


func _draw_status(c: CanvasItem) -> void:
	Ui.panel(c, STATUS, Ui.RIM_DIM)
	var x := STATUS.position.x + 18.0
	var y := STATUS.position.y + 34.0
	var lv := game.level(id)
	Ui.text(c, Vector2(x, y), "Nv %d · Radio %d m" % [lv, roundi(game.radius(id))], Ui.TEXT,
		Ui.GOLD)
	Ui.text_right(c, Vector2(STATUS.end.x - 18.0, y), "+%s/min" % Economy.money(
		game.income(id)), Ui.TEXT, Ui.MINT, Ui.NARROW)
	var works := game.cranes_busy(id)
	var free := game.cranes(id) - works
	var n := game.owned_count(id)
	_line(c, Vector2(x, y + 28), "%s · %s · grúas libres %d/%d" % ["1 terreno tuyo" if n == 1
		else "%d terrenos tuyos" % n, "1 obra" if works == 1 else "%d obras" % works, free,
		game.cranes(id)], Ui.CREAM)
	_line(c, Vector2(x, y + 50), "Alquileres %s + comisiones %s" % [Economy.money(
		game.lots_rent(id)), Economy.money(game.office_income(id))], Ui.MINT)
	_line(c, Vector2(x, y + 72), "Cobras %d h sin conexión" % roundi(game.offline_cap_s()
		/ 3600.0), Ui.MUTED)


# the next level: what it costs, what it brings and the button
func _draw_next(c: CanvasItem) -> void:
	Ui.panel(c, NEXT, Ui.RIM_DIM)
	var x := NEXT.position.x + 18.0
	var y := NEXT.position.y + 34.0
	var lv := game.level(id)
	if lv >= Economy.max_level():
		Ui.text(c, Vector2(x, y), "Nivel máximo", Ui.TEXT, Ui.CREAM)
		_line(c, Vector2(x, y + 30), "Tu oficina llega a todo su barrio: %d m" % roundi(
			game.radius(id)), Ui.MUTED)
		_line(c, Vector2(x, y + 52), "Lo siguiente: abrir otra oficina en el mapa", Ui.MUTED)
		return
	var cost := Economy.level_cost(lv)
	Ui.text(c, Vector2(x, y), "Subir a Nv %d" % (lv + 1), Ui.TEXT, Ui.CREAM)
	Ui.text_right(c, Vector2(NEXT.end.x - 18.0, y), Economy.money(cost), Ui.TEXT, Ui.GOLD)
	# the commissions (with the manager's rent bonus, as earned) take a whole line, the rest two
	# to a line
	var bonus := 1.0 + Economy.trait_of(game.manager(id), "rent")
	_line(c, Vector2(x, y + 28.0), "Comisiones %s > %s/min" % [Economy.money(
		Economy.office_income(lv) * bonus), Economy.money(Economy.office_income(lv + 1)
		* bonus)], Ui.CREAM)
	var gains := _gains(lv)
	var col := (NEXT.size.x - 36.0) * 0.5
	for k in gains.size():
		var at := Vector2(x + (k % 2) * col, y + 50.0 + (k / 2) * 22.0)
		_line(c, at, gains[k], Ui.MINT if gains[k].begins_with("+") else Ui.CREAM, col - 10.0)
	var why := game.can_level_up(id)
	Ui.button(c, LEVEL_BTN, "Subir a Nv %d" % (lv + 1), hot, why == "", why != "")
	var nx := LEVEL_BTN.end.x + 16.0
	if why == "":
		_line(c, Vector2(nx, LEVEL_BTN.position.y + 32), "¡Ya puedes!", Ui.GOLD)
	elif why.begins_with("Te faltan"):
		_line(c, Vector2(nx, LEVEL_BTN.position.y + 20), why, Ui.MUTED, NEXT.end.x - nx - 14.0)
		var inc := game.income() * (1.0 - game.autopay() if game.total_debt() > 0.0 else 1.0)
		if inc > 0.0:
			_line(c, Vector2(nx, LEVEL_BTN.position.y + 44), "~" + Economy.duration((cost
				- game.money()) / inc * 60.0), Ui.MUTED)


# what else the next level brings, as short lines (a "+" line is something new); what does not
# change is left out
func _gains(lv: int) -> Array[String]:
	var out: Array[String] = []
	out.append("Radio %d > %d m" % [roundi(Rules.active_radius(lv)),
		roundi(Rules.active_radius(lv + 1))])
	var c0 := Economy.cranes(lv)
	var c1 := Economy.cranes(lv + 1)
	if c1 != c0:
		out.append("Grúas %d > %d" % [c0, c1])
	out.append("Sin conexión %d > %d h" % [roundi(Economy.offline_hours(lv)),
		roundi(Economy.offline_hours(lv + 1))])
	if lv + 1 == Economy.MANAGER_LEVEL:
		out.append("+ Un gerente gratis")
	if lv + 1 == Economy.AUTO_LEVEL:
		out.append("+ Obras solas")
	if lv + 1 == Economy.OFFICE_NEEDS_LEVEL:
		out.append("+ Abrir otra oficina")
	return out


func _draw_auto(c: CanvasItem) -> void:
	var open := game.auto_open(id)
	Ui.plate(c, AUTO, Ui.PLATE, Ui.RIM_DIM, 13)
	var x := AUTO.position.x + 18.0
	Ui.text(c, Vector2(x, AUTO.position.y + 26), "Obras solas", Ui.TEXT,
		Ui.CREAM if open else Ui.MUTED)
	_line(c, Vector2(x, AUTO.position.y + 48), "Construye con las grúas libres", Ui.MUTED,
		AUTO_BTN.position.x - x - 12.0)
	if open:
		var on := game.auto_on(id)
		Ui.button(c, AUTO_BTN, "Sí" if on else "No", hot, on)
	else:
		Ui.button(c, AUTO_BTN, "Nv %d" % Economy.AUTO_LEVEL, hot, false, true)


# the rows still to come, greyed with a PRONTO tag (as Battlegrounds shows its SOON tools)
func _draw_soon(c: CanvasItem) -> void:
	var w := (576.0 - 8.0) / SOON.size()
	for k in SOON.size():
		var r := Rect2(12.0 + k * (w + 8.0), SOON_Y, w, SOON_H)
		Ui.plate(c, r, Ui.SHEET, Ui.RIM_DIM, 13)
		Ui.text(c, Vector2(r.position.x + 16, r.position.y + 34), SOON[k], Ui.TEXT, Ui.SL3,
			Ui.NARROW, false)
		var tag := "PRONTO"
		var tw := Ui.micro_width(tag) + 12.0
		var chip := Rect2(r.end.x - tw - 12.0, r.position.y + 15, tw, 22)
		Ui.chip(c, chip, Ui.SUNKEN, Ui.RIM_DIM)
		Ui.micro(c, chip.position + Vector2(6, 6), tag, Ui.MUTED)


# one small line, cut short with an ellipsis to fit `room` when given
func _line(c: CanvasItem, at: Vector2, s: String, color: Color, room: float = 540.0) -> void:
	var line := s
	var cut := s.length()
	while cut > 3 and Ui.text_width(line, Ui.SMALL, Ui.TEN) > room:
		cut -= 1
		line = s.left(cut).strip_edges() + "…"
	Ui.text(c, at, line, Ui.SMALL, color, Ui.TEN)
