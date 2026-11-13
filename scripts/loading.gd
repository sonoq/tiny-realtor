class_name Loading
extends Screen

# What the player sees while a city map or an office area downloads and bakes: what is
# happening in plain words, how much has arrived, a spinner, and a way out. When every server
# failed it says so and offers to try again.

const BOX := Rect2(36, 150, 528, 330)
const RETRY := Rect2(64, 398, 230, 56)
const LEAVE := Rect2(306, 398, 230, 56)
# the spinner: eight blocks chasing round, like a tiny city going up
const BLOCK := 12.0
const RING_R := 34.0

var title := ""
var status := ""
var bytes := 0
var error := ""
var _t := 0.0


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func press(at: Vector2) -> bool:
	return Ui.BACK_RECT.has_point(at) or (error != "" and (RETRY.has_point(at)
		or LEAVE.has_point(at)))


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at) or (error != "" and LEAVE.has_point(at)):
		back()
	elif error != "" and RETRY.has_point(at):
		_t = 0.0
		app.retry_job()


func back() -> bool:
	app.cancel_job()
	return true


func _draw() -> void:
	Ui.backdrop(self)
	Ui.panel(self, BOX, Ui.RED if error != "" else Ui.RIM_DIM)
	Ui.text_in(self, Rect2(BOX.position.x, BOX.position.y + 22, BOX.size.x, 30), title, Ui.TEXT,
		Ui.GOLD)
	if error == "":
		var c := (BOX.get_center() + Vector2(0, -24)).round()
		for i in 8:
			var a := TAU * i / 8.0
			var lit := fposmod(_t * 8.0 - i, 8.0)
			var tone := Ui.GOLD
			if lit > 1.0:
				tone = Ui.GOLD_M if lit < 3.0 else Ui.STEEL
			var at := (c + Vector2(cos(a), sin(a)) * RING_R - Vector2.ONE * BLOCK * 0.5)
			at = (at / 2.0).round() * 2.0
			draw_rect(Rect2(at - Vector2(2, 2), Vector2.ONE * (BLOCK + 4)), Ui.VOID)
			draw_rect(Rect2(at, Vector2.ONE * BLOCK), tone)
		Ui.text_in(self, Rect2(BOX.position.x + 10, BOX.position.y + 214, BOX.size.x - 20, 26),
			status, Ui.TEXT, Ui.CREAM, Ui.NARROW)
		var got := "Recibido: %s" % Ui.size_text(bytes) if bytes > 0 else "Esperando al servidor…"
		# the public servers can take minutes; a ticking clock shows nothing is stuck
		got += "  ·  %d s" % int(_t)
		Ui.text_in(self, Rect2(BOX.position.x, BOX.position.y + 250, BOX.size.x, 24), got,
			Ui.SMALL, Ui.MUTED, Ui.TEN)
		Ui.text_in(self, Rect2(BOX.position.x, BOX.position.y + 280, BOX.size.x, 24),
			"Solo se descarga una vez", Ui.SMALL, Ui.MUTED, Ui.TEN)
	else:
		var y := BOX.position.y + 76
		for line in _wrap(Ui.caps(error), 34):
			Ui.text_in(self, Rect2(BOX.position.x, y, BOX.size.x, 26), line, Ui.TEXT, Ui.CREAM,
				Ui.NARROW)
			y += 32
		Ui.button(self, RETRY, "Reintentar", hot, true)
		Ui.button(self, LEAVE, "Volver", hot)
	Ui.header(self, "Descargando", true, hot)
	Ui.footer(self, "")


static func _wrap(s: String, width: int) -> Array[String]:
	var out: Array[String] = []
	var line := ""
	for word in s.split(" "):
		if line.length() + word.length() + 1 > width and line != "":
			out.append(line)
			line = word
		else:
			line = word if line == "" else line + " " + word
	if line != "":
		out.append(line)
	return out
