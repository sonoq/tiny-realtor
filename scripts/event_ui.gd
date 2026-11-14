class_name EventUi
extends RefCounted

# The events on the office's map (docs/GAMEPLAY.md "Eventos"), part of OfficePlay's layer: a
# slim banner that slides in under the header, left of the zoom buttons, with the event's icon,
# a short line, what it is about and how long it waits, a button that takes it (buy at the
# discount, accept, collect, or open the job) and an X that lets it go (it costs nothing). A
# tap on the banner's body pans to the lot it is about and opens its card (a job opens its
# panel). The lot gets a bobbing bubble with the same icon. An exprés already accepted shows in
# the banner too until it is used. It never steals a click: the banner leaves the header and
# the zoom column alone, and for GRACE_S after it slides in a click there goes to the map as if
# it were not there; buying from it has OfficePlay's guards (not the click that focused the
# window, not the second tap of a double tap) and can be undone like any purchase.
#
# It also tells Events when the player is active: the window focused and the pointer moved in
# the last ACTIVE_FOCUS_S, or the pointer moving over the window in the last ACTIVE_HOVER_S.

const BANNER := Rect2(12, 112, 516, 56)
const BTN := Rect2(334, 118, 140, 44)
const CLOSE := Rect2(478, 118, 44, 44)
const TEXT_X := 64.0
const SLIDE_S := 0.25
const GRACE_S := 0.6
const ACTIVE_HOVER_S := 30.0
const ACTIVE_FOCUS_S := 180.0
# a frame longer than this (a stall, the computer waking up) is not played time
const TICK_MAX := 1.0
const ICONS := {
	"sale": [".11...1.", ".11..1..", "....1...", "...1....", "..1.....", ".1..11..",
		"1...11..", "........"],
	"express": ["....111.", "...111..", "..111...", ".111111.", "...111..", "..111...",
		".11.....", "1......."],
	"vip": ["...11...", "...11...", "11111111", ".111111.", "..1111..", ".111111.",
		".11..11.", "11....11"],
	"buyer": ["...1....", ".11111..", "1..1....", ".1111...", "...1.1..", "11111...",
		"...1....", "........"],
	"pipes": ["..111...", "...1....", "111111..", "1111111.", ".....11.", "........",
		".....11.", ".....11."],
	"wires": [".1..1...", ".1..1...", "111111..", "111111..", ".1111...", "..11....",
		"..11....", "...1111."],
	"bulbs": ["..1111..", ".111111.", "11111111", "11111111", ".111111.", "..1111..",
		"..1111..", "...11..."],
}

var play: OfficePlay
var game: Game
var id := ""
var _clock := 0.0
var _moved_ms := -10000000
# the event on show and when it slid in
var _shown := -1
var _shown_at := -10.0


func _init(the_play: OfficePlay) -> void:
	play = the_play
	game = the_play.game
	id = the_play.id


# the pointer moved over the window
func pointer(at: Vector2) -> void:
	if Rect2(Vector2.ZERO, Ui.CANVAS).has_point(at):
		_moved_ms = Time.get_ticks_msec()


func active() -> bool:
	var idle := (Time.get_ticks_msec() - _moved_ms) / 1000.0
	var focused := play.is_inside_tree() and play.get_window().has_focus()
	return idle < (ACTIVE_FOCUS_S if focused else ACTIVE_HOVER_S)


func tick(delta: float) -> void:
	_clock += delta
	if Events.auto:
		var ev := Events.tick(game, id, play.infos, minf(delta, TICK_MAX), active())
		if not ev.is_empty():
			play.queue_redraw()
	var key := _key()
	if key != _shown:
		_shown = key
		_shown_at = _clock


# what the banner is about: the waiting event, else an exprés already taken; {} for nothing
func subject() -> Dictionary:
	var p := Events.pending(game, id)
	if not p.is_empty():
		return p
	if Events.express_left(game, id) > 0.0:
		return {"kind": "express_on", "n": -2, "lot": _best_build()}
	return {}


func _key() -> int:
	var s := subject()
	return int(s.get("n", -1)) if not s.is_empty() else -1


func visible() -> bool:
	return not subject().is_empty()


func over(at: Vector2) -> bool:
	return visible() and BANNER.has_point(at)


# a click; true when the banner took it. `guarded`: the click that focused the window or the
# second tap of a double tap, which may not spend
func click(at: Vector2, guarded: bool) -> bool:
	if not over(at):
		return false
	# it has just slid in under the pointer: the click was meant for the map
	if _clock - _shown_at < GRACE_S:
		return false
	var s := subject()
	play.view.sync()
	if CLOSE.has_point(at):
		if s["kind"] == "express_on":
			game.office(id).erase("express")
		else:
			Events.dismiss(game, id)
		game.save()
	elif BTN.has_point(at):
		_take(s, guarded)
	else:
		_follow(s)
	play.queue_redraw()
	return true


func _take(s: Dictionary, guarded: bool) -> void:
	var i: int = play.index.get(s.get("lot", ""), -1)
	match s["kind"]:
		"sale":
			if i < 0 or guarded:
				return
			if game.can_buy(id, play.infos[i]) == "":
				play.event_buy(i)
			else:
				_follow(s)
		"express":
			if Events.accept(game, id) == "":
				play.say("Exprés: tu próxima obra tarda la mitad", true)
				game.save()
				_follow({"lot": _best_build()})
		"vip":
			if Events.accept(game, id) == "":
				play.say("¡Inquilino VIP! x%d alquiler %s" % [roundi(float(s["x"])),
					Economy.duration(float(s["secs"]))], true)
				game.save()
		"buyer":
			var pay := Events.reward(game, s)
			if Events.accept(game, id) == "":
				play.say("Opción vendida: +" + Economy.money(pay), true)
				game.save()
		"job":
			play.open_job(s)
		"express_on":
			_follow(s)


# pans to the lot the event is about and opens its card; a job opens its panel
func _follow(s: Dictionary) -> void:
	if s.get("kind", "") == "job":
		play.open_job(s)
		return
	var i: int = play.index.get(s.get("lot", ""), -1)
	if i >= 0:
		play.view.focus_lot(i)
		play.view.select(i)


# the owned lot where works make most sense now (for an exprés)
func _best_build() -> String:
	var best := ""
	var best_s := -1.0
	for lid: String in game.office(id).get("lots", {}):
		var l := game.lot(id, lid)
		if l.has("end") or int(l["t"]) >= int(l["mx"]) or l.get("fill", false):
			continue
		var secs := game.build_time(id, int(l["t"]), int(l["t"]) + 1)
		var ok := game.can_build(id, lid) == ""
		var score := secs + (1e6 if ok else 0.0)
		if score > best_s:
			best_s = score
			best = lid
	return best


# --- text ----------------------------------------------------------------------------------------

func _title(s: Dictionary) -> String:
	match s["kind"]:
		"sale":
			return "Oferta -%d%%" % roundi(float(s["cut"]) * 100.0)
		"express":
			return "Obra exprés"
		"vip":
			return "Inquilino VIP"
		"buyer":
			return "Comprador con prisa"
		"job":
			return JobPanel.title_of(s["game"])
		"express_on":
			return "Exprés activa"
	return ""


func _detail(s: Dictionary) -> String:
	var i: int = play.index.get(s.get("lot", ""), -1)
	var street := play.street_of(i) if i >= 0 else ""
	var left := ""
	match s["kind"]:
		"sale":
			var t := int(play.infos[i]["base_tier"]) if i >= 0 else 0
			var what := "Solar" if t == 0 else Economy.TIER_NAMES[t]
			return "%s en %s%s" % [what, street, left]
		"express":
			return "Tu próxima obra -50%% tiempo%s" % left
		"vip":
			return "x%d alquiler %s · %s%s" % [roundi(float(s["x"])), Economy.duration(float(
				s["secs"])), street, left]
		"buyer":
			return "Quiere una opción sobre %s%s" % [street, left]
		"job":
			return "%s · hasta +%s%s" % [street, Economy.money(Events.reward(game, s)), left]
		"express_on":
			return "Elige una obra · quedan %s" % Economy.duration(Events.express_left(game, id))
	return ""


# [label, accent, off] of the banner's button
func _button(s: Dictionary) -> Array:
	match s["kind"]:
		"sale":
			var i: int = play.index.get(s["lot"], -1)
			if i < 0:
				return ["", false, true]
			var price := game.buy_price(id, play.infos[i])
			if game.money() >= price:
				return [Economy.money(price), true, false]
			return ["Ver", false, false]
		"express":
			return ["Activar", true, false]
		"vip":
			return ["Aceptar", true, false]
		"buyer":
			return ["+" + Economy.money(Events.reward(game, s)), true, false]
		"job":
			return ["Ayudar", true, false]
		"express_on":
			return ["Ver", false, false]
	return ["", false, true]


# the lot card's line about an event on its lot ("" for none): [text, colour]
func card_line(i: int) -> Array:
	var lid: String = play.infos[i]["id"]
	var p := Events.pending(game, id)
	if p.get("lot", "") == lid:
		match p["kind"]:
			"sale":
				return ["Oferta -%d%% · quedan %d s" % [roundi(float(p["cut"]) * 100.0), ceili(
					float(p["left"]))], Ui.GOLD]
			"vip":
				return ["Inquilino VIP x%d esperando" % roundi(float(p["x"])), Ui.GOLD]
			"job":
				return ["Un inquilino pide ayuda", Ui.GOLD]
			"buyer":
				return ["Un comprador quiere una opción", Ui.GOLD]
	var vip := Events.vip_left(game, id, lid)
	if vip > 0.0:
		return ["Inquilino VIP x%d · %s" % [roundi(float(game.lot(id, lid).get("vx", 2.0))),
			Economy.duration(vip)], Ui.GOLD]
	if Events.express_left(game, id) > 0.0 and game.owns(id, lid):
		return ["Exprés: la próxima obra tarda la mitad", Ui.GOLD]
	return []


# --- drawing -------------------------------------------------------------------------------------

func draw(c: CanvasItem) -> void:
	var s := subject()
	if s.is_empty():
		return
	var f := clampf((_clock - _shown_at) / SLIDE_S, 0.0, 1.0)
	var off := Vector2(roundf(-(1.0 - f) * (1.0 - f) * (BANNER.end.x + 8.0) / 2.0) * 2.0, 0)
	var r := Rect2(BANNER.position + off, BANNER.size)
	var hot := play.hot if f >= 1.0 else Vector2(-100, -100)
	var body_hot := r.has_point(hot) and not BTN.has_point(hot) and not CLOSE.has_point(hot)
	Ui.plate(c, r, Ui.STEEL if body_hot else Ui.PLATE, Ui.GOLD, 13)
	var kind: String = s["kind"]
	var icon_key: String = s["game"] if kind == "job" else ("express" if kind == "express_on"
		else kind)
	var ic := Rect2(r.position + Vector2(10, 10), Vector2(40, 36))
	c.draw_rect(ic, Ui.VOID)
	c.draw_rect(ic.grow(-2), Ui.GOLD_D)
	icon(c, icon_key, ic.position + Vector2(8, 6), 3.0, Ui.GOLD)
	var room := BTN.position.x - TEXT_X - 10.0
	JobPanel._fit(c, r.position + Vector2(TEXT_X - BANNER.position.x, 30), _title(s), room,
		Ui.GOLD if kind != "express_on" else Ui.CYAN)
	# how long it still waits, at the right of the detail line
	var wait := ""
	if s.has("left"):
		wait = "%d S" % ceili(float(s["left"]))
		Ui.micro(c, r.position + Vector2(TEXT_X - BANNER.position.x + room - Ui.micro_width(wait),
			38), wait, Ui.GOLD, 2.0)
	var text_room := room - (Ui.micro_width(wait) + 10.0 if wait != "" else 0.0)
	# the micro font has no middle dot or ellipsis
	var detail := StreetNames.plain(_detail(s).replace("·", "-"))
	while Ui.micro_width(detail) > text_room and detail.length() > 4:
		detail = detail.left(detail.length() - 3).strip_edges() + ".."
	Ui.micro(c, r.position + Vector2(TEXT_X - BANNER.position.x, 38), detail, Ui.CREAM, 2.0)
	# how long it waits, as a thin gold bar along the bottom
	if s.has("life"):
		var w := floorf(room * clampf(float(s["left"]) / float(s["life"]), 0.0, 1.0) / 2.0) * 2.0
		c.draw_rect(Rect2(r.position + Vector2(TEXT_X - BANNER.position.x, 50), Vector2(room, 2)),
			Ui.SL2)
		c.draw_rect(Rect2(r.position + Vector2(TEXT_X - BANNER.position.x, 50), Vector2(w, 2)),
			Ui.GOLD)
	var b := _button(s)
	if b[0] != "":
		Ui.button(c, Rect2(BTN.position + off, BTN.size), b[0], hot, b[1],
			b[2], Ui.NARROW)
	Ui.button(c, Rect2(CLOSE.position + off, CLOSE.size), "X", hot)


static func icon(c: CanvasItem, key: String, at: Vector2, px: float, color: Color) -> void:
	var rows: Array = ICONS.get(key, ICONS["sale"])
	JobGame.sprite(c, rows, at, px, {"1": color})


# the bubble over the event's lot and a star over each VIP building, inside the map's box
func draw_marks(c: CanvasItem, view_r: Rect2) -> void:
	var p := Events.pending(game, id)
	var bob := -2.0 if int(_clock * 3.0) % 2 == 0 else 0.0
	if not p.is_empty() and p.get("lot", "") != "":
		var i: int = play.index.get(p["lot"], -1)
		if i >= 0:
			var at := _top_of(i)
			if view_r.has_point(at + Vector2(0, -50)):
				var key: String = p["game"] if p["kind"] == "job" else p["kind"]
				var box := Rect2((at + Vector2(-18, -50 + bob)).round(), Vector2(36, 34))
				c.draw_rect(box.grow(2), Ui.VOID)
				c.draw_rect(box, Ui.GOLD)
				c.draw_rect(Rect2(box.get_center().x - 4, box.end.y, 8, 6), Ui.VOID)
				c.draw_rect(Rect2(box.get_center().x - 2, box.end.y, 4, 4), Ui.GOLD)
				icon(c, key, box.position + Vector2(6, 5), 3.0, Ui.VOID)
	for lid: String in game.office(id).get("lots", {}):
		var left := Events.vip_left(game, id, lid)
		if left <= 0.0:
			continue
		var i: int = play.index.get(lid, -1)
		if i < 0:
			continue
		var at := _top_of(i)
		if not view_r.has_point(at + Vector2(0, -40)):
			continue
		var text := "VIP " + Economy.duration(left).to_upper()
		var w := Ui.micro_width(text, 2.0)
		icon(c, "vip", (at + Vector2(-w * 0.5 - 22, -38 + bob)).round(), 2.0, Ui.GOLD)
		Ui.micro(c, (at + Vector2(-w * 0.5, -36 + bob)).round(), text, Ui.GOLD, 2.0, true)


# where a lot's marks stand on screen: over its roof, else its ground middle
func _top_of(i: int) -> Vector2:
	var lot: Dictionary = play.view.lots[i]
	if lot.has("roof"):
		return play.view.drawing_to_screen(lot["roof"]) + Vector2(0, -6)
	return play.view.screen_of_lot(i)
