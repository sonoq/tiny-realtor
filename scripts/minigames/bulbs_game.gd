class_name BulbsGame
extends JobGame

# "Bombillas fundidas": your building's front at night, its windows lit gold; some have gone dark
# with a dead bulb hanging in them. Tap a dark window to put a new bulb in. More go out as you
# play (each flickers for a moment first, so it is fair); fix every one that went out. The score
# is the share fixed; when the last one is in and no more are due, the whole front glows.

const COLS := 5
const ROWS := 4
const WIN := Vector2(52, 52)
const STEP := Vector2(68, 70)
const FRONT := Rect2(120, 146, 360, 366)
const FIRST := Vector2(138, 180)
# windows dark at the start, then one more at each of these seconds
const START_DARK := 4
const BURNS: Array[float] = [1.8, 3.3, 4.8, 6.3, 7.6, 8.9, 10.2, 11.4]
const FLICKER_S := 0.6

# per window: 0 lit, 1 dark, 2 fixed
var state: Array[int] = []
var fixed := 0
var went_out := 0
# per window: when it is due to go out (-1 none)
var due: Array[float] = []
var _fix_t: Array[float] = []
var _stars: Array[Vector2] = []


func setup() -> void:
	for k in COLS * ROWS:
		state.append(0)
		due.append(-1.0)
		_fix_t.append(-10.0)
	var order: Array[int] = []
	for k in COLS * ROWS:
		order.append(k)
	for i in range(order.size() - 1, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	for k in START_DARK:
		state[order[k]] = 1
		went_out += 1
	# the later ones, in the shuffled order after the first dark ones
	for k in BURNS.size():
		due[order[START_DARK + k]] = BURNS[k]
	for k in 18:
		_stars.append(Vector2(rng.randf_range(AREA.position.x + 8, AREA.end.x - 8),
			rng.randf_range(AREA.position.y + 6, FRONT.position.y - 8)))


func how() -> String:
	return "Toca las ventanas apagadas para cambiar la bombilla"


func hint() -> String:
	return "Cambia las bombillas fundidas · %d" % dark()


func dark() -> int:
	return state.count(1)


func score() -> float:
	return float(fixed) / maxf(1.0, went_out)


func window(k: int) -> Rect2:
	return Rect2(FIRST + Vector2(k % COLS, k / COLS) * STEP, WIN)


# the box a press counts in: the window and a margin round it, over MIN_HIT
func hit(k: int) -> Rect2:
	return window(k).grow(8.0)


func advance(_dt: float) -> void:
	for k in due.size():
		if due[k] >= 0.0 and t >= due[k] and state[k] != 1:
			state[k] = 1
			due[k] = -1.0
			went_out += 1
	if dark() == 0 and _none_due():
		_win()


func _none_due() -> bool:
	for d in due:
		if d >= 0.0:
			return false
	return true


func press(at: Vector2) -> void:
	if over:
		return
	for k in state.size():
		if state[k] == 1 and hit(k).has_point(at):
			state[k] = 2
			fixed += 1
			_fix_t[k] = t
			_pop("¡LUZ!", window(k).get_center() + Vector2(0, -20), Ui.GOLD)
			if dark() == 0 and _none_due():
				_win()
			return


func draw(c: CanvasItem) -> void:
	c.draw_rect(AREA, Ui.VOID)
	for s in _stars:
		c.draw_rect(Rect2(s.round(), Vector2(2, 2)), Ui.CREAM if int(s.x) % 3 else Ui.MUTED)
	# the moon
	JobGame.sprite(c, ["..111", ".11..", "11...", "11...", "11...", ".11..", "..111"],
		Vector2(AREA.end.x - 64, AREA.position.y + 4), 4.0, {"1": Pal.c("CRM1")})
	# the street, the building and its cornice
	c.draw_rect(Rect2(AREA.position.x, FRONT.end.y - 8, AREA.size.x, AREA.end.y - FRONT.end.y + 8),
		Ui.SL1)
	JobGame.inked(c, FRONT, Pal.c("TER2"))
	for j in range(0, int(FRONT.size.y), 12):
		c.draw_rect(Rect2(FRONT.position.x, FRONT.position.y + j, FRONT.size.x, 2), Pal.c("TER3"))
	c.draw_rect(Rect2(FRONT.position.x - 12, FRONT.position.y - 4, FRONT.size.x + 24, 22),
		Ui.VOID)
	c.draw_rect(Rect2(FRONT.position.x - 8, FRONT.position.y, FRONT.size.x + 16, 14),
		Pal.c("STN1"))
	# the door
	var door := Rect2(FRONT.get_center().x - 30, FRONT.end.y - 62, 60, 62)
	JobGame.inked(c, door, Pal.c("WOOD"))
	c.draw_rect(Rect2(door.position + Vector2(8, 8), Vector2(44, 20)), Ui.GOLD_M)
	for k in state.size():
		_window(c, k)
	_draw_pops(c)


func _window(c: CanvasItem, k: int) -> void:
	var r := window(k)
	var lit := state[k] != 1
	# about to go out: it flickers first
	if state[k] == 0 and due[k] >= 0.0 and t > due[k] - FLICKER_S:
		lit = int(t * 14.0) % 2 == 0
	c.draw_rect(r.grow(4), Ui.VOID)
	if lit:
		var fresh := t - _fix_t[k] < 0.3
		c.draw_rect(r, Ui.CREAM if fresh else Ui.GOLD)
		c.draw_rect(Rect2(r.position, Vector2(r.size.x, 8)), Ui.CREAM)
		# curtains on some, a plant on others
		if k % 3 == 0:
			c.draw_rect(Rect2(r.position, Vector2(10, r.size.y)), Pal.c("RED_M"))
			c.draw_rect(Rect2(r.end.x - 10, r.position.y, 10, r.size.y), Pal.c("RED_M"))
		elif k % 3 == 1:
			c.draw_rect(Rect2(r.position + Vector2(8, r.size.y - 16), Vector2(12, 16)),
				Pal.c("GRASS_D"))
		c.draw_rect(Rect2(r.position.x + r.size.x * 0.5 - 1, r.position.y, 2, r.size.y),
			Ui.GOLD_M)
	else:
		var over_it := hit(k).has_point(hot) and not over
		c.draw_rect(r, Ui.SL2 if over_it else Ui.SL1)
		# the dead bulb on its wire
		var mid := r.position + Vector2(r.size.x * 0.5, 0)
		c.draw_rect(Rect2(mid + Vector2(-1, 0), Vector2(2, 14)), Ui.SL3)
		JobGame.sprite(c, [".11.", "1111", "1111", ".11."], mid + Vector2(-8, 14), 4.0,
			{"1": Ui.MUTED if not over_it else Ui.CREAM})
		c.draw_rect(Rect2(mid + Vector2(-4, 30), Vector2(8, 4)), Ui.SL3)
	c.draw_rect(Rect2(r.position.x - 4, r.end.y, r.size.x + 8, 6), Pal.c("STN2"))
