class_name Loading
extends Screen

# What the player sees while a city map or an office area downloads and bakes: what is
# happening in plain words, how much has arrived, a spinner, and a way out. When every server
# failed it says so and offers to try again.

const RETRY := Rect2(150, 380, 140, 48)
const LEAVE := Rect2(310, 380, 140, 48)
const BOX := Rect2(60, 170, 480, 280)

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
	draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color("#16131d"))
	Ui.panel(self, BOX)
	Ui.text_in(self, Rect2(BOX.position.x, BOX.position.y + 18, BOX.size.x, 30), title, 18, Ui.GOLD)
	if error == "":
		# eight blocks chasing round, like a tiny city being built
		var c := BOX.get_center() + Vector2(0, -10)
		for i in 8:
			var a := TAU * i / 8.0
			var lit := fposmod(_t * 8.0 - i, 8.0)
			var tone := Ui.GOLD.lerp(Ui.EDGE, clampf(lit / 6.0, 0.0, 1.0))
			draw_rect(Rect2(c + Vector2(cos(a), sin(a)) * 26.0 - Vector2(5, 5), Vector2(10, 10)),
				tone)
		Ui.text_in(self, Rect2(BOX.position.x + 10, BOX.position.y + 186, BOX.size.x - 20, 24),
			status, Ui.FONT_SIZE, Ui.INK)
		var got := "Recibido: %s" % Ui.size_text(bytes) if bytes > 0 else "Esperando al servidor…"
		# the public servers can take minutes; a ticking clock shows nothing is stuck
		got += "  ·  %d s" % int(_t)
		Ui.text_in(self, Rect2(BOX.position.x, BOX.position.y + 214, BOX.size.x, 24), got,
			Ui.SMALL, Ui.DIM)
		Ui.text_in(self, Rect2(BOX.position.x, BOX.position.y + 240, BOX.size.x, 24),
			"Solo se descarga una vez y se guarda para siempre.", Ui.SMALL, Ui.DIM)
	else:
		var y := BOX.position.y + 80
		for line in _wrap(error, 44):
			Ui.text_in(self, Rect2(BOX.position.x, y, BOX.size.x, 24), line, Ui.FONT_SIZE, Ui.INK)
			y += 24
		Ui.button(self, RETRY, "Reintentar", hot, true)
		Ui.button(self, LEAVE, "Volver", hot)
	Ui.header(self, "Descargando mapa", true, hot)
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
