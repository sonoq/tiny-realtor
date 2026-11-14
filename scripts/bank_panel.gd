class_name BankPanel
extends RefCounted

# The bank, a full-window panel over the office (docs/GAMEPLAY.md "Banco"): the debt, the
# interest per minute next to the rent per minute, the autopay share (NO / 10 / 25 / 50 %) with
# how long the debt takes to pay at it, and the three loans, each with its room and a Pedir or
# Devolver button. Pedir opens a sheet that shows, before signing, what you get, what you owe,
# the interest per minute against your rent and the payoff time at every autopay share.
# OfficePlay draws it on its own canvas and hands it the input.

const STATUS := Rect2(12, 86, 576, 166)
const CHIP_W := 84.0
const CHIPS_X := 218.0
const ROW_Y := 260.0
const ROW_H := 96.0
const SHEET := Rect2(12, 120, 576, 404)
const AMOUNTS: Array[float] = [0.25, 0.5, 1.0]

var game: Game
var hot := Vector2(-100, -100)
# the loan being looked at before signing, "" for none, and the share of its room asked for
var _ask := ""
var _share := 1.0
# set when the back button asks to leave the bank; OfficePlay closes the panel
var _close := false


func _init(the_game: Game) -> void:
	game = the_game


func tick() -> void:
	pass


func back() -> bool:
	if _ask != "":
		_ask = ""
		return true
	return false


func _chip(k: int) -> Rect2:
	return Rect2(CHIPS_X + k * (CHIP_W + 8.0), STATUS.position.y + 74, CHIP_W, 46)


func _row(k: int) -> Rect2:
	return Rect2(12, ROW_Y + k * ROW_H, 576, ROW_H - 8)


func _row_btn(k: int) -> Rect2:
	var r := _row(k)
	return Rect2(r.end.x - 196, r.position.y + 18, 180, 52)


func _amount_btn(k: int) -> Rect2:
	return Rect2(SHEET.position.x + 24 + k * 140, SHEET.position.y + 64, 128, 46)


func _sign_btn() -> Rect2:
	return Rect2(SHEET.end.x - 224, SHEET.end.y - 70, 200, 52)


func _cancel_btn() -> Rect2:
	return Rect2(SHEET.position.x + 24, SHEET.end.y - 70, 200, 52)


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		back()
		if _ask == "":
			_close = true
		return
	if _ask != "":
		for k in AMOUNTS.size():
			if _amount_btn(k).has_point(at):
				_share = AMOUNTS[k]
		if _cancel_btn().has_point(at):
			_ask = ""
		elif _sign_btn().has_point(at):
			var amount := _amount()
			if game.borrow(_ask, amount) == "":
				game.save()
				_ask = ""
		return
	for k in Economy.AUTOPAY.size():
		if _chip(k).has_point(at):
			game.set_autopay(Economy.AUTOPAY[k])
			game.save()
	for k in Economy.LOANS.size():
		if not _row_btn(k).has_point(at):
			continue
		var kind: String = Economy.LOANS[k]["id"]
		if game.loan_debt(kind) > 0.0:
			if game.repay(kind) > 0.0:
				game.save()
		elif game.loan_room(kind) >= Economy.LOAN_MIN:
			_ask = kind
			_share = 1.0


func wants_close() -> bool:
	return _close


func _amount() -> float:
	var room := game.loan_room(_ask)
	return maxf(Economy.LOAN_MIN, floorf(room * _share / 1000.0) * 1000.0)


func draw(c: CanvasItem) -> void:
	Ui.backdrop(c)
	Ui.header(c, "Banco", true, hot)
	var cash := Economy.money(game.money())
	Ui.text_right(c, Vector2(588, 40), cash, Ui.TEXT, Ui.GOLD)
	Ui.coin(c, Vector2(588 - Ui.text_width(cash, Ui.TEXT) - 22, 26))
	_draw_status(c)
	for k in Economy.LOANS.size():
		_draw_loan(c, k)
	Ui.text(c, Vector2(16, 556), "El interés nunca pasa del 8% de tu alquiler", Ui.SMALL, Ui.MINT,
		Ui.TEN)
	Ui.footer(c, "")
	if _ask != "":
		_draw_sheet(c)


func _draw_status(c: CanvasItem) -> void:
	Ui.panel(c, STATUS, Ui.RIM_DIM)
	var x := STATUS.position.x + 18.0
	var y := STATUS.position.y + 38.0
	var debt := game.total_debt()
	if debt > 0.0:
		Ui.text(c, Vector2(x, y), "Deuda " + Economy.money(debt), Ui.TEXT, Ui.BLOOD)
	else:
		Ui.text(c, Vector2(x, y), "Sin deudas", Ui.TEXT, Ui.MINT)
	Ui.text_right(c, Vector2(STATUS.end.x - 18, y), "Alquiler %s/min" % Economy.money(
		game.income()), Ui.TEXT, Ui.MINT, Ui.NARROW)
	var inc := game.income()
	var interest := game.interest_per_min()
	var share := interest / inc * 100.0 if inc > 0.0 else 0.0
	Ui.text(c, Vector2(x, y + 28), "Interés %s/min (%d%% de tu alquiler)" % [Economy.money(
		interest), roundi(share)], Ui.SMALL, Ui.MUTED, Ui.TEN)
	Ui.text(c, Vector2(x, y + 70), "Pago automático", Ui.TEXT, Ui.CREAM, Ui.NARROW)
	for k in Economy.AUTOPAY.size():
		var p: float = Economy.AUTOPAY[k]
		var label := "NO" if p == 0.0 else "%d%%" % roundi(p * 100.0)
		var on := absf(game.autopay() - p) < 0.001
		Ui.button(c, _chip(k), label, hot, on)
	var left := "Sin deudas que pagar"
	if debt > 0.0:
		var m := game.payoff_minutes(game.autopay())
		left = "Con el pago automático apagado la deuda no baja" if game.autopay() <= 0.0 \
			else ("Se paga sola en ~" + Economy.duration(m * 60.0) if m < INF \
			else "Sube el pago automático para pagarla")
	Ui.text(c, Vector2(x, STATUS.end.y - 14), left, Ui.SMALL, Ui.MUTED, Ui.TEN)


func _draw_loan(c: CanvasItem, k: int) -> void:
	var def: Dictionary = Economy.LOANS[k]
	var kind: String = def["id"]
	var r := _row(k)
	Ui.plate(c, r, Ui.PLATE, Ui.RIM_DIM, 13)
	var x := r.position.x + 18.0
	var b := _row_btn(k)
	var terms := "%d%% comisión · %s%%/h" % [roundi(float(def["fee"]) * 100.0),
		_pct(game.loan_rate_h(kind) * 100.0)]
	var owed := game.loan_debt(kind)
	var room := game.loan_room(kind)
	var what := "Hasta " + Economy.money(room)
	# the mortgage grows with what your lots are worth: say so, rather than show a tiny cap
	if game.loan_by_worth(kind) and room >= Economy.LOAN_MIN:
		what += " (50% de tus terrenos)"
	var tone := Ui.CREAM
	if owed > 0.0:
		what = "Debes " + Economy.money(owed)
		tone = Ui.BLOOD
	elif room < Economy.LOAN_MIN:
		what = "Tus alquileres no dan para más"
		tone = Ui.MUTED
	Ui.text(c, Vector2(x, r.position.y + 30), def["name"], Ui.TEXT, Ui.GOLD)
	Ui.text(c, Vector2(x, r.position.y + 54), terms, Ui.SMALL, Ui.MUTED, Ui.TEN)
	Ui.text(c, Vector2(x, r.position.y + 78), what, Ui.SMALL, tone, Ui.TEN)
	if owed > 0.0:
		var can := minf(owed, game.money())
		Ui.button(c, b, "Devolver " + Economy.money(can) if can > 0.0 else "Devolver", hot, false,
			can <= 0.0, Ui.NARROW)
	else:
		Ui.button(c, b, "Pedir", hot, false, room < Economy.LOAN_MIN)


func _draw_sheet(c: CanvasItem) -> void:
	c.draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color(Ui.VOID, 0.6))
	Ui.panel(c, SHEET, Ui.GOLD)
	var def := Economy.loan_def(_ask)
	var x := SHEET.position.x + 24.0
	Ui.text(c, Vector2(x, SHEET.position.y + 42), "Préstamo " + String(def["name"]), Ui.TEXT,
		Ui.CREAM)
	for k in AMOUNTS.size():
		var label := "Máx" if AMOUNTS[k] >= 1.0 else "%d%%" % roundi(AMOUNTS[k] * 100.0)
		Ui.button(c, _amount_btn(k), label, hot, absf(_share - AMOUNTS[k]) < 0.001)
	var amount := _amount()
	var debt := amount * (1.0 + float(def["fee"]))
	var rate := game.loan_rate_h(_ask)
	var interest := debt * rate / 60.0
	var y := SHEET.position.y + 150.0
	Ui.text(c, Vector2(x, y), "Recibes " + Economy.money(amount), Ui.TEXT, Ui.GOLD)
	Ui.text(c, Vector2(x, y + 30), "Debes %s (comisión %d%%)" % [Economy.money(debt),
		roundi(float(def["fee"]) * 100.0)], Ui.TEXT, Ui.BLOOD, Ui.NARROW)
	Ui.text(c, Vector2(x, y + 60), "Interés %s/min · tu alquiler %s/min" % [Economy.money(
		interest), Economy.money(game.income())], Ui.TEXT, Ui.CREAM, Ui.NARROW)
	Ui.text(c, Vector2(x, y + 92), "Se paga sola con el pago automático al:", Ui.SMALL,
		Ui.MUTED, Ui.TEN)
	var shares: Array[float] = [0.10, 0.25, 0.50]
	for k in shares.size():
		var m := game.payoff_minutes(shares[k], debt, rate)
		var when := "~" + Economy.duration(m * 60.0) if m < INF else "nunca"
		var row := Vector2(x + 20.0, y + 118.0 + k * 24.0)
		Ui.text(c, row, "%d%%" % roundi(shares[k] * 100.0), Ui.SMALL, Ui.GOLD, Ui.TEN)
		Ui.text(c, row + Vector2(60, 0), when, Ui.SMALL, Ui.CREAM, Ui.TEN)
	Ui.button(c, _cancel_btn(), "Cancelar", hot)
	Ui.button(c, _sign_btn(), "Firmar", hot, true)


static func _pct(v: float) -> String:
	if absf(v - roundf(v)) < 0.05:
		return "%d" % roundi(v)
	return ("%.2f" % v).rstrip("0").replace(".", ",")
