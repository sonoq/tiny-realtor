class_name PlungeGame
extends JobGame

# "Váter atascado": a marker sweeps to and fro along a gauge under the toilet; push (press
# anywhere, or the big button) while it is inside the gold zone. Each good push sends the plunger
# down with a "¡GLUB!", the muddy water drops a step and clears, and the next zone is narrower and
# the marker quicker; a push outside it splashes ("¡CHOF!") and the plunger needs a moment
# before it can push again, so mashing does not pay. GOAL good pushes flush it.

const GOAL := 6
const GAUGE := Rect2(64, 416, 472, 40)
const PUSH := Rect2(170, 468, 260, 56)
const MARK_W := 12.0
# sweeps across and back per second, at the start and added per good push
const SPEED0 := 0.55
const SPEED_UP := 0.07
const ZONE0 := 0.24
const ZONE_MIN := 0.13
const MISS_WAIT := 0.45
const PUSH_S := 0.22
const TOILET_AT := Vector2(220, 160)
const PX := 8.0
const TOILET: Array[String] = [
	"....kkkkkkkkkkkk....",
	"...kwwwwwwwwwwwwk...",
	"....kkkkkkkkkkkk....",
	"....kwwwwwwwwwlk....",
	"....kwskwwwwwwlk....",
	"....kwwwwwwwwwlk....",
	"....kllllllllllk....",
	"..kkkkkkkkkkkkkkkk..",
	".kwwwwwwwwwwwwwwwwk.",
	"kwwkkkkkkkkkkkkkkwwk",
	"kwk11111111111111kwk",
	"kwk22222222222222kwk",
	".kwk333333333333kwk.",
	".klwk4444444444kwlk.",
	"..klwkkkkkkkkkkwlk..",
	"...kllwwwwwwwwllk...",
	"....ksllllllllsk....",
	".....ksslllllsk.....",
	"......kssssssk......",
	".....kkkkkkkkkk.....",
	"....kssssssssssk....",
	"....kkkkkkkkkkkk....",
]

var good := 0
var misses := 0
var _x := 0.0
var _dir := 1.0
var _speed := SPEED0
var _zone := 0.5
var _zone_w := ZONE0
var _push_t := -10.0
var _wait_until := -10.0
var _splash_t := -10.0
var _glub_t := -10.0


func setup() -> void:
	_new_zone()


func how() -> String:
	return "Pulsa cuando la marca pase por la zona dorada"


func hint() -> String:
	return "Pulsa en el dorado · %d/%d" % [good, GOAL]


func score() -> float:
	return float(good) / GOAL


func marker() -> float:
	return _x


# the gauge's gold zone: [from, to] in 0..1
func zone() -> Vector2:
	return Vector2(_zone - _zone_w * 0.5, _zone + _zone_w * 0.5)


func ready_to_push() -> bool:
	return t >= _wait_until and not over


func _new_zone() -> void:
	var from := _zone_w * 0.5 + 0.04
	var c := rng.randf_range(from, 1.0 - from)
	# far enough from the last one that the eye has to follow
	if absf(c - _zone) < 0.2:
		c = clampf(1.0 - c, from, 1.0 - from)
	_zone = c


func advance(dt: float) -> void:
	_x += _dir * _speed * 2.0 * dt
	while _x > 1.0 or _x < 0.0:
		if _x > 1.0:
			_x = 2.0 - _x
			_dir = -1.0
		else:
			_x = -_x
			_dir = 1.0


func press(at: Vector2) -> void:
	if not AREA.has_point(at) or not ready_to_push():
		return
	_push_t = t
	var z := zone()
	var half := MARK_W * 0.5 / GAUGE.size.x
	if _x + half >= z.x and _x - half <= z.y:
		good += 1
		_glub_t = t
		_pop("¡GLUB!", TOILET_AT + Vector2(80, -10), Ui.MINT)
		if good >= GOAL:
			_win()
			return
		_speed += SPEED_UP
		_zone_w = maxf(ZONE_MIN, _zone_w - 0.02)
		_new_zone()
		_wait_until = t + 0.12
	else:
		misses += 1
		_splash_t = t
		_wait_until = t + MISS_WAIT
		_pop("¡CHOF!", TOILET_AT + Vector2(80, -10), Ui.BLOOD)


func draw(c: CanvasItem) -> void:
	c.draw_rect(AREA, Ui.SL1)
	# bathroom tiles behind, a floor under
	for j in 6:
		for i in 12:
			var r := Rect2(AREA.position + Vector2(i * 48, j * 48), Vector2(46, 46))
			if r.end.y < AREA.position.y + 226:
				c.draw_rect(r, Ui.SL2 if (i + j) % 2 == 0 else Ui.STEEL.darkened(0.25))
	c.draw_rect(Rect2(AREA.position.x, AREA.position.y + 226, AREA.size.x, AREA.size.y - 226),
		Ui.SL0)
	_draw_toilet(c)
	_draw_plunger(c)
	_draw_progress(c)
	_draw_gauge(c)
	var can := ready_to_push()
	Ui.button(c, PUSH, "¡Empuja!", hot, can, not can)
	_draw_pops(c)


func _water() -> Array[Color]:
	var cols: Array[Color] = [Pal.c("DIRT_D"), Pal.c("DIRT"), Pal.c("DIRT_L"), Pal.c("CYAN_D"),
		Pal.c("CYAN_M"), Pal.c("CYAN_M"), Pal.c("CYAN")]
	var k := clampi(good, 0, cols.size() - 1)
	return [cols[k], cols[mini(k + 1, cols.size() - 1)]]


func _draw_toilet(c: CanvasItem) -> void:
	var w := _water()
	# water rows 1..4 from the top: muddy and brimming at first, a row lower every two pushes
	var level := 4 - floori(good * 4.0 / GOAL)
	var keys := {"k": Ui.VOID, "w": Pal.c("CRM0"), "l": Pal.c("CRM1"), "s": Pal.c("STN2")}
	for r in 4:
		keys[str(r + 1)] = w[0] if 4 - r <= level else Pal.c("CRM2")
	# a wobble when the plunger lands
	var shake := Vector2.ZERO
	if t - _push_t < 0.12:
		shake = Vector2(0, 4)
	JobGame.sprite(c, TOILET, TOILET_AT + shake, PX, keys)
	var top := TOILET_AT + shake + Vector2(3, 10) * PX
	if level > 0:
		# a glint on the water
		c.draw_rect(Rect2(top + Vector2(PX * 2, (4 - level) * PX), Vector2(PX * 3, PX * 0.5)),
			w[1])
	# bubbles after a good push, mud drops after a splash
	var gb := t - _glub_t
	if gb >= 0.0 and gb < 0.6:
		for k in 3:
			var p := top + Vector2(40 + k * 34, -floorf(gb * 10.0) * 6.0 - k * 8)
			c.draw_rect(Rect2(p, Vector2(8, 8)), Ui.VOID)
			c.draw_rect(Rect2(p + Vector2(2, 2), Vector2(4, 4)), Pal.c("CYAN"))
	var sp := t - _splash_t
	if sp >= 0.0 and sp < 0.45:
		for k in 5:
			var vx := (k - 2) * 60.0
			var p := top + Vector2(76 + vx * sp, -220.0 * sp + 420.0 * sp * sp - 8)
			c.draw_rect(Rect2(p.round(), Vector2(8, 8)), Ui.VOID)
			c.draw_rect(Rect2(p.round() + Vector2(2, 2), Vector2(4, 4)), Pal.c("DIRT"))
	if won:
		# the flush: the clear water swirls down
		var a := since * 12.0
		for k in 6:
			var ang := a + k * TAU / 6.0
			var p := top + Vector2(80, 16) + Vector2(cos(ang) * 44.0, sin(ang) * 10.0)
			c.draw_rect(Rect2((p / 4.0).round() * 4.0, Vector2(8, 4)), Pal.c("CREAM"))


func _draw_plunger(c: CanvasItem) -> void:
	var down := 0.0
	var pt := t - _push_t
	if pt >= 0.0 and pt < PUSH_S:
		down = 28.0 * (1.0 - absf(pt / PUSH_S * 2.0 - 1.0))
	if won:
		down = -minf(since, 0.4) * 120.0
	var x := TOILET_AT.x + 10.0 * PX
	var cup_y := TOILET_AT.y + 9.0 * PX + roundf(down / 4.0) * 4.0 - 22.0
	# the handle up out of the frame of the tank, the red rubber cup on the water
	JobGame.inked(c, Rect2(x - 6, AREA.position.y + 6, 12, cup_y - AREA.position.y - 6),
		Pal.c("WOOD"), 4.0)
	c.draw_rect(Rect2(x - 6, AREA.position.y + 6, 4, cup_y - AREA.position.y - 6),
		Pal.c("DIRT_L"))
	var cup := Rect2(x - 36, cup_y, 72, 28)
	JobGame.inked(c, cup, Ui.RED)
	c.draw_rect(Rect2(cup.position, Vector2(cup.size.x, 8)), Ui.BLOOD)
	c.draw_rect(Rect2(cup.position + Vector2(-8, cup.size.y - 8), Vector2(cup.size.x + 16, 8)),
		Pal.c("RED_M"))


func _draw_progress(c: CanvasItem) -> void:
	var w := 28.0
	var x0 := AREA.get_center().x - (GOAL * (w + 8.0) - 8.0) * 0.5
	for k in GOAL:
		var r := Rect2(x0 + k * (w + 8.0), GAUGE.position.y - 46, w, 20)
		JobGame.inked(c, r, Ui.MINT if k < good else Ui.SL2, 2.0)


func _draw_gauge(c: CanvasItem) -> void:
	JobGame.inked(c, GAUGE, Ui.SUNKEN)
	var z := zone()
	var zr := Rect2(GAUGE.position.x + GAUGE.size.x * z.x, GAUGE.position.y + 4,
		GAUGE.size.x * (z.y - z.x), GAUGE.size.y - 8)
	zr.position.x = roundf(zr.position.x / 2.0) * 2.0
	zr.size.x = roundf(zr.size.x / 2.0) * 2.0
	c.draw_rect(zr, Ui.GOLD)
	c.draw_rect(Rect2(zr.position, Vector2(zr.size.x, 4)), Ui.CREAM)
	c.draw_rect(Rect2(zr.position + Vector2(0, zr.size.y - 4), Vector2(zr.size.x, 4)),
		Ui.GOLD_M)
	var mx := roundf((GAUGE.position.x + GAUGE.size.x * _x - MARK_W * 0.5) / 2.0) * 2.0
	var mr := Rect2(mx, GAUGE.position.y - 8, MARK_W, GAUGE.size.y + 16)
	JobGame.inked(c, mr, Ui.CYAN if ready_to_push() else Ui.MUTED, 2.0)
