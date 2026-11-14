class_name JobGame
extends RefCounted

# One tenant job's minigame (docs/GAMEPLAY.md "Encargos"): a short play of JOB_S seconds with its
# own clock, a score 0..1 and pixel-art drawing in style A's UI colours. JobPanel shows it under
# its header, steps it every frame and hands it the pointer: press (button down: what the games
# act on, so timing feels immediate), click (released without moving), drag (moved while held)
# and `hot`. Everything random comes from the event's seed, so a job plays the same every time
# and the tools can drive it like a player.

# where a game draws: under the header and the time bar, above the hint line
const AREA := Rect2(12, 112, 576, 420)
# how long a finished game keeps showing (its flush, spark or full facade) before the result
const OUTRO_S := 0.9

var seed := 0
var t := 0.0
var limit := Economy.JOB_S
var over := false
var won := false
# seconds since it ended
var since := 0.0
var hot := Vector2(-100, -100)
var rng := RandomNumberGenerator.new()
# short words that pop and rise: [text, at, born, colour]
var _pops: Array = []


func _init(the_seed: int) -> void:
	seed = the_seed
	rng.seed = the_seed
	setup()


func setup() -> void:
	pass


func step(dt: float) -> void:
	if over:
		since += dt
		return
	t += dt
	advance(dt)
	if t >= limit and not over:
		t = limit
		over = true


func advance(_dt: float) -> void:
	pass


func press(_at: Vector2) -> void:
	pass


func click(_at: Vector2) -> void:
	pass


func drag(_at: Vector2) -> void:
	pass


func score() -> float:
	return 0.0


func left() -> float:
	return maxf(0.0, limit - t)


# the line under the game: what to do
func hint() -> String:
	return ""


# what the intro says the job is about
func how() -> String:
	return ""


func draw(_c: CanvasItem) -> void:
	pass


func _win() -> void:
	won = true
	over = true


func _pop(text: String, at: Vector2, color: Color) -> void:
	# one that comes while the last still rises goes beside it, not on it
	var now := t + since
	if not _pops.is_empty() and now - float(_pops[-1][2]) < 0.8 \
			and (_pops[-1][1] as Vector2).distance_to(at) < 30.0:
		at += Vector2(-90.0 if (_pops[-1][1] as Vector2).x >= at.x else 90.0, 0)
	_pops.append([text, at, now, color])


func _draw_pops(c: CanvasItem) -> void:
	var now := t + since
	for p: Array in _pops:
		var age := now - float(p[2])
		if age < 0.0 or age > 0.8:
			continue
		var rise := floorf(age * 10.0) * 3.0
		var w := Ui.text_width(p[0], Ui.TEXT)
		Ui.text(c, ((p[1] as Vector2) - Vector2(w * 0.5, rise)).round(), p[0], Ui.TEXT, p[3])


# a pixel sprite from rows of characters, each mapped to a colour by `keys` ("." is clear)
static func sprite(c: CanvasItem, rows: Array, at: Vector2, px: float, keys: Dictionary) -> void:
	for j in rows.size():
		var row: String = rows[j]
		var i := 0
		while i < row.length():
			var ch := row[i]
			if ch == "." or not keys.has(ch):
				i += 1
				continue
			# runs of one colour in one rect
			var k := i
			while k < row.length() and row[k] == ch:
				k += 1
			c.draw_rect(Rect2(at + Vector2(i, j) * px, Vector2((k - i) * px, px)), keys[ch])
			i = k


# a rect with a one-pixel-block ink rim around it
static func inked(c: CanvasItem, r: Rect2, color: Color, rim: float = 4.0) -> void:
	c.draw_rect(r.grow(rim), Ui.VOID)
	c.draw_rect(r, color)


# a thick pixel line from a to b in square dots of `w` on a `w` grid, inked
static func thick(c: CanvasItem, pts: PackedVector2Array, w: float, color: Color) -> void:
	for pass_k in 2:
		var size := w + (4.0 if pass_k == 0 else 0.0)
		var col := Ui.VOID if pass_k == 0 else color
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var n := maxi(1, ceili(a.distance_to(b) / (w * 0.5)))
			for s in n + 1:
				var p := (a.lerp(b, float(s) / n) / 2.0).round() * 2.0
				c.draw_rect(Rect2(p - Vector2(size, size) * 0.5, Vector2(size, size)), col)
