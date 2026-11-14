class_name TeamPanel
extends RefCounted

# The office's manager, a full-window panel over the office (docs/GAMEPLAY.md "Gerentes"): the
# manager now in charge (portrait, name, rarity, bonuses) and the agency's candidates, each
# with a Contratar button (tap twice: the new one replaces the old one), plus a button to see
# other candidates now. Before the office reaches the level that opens managers it says so.
# OfficePlay draws it on its own canvas and hands it the input.

const NOW := Rect2(12, 86, 576, 136)
const AGENCY_Y := 262.0
const REFRESH := Rect2(392, 230, 196, 48)
const ROW_Y := 286.0
const ROW_H := 98.0
const SURE_S := 3.0

var game: Game
var id := ""
var hot := Vector2(-100, -100)
var _close := false
# the candidate slot waiting for a second tap to be hired, and until when
var _sure := -1
var _sure_until := 0.0
var _clock := 0.0


func _init(the_game: Game, office_id: String) -> void:
	game = the_game
	id = office_id


func tick() -> void:
	_clock += 0.1


func back() -> bool:
	return false


func wants_close() -> bool:
	return _close


func _row(k: int) -> Rect2:
	return Rect2(12, ROW_Y + k * ROW_H, 576, ROW_H - 8)


func _hire_btn(k: int) -> Rect2:
	var r := _row(k)
	return Rect2(r.end.x - 204, r.position.y + 20, 188, 52)


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		_close = true
		return
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
	Ui.backdrop(c)
	Ui.header(c, "Gerente", true, hot)
	var cash := Economy.money(game.money())
	Ui.text_right(c, Vector2(588, 40), cash, Ui.TEXT, Ui.GOLD)
	Ui.coin(c, Vector2(588 - Ui.text_width(cash, Ui.TEXT) - 22, 26))
	Ui.panel(c, NOW, Ui.RIM_DIM)
	var m: Variant = game.manager(id)
	if not game.managers_open(id):
		Ui.text(c, NOW.position + Vector2(18, 44), "Aún no tienes gerente", Ui.TEXT, Ui.CREAM)
		Ui.text(c, NOW.position + Vector2(18, 80), "Sube la oficina al Nv %d y te llega uno" %
			Economy.MANAGER_LEVEL, Ui.SMALL, Ui.MUTED, Ui.TEN)
		Ui.text(c, NOW.position + Vector2(18, 108), "gratis. Luego eliges otros mejores.",
			Ui.SMALL, Ui.MUTED, Ui.TEN)
		Ui.footer(c, "")
		return
	if m is Dictionary:
		_person(c, m, NOW, 6.0, true)
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
		Ui.button(c, _hire_btn(k), "¿Seguro?" if sure else Economy.money(cost), hot, can, not can,
			Ui.NARROW)
	if cands.is_empty():
		Ui.text(c, Vector2(16, ROW_Y + 40), "Ya contrataste a todos; vuelve luego", Ui.SMALL,
			Ui.MUTED, Ui.TEN)
	Ui.footer(c, "")


# a portrait with name, rarity and bonuses inside `r`
func _person(c: CanvasItem, m: Dictionary, r: Rect2, px: float, big: bool) -> void:
	var side := px * Faces.SIZE + 10.0
	var badge := Rect2((r.position + Vector2(10, (r.size.y - side) * 0.5)).round(),
		Vector2(side, side))
	Faces.badge(c, badge, int(m["face"]), int(m["rarity"]))
	var x := badge.end.x + 14.0
	var rarity := int(m["rarity"])
	var y := r.position.y + (40.0 if big else 30.0)
	Ui.text(c, Vector2(x, y), m["name"], Ui.TEXT, Ui.CREAM, Ui.BOLD if big else Ui.NARROW)
	Ui.text(c, Vector2(x, y + 24), Economy.RARITY_NAMES[rarity], Ui.SMALL,
		Faces.RARITY_INK[rarity], Ui.TEN)
	var line := ""
	for t: Dictionary in m["traits"]:
		line += (" · " if line != "" else "") + Economy.trait_text(t)
	var room := r.end.x - x - 12.0
	var s := line
	var cut := line.length()
	while cut > 3 and Ui.text_width(s, Ui.SMALL, Ui.TEN) > room:
		cut -= 1
		s = line.left(cut).strip_edges() + "…"
	Ui.text(c, Vector2(x, y + 50), s, Ui.SMALL, Ui.MINT, Ui.TEN)
