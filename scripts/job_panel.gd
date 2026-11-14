class_name JobPanel
extends RefCounted

# A tenant job, a full-window panel over the office like the bank (docs/GAMEPLAY.md
# "Encargos"): first what it is and what it pays (a perfect job, and what even a failed one
# pays), then the minigame (JobGame) under a time bar, then the result with the money. The pay
# is made when the game ends, before the result shows, so leaving at any point never loses what
# was earned: back during the game ends it with the score so far; back on the first page leaves
# the job waiting. OfficePlay draws it on its own canvas, steps it every frame and hands it the
# input (press / drag / click / hover).

enum { INTRO, PLAY, DONE }
const TIME_BAR := Rect2(84, 86, 504, 18)
const INTRO_CARD := Rect2(48, 150, 504, 300)
const GO_BTN := Rect2(170, 372, 260, 60)
const DONE_CARD := Rect2(60, 160, 480, 290)
const OK_BTN := Rect2(200, 374, 200, 56)
# a short "¡Ya!" before the clock starts, so the tap on EMPEZAR is not the first move
const READY_S := 0.7
const TITLES := {"plunge": "Váter atascado", "wires": "Sin luz en casa",
	"bulbs": "Bombillas fundidas"}

var game: Game
var id := ""
var ev: Dictionary
var street := ""
var job: JobGame
var page := INTRO
var hot := Vector2(-100, -100):
	set(v):
		hot = v
		if job != null:
			job.hot = v
var paid := -1.0
var paused := false
var _ready_t := 0.0
var _close := false


func _init(the_game: Game, office_id: String, event: Dictionary, street_name: String) -> void:
	game = the_game
	id = office_id
	ev = event.duplicate()
	street = street_name
	job = make(ev.get("game", "plunge"), int(ev.get("seed", 1)))


static func make(kind: String, seed: int) -> JobGame:
	match kind:
		"wires":
			return WiresGame.new(seed)
		"bulbs":
			return BulbsGame.new(seed)
	return PlungeGame.new(seed)


static func title_of(kind: String) -> String:
	return TITLES.get(kind, "Encargo")


func tick() -> void:
	pass


# true while the game runs: OfficePlay redraws every frame
func live() -> bool:
	return page == PLAY


# OfficePlay's frame-by-frame stepping; tools that film a job set `paused` and call run()
func step(dt: float) -> void:
	if not paused:
		run(dt)


func run(dt: float) -> void:
	if page != PLAY:
		return
	if _ready_t < READY_S:
		_ready_t += dt
		return
	job.step(dt)
	if job.over and job.since >= JobGame.OUTRO_S:
		_finish()


func playing() -> bool:
	return page == PLAY and _ready_t >= READY_S and not job.over


func start() -> void:
	if page == INTRO:
		page = PLAY
		_ready_t = 0.0


func press(at: Vector2) -> void:
	if playing() and not Ui.BACK_RECT.has_point(at):
		job.press(at)


func drag(at: Vector2) -> void:
	if playing():
		job.drag(at)


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		if not back():
			_close = true
		return
	match page:
		INTRO:
			if GO_BTN.has_point(at):
				start()
		PLAY:
			if playing():
				job.click(at)
		DONE:
			if OK_BTN.has_point(at):
				_close = true


func back() -> bool:
	if page == PLAY:
		_finish()
		return true
	return false


func wants_close() -> bool:
	return _close


# the game is over (or given up): pay now, then show the result
func _finish() -> void:
	if page == DONE:
		return
	paid = Events.finish_job(game, id, int(ev["n"]), job.score())
	game.save()
	page = DONE


func draw(c: CanvasItem) -> void:
	Ui.backdrop(c)
	match page:
		INTRO:
			_draw_intro(c)
		PLAY:
			_draw_play(c)
		DONE:
			_draw_done(c)
	Ui.header(c, title_of(ev.get("game", "")), true, hot, 588.0 if page != PLAY else 470.0)
	Ui.footer(c, "")


func _draw_intro(c: CanvasItem) -> void:
	# the game as it starts, dimmed behind the card
	job.draw(c)
	c.draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color(Ui.VOID, 0.55))
	Ui.panel(c, INTRO_CARD, Ui.GOLD)
	var x := INTRO_CARD.position.x + 22.0
	var y := INTRO_CARD.position.y + 40.0
	_fit(c, Vector2(x, y), "Inquilino de " + street, INTRO_CARD.size.x - 44.0, Ui.CREAM)
	var lines := wrap_text(job.how() + " · %d s" % roundi(job.limit), INTRO_CARD.size.x - 44.0)
	for k in mini(2, lines.size()):
		Ui.text(c, Vector2(x, y + 32 + k * 24), lines[k], Ui.SMALL, Ui.MUTED, Ui.TEN)
	Ui.coin(c, Vector2(x, y + 86))
	Ui.text(c, Vector2(x + 24, y + 106), "Perfecto: +" + Economy.money(Events.job_pay(game, ev,
		1.0)), Ui.TEXT, Ui.GOLD)
	Ui.text(c, Vector2(x, y + 136), "A medias, menos · si no sale, +%s" % Economy.money(
		Events.job_pay(game, ev, 0.0)), Ui.SMALL, Ui.MUTED, Ui.TEN)
	Ui.button(c, GO_BTN, "Empezar", hot, true)


func _draw_play(c: CanvasItem) -> void:
	job.draw(c)
	var left := job.left()
	var frac := left / job.limit
	Ui.bar(c, TIME_BAR, frac, Ui.GOLD if left > 3.0 else Ui.BLOOD)
	var secs := "%d s" % ceili(left)
	Ui.text_right(c, Vector2(TIME_BAR.end.x - 6, TIME_BAR.position.y - 4), secs, Ui.SMALL,
		Ui.CREAM, Ui.TEN)
	_fit(c, Vector2(16, 556), job.hint(), 568.0, Ui.MUTED, Ui.SMALL)
	if _ready_t < READY_S:
		Ui.text_in(c, Rect2(0, 260, 600, 80), "¡Ya!", Ui.BIG, Ui.GOLD)


func _draw_done(c: CanvasItem) -> void:
	job.draw(c)
	c.draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color(Ui.VOID, 0.6))
	Ui.panel(c, DONE_CARD, Ui.GOLD)
	var s := job.score()
	var head := "¡Perfecto!" if s >= 0.999 else ("¡Bien hecho!" if s >= 0.5 else
		("A medias" if s > 0.0 else "No ha salido"))
	Ui.text_in(c, Rect2(DONE_CARD.position + Vector2(0, 16), Vector2(DONE_CARD.size.x, 44)),
		head, Ui.BIG, Ui.CREAM if s > 0.0 else Ui.MUTED)
	# three stars by the score
	var n := 3 if s >= 0.999 else (2 if s >= 0.5 else (1 if s > 0.0 else 0))
	for k in 3:
		var at := Vector2(DONE_CARD.get_center().x - 96 + k * 72, DONE_CARD.position.y + 80)
		_star(c, at, Ui.GOLD if k < n else Ui.SL2)
	var money := "+" + Economy.money(maxf(0.0, paid))
	var w := Ui.text_width(money, Ui.BIG) + 24.0
	var mx := DONE_CARD.get_center().x - w * 0.5
	Ui.coin(c, Vector2(mx, DONE_CARD.position.y + 138))
	Ui.text(c, Vector2(mx + 24, DONE_CARD.position.y + 160), money, Ui.BIG, Ui.GOLD)
	Ui.text_in(c, Rect2(DONE_CARD.position.x, DONE_CARD.position.y + 170, DONE_CARD.size.x, 24),
		"El inquilino te paga", Ui.SMALL, Ui.MUTED, Ui.TEN)
	Ui.button(c, OK_BTN, "¡Bien!", hot, true)


static func _star(c: CanvasItem, at: Vector2, color: Color) -> void:
	var rows: Array[String] = ["...11...", "...11...", "11111111", ".111111.", "..1111..",
		".111111.", ".11..11.", "11....11"]
	JobGame.sprite(c, rows, at + Vector2(-2, -2), 6.0, {"1": Ui.VOID})
	JobGame.sprite(c, rows, at + Vector2(2, 2), 6.0, {"1": Ui.VOID})
	JobGame.sprite(c, rows, at, 6.0, {"1": color})


# words in lines that fit `room` in the small font
static func wrap_text(s: String, room: float) -> Array[String]:
	var out: Array[String] = []
	var line := ""
	for word in s.split(" ", false):
		var next := word if line == "" else line + " " + word
		if line != "" and Ui.text_width(next, Ui.SMALL, Ui.TEN) > room:
			out.append(line)
			line = word
		else:
			line = next
	if line != "":
		out.append(line)
	return out


static func _fit(c: CanvasItem, at: Vector2, s: String, room: float, color: Color,
		size: int = Ui.TEXT) -> void:
	var kind := Ui.BOLD if size == Ui.TEXT else Ui.TEN
	if Ui.text_width(s, size, kind) > room and size == Ui.TEXT:
		kind = Ui.NARROW
	var line := s
	var cut := s.length()
	while cut > 3 and Ui.text_width(line, size, kind) > room:
		cut -= 1
		line = s.left(cut).strip_edges() + "…"
	Ui.text(c, at, line, size, color, kind)
