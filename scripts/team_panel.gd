class_name TeamPanel
extends RefCounted

# The office's manager, the GERENTE page of the office tab (OfficePanel; docs/GAMEPLAY.md
# "Gerentes"): the manager now in charge (portrait, name, rarity, bonuses) and the agency's
# candidates, each with a Contratar button (tap twice: the new one replaces the old one), plus a
# button to see other candidates now. Before the office reaches the level that opens managers it
# says so. OfficePanel draws the header, the tabs and the footer round it and hands it the input.

const NOW := Rect2(12, 132, 576, 104)
const AGENCY_Y := 268.0
const REFRESH := Rect2(392, 244, 196, 44)
const ROW_Y := 294.0
const ROW_H := 94.0
const SURE_S := 3.0

var game: Game
var id := ""
var hot := Vector2(-100, -100)
# the candidate slot waiting for a second tap to be hired, and until when
var _sure := -1
var _sure_until := 0.0
var _clock := 0.0


func _init(the_game: Game, office_id: String) -> void:
	game = the_game
	id = office_id


func tick() -> void:
	_clock += 0.1


func _row(k: int) -> Rect2:
	return Rect2(12, ROW_Y + k * ROW_H, 576, ROW_H - 8)


func _hire_btn(k: int) -> Rect2:
	var r := _row(k)
	return Rect2(r.end.x - 204, r.position.y + 20, 188, 52)


func click(at: Vector2) -> void:
	if not game.managers_open(id):
		return
	if REFRESH.has_point(at):
		if game.refresh_pool(id) == "":
			game.save()
		return
	var cands := game.pool(id)
	for k in cands.size():
		if not _hire_btn(k).has_point(at):
			continue
		var m: Dictionary = cands[k]
		if game.can_hire(id, m) != "":
			return
		if _sure == int(m["slot"]) and _clock < _sure_until:
			game.hire(id, m)
			game.save()
			_sure = -1
		else:
			_sure = int(m["slot"])
			_sure_until = _clock + SURE_S


func draw(c: CanvasItem) -> void:
	Ui.panel(c, NOW, Ui.RIM_DIM)
	var m: Variant = game.manager(id)
	if not game.managers_open(id):
		Ui.text(c, NOW.position + Vector2(18, 40), "Aún no tienes gerente", Ui.TEXT, Ui.CREAM)
		Ui.text(c, NOW.position + Vector2(18, 70), "Sube la oficina al Nv %d y te llega uno" %
			Economy.MANAGER_LEVEL, Ui.SMALL, Ui.MUTED, Ui.TEN)
		Ui.text(c, NOW.position + Vector2(18, 92), "gratis. Luego eliges otros mejores.",
			Ui.SMALL, Ui.MUTED, Ui.TEN)
		return
	if m is Dictionary:
		_person(c, m, NOW, 5.0, true)
	else:
		Ui.text(c, NOW.position + Vector2(18, 44), "Sin gerente", Ui.TEXT, Ui.MUTED)
		Ui.text(c, NOW.position + Vector2(18, 80), "Contrata uno de abajo", Ui.SMALL, Ui.MUTED,
			Ui.TEN)
	var left := game.pool_left_s(id)
	Ui.text(c, Vector2(16, AGENCY_Y - 6), "Agencia", Ui.TEXT, Ui.CREAM)
	Ui.text(c, Vector2(16, AGENCY_Y + 16), "Nuevos en " + Economy.duration(left), Ui.SMALL,
		Ui.MUTED, Ui.TEN)
	var rc := game.refresh_cost(id)
	Ui.button(c, REFRESH, "Otros " + Economy.money(rc), hot, false, game.money() < rc, Ui.NARROW)
	var cands := game.pool(id)
	for k in cands.size():
		var cand: Dictionary = cands[k]
		var r := _row(k)
		Ui.plate(c, r, Ui.PLATE, Faces.RARITY_INK[int(cand["rarity"])], 13)
		_person(c, cand, Rect2(r.position, Vector2(r.size.x - 210, r.size.y)), 4.0, false)
		var cost := game.hire_cost(id, cand)
		var can := game.can_hire(id, cand) == ""
		var sure := _sure == int(cand["slot"]) and _clock < _sure_until
		var label := Economy.money(cost)
		if sure:
			label = "¿Cambiar?" if game.manager(id) != null else "¿Seguro?"
		Ui.button(c, _hire_btn(k), label, hot, can, not can, Ui.NARROW)
	if cands.is_empty():
		Ui.text(c, Vector2(16, ROW_Y + 40), "Ya contrataste a todos; vuelve luego", Ui.SMALL,
			Ui.MUTED, Ui.TEN)


# a portrait with name, rarity and bonuses inside `r`
func _person(c: CanvasItem, m: Dictionary, r: Rect2, px: float, big: bool) -> void:
	var side := px * Faces.SIZE + 10.0
	var badge := Rect2((r.position + Vector2(10, (r.size.y - side) * 0.5)).round(),
		Vector2(side, side))
	Faces.badge(c, badge, int(m["face"]), int(m["rarity"]))
	var x := badge.end.x + 14.0
	var rarity := int(m["rarity"])
	var y := r.position.y + (34.0 if big else 26.0)
	var name: String = m["name"]
	Ui.text(c, Vector2(x, y), name, Ui.TEXT, Ui.CREAM, Ui.BOLD if big else Ui.NARROW)
	var nw := Ui.text_width(name, Ui.TEXT, Ui.BOLD if big else Ui.NARROW)
	Ui.text(c, Vector2(x + nw + 10, y), Economy.RARITY_NAMES[rarity], Ui.SMALL,
		Faces.RARITY_INK[rarity], Ui.TEN)
	# one bonus a line, so none is cut short: they are the choice
	var room := r.end.x - x - 12.0
	var line_y := y + (22.0 if big else 20.0)
	for t: Dictionary in m["traits"]:
		var s := Economy.trait_text(t)
		var full := s
		var cut := s.length()
		while cut > 3 and Ui.text_width(s, Ui.SMALL, Ui.TEN) > room:
			cut -= 1
			s = full.left(cut).strip_edges() + "…"
		Ui.text(c, Vector2(x, line_y), s, Ui.SMALL, Ui.MINT, Ui.TEN)
		line_y += 20.0 if big else 18.0
