class_name PipesGame
extends JobGame

# "Sin agua en casa": a board of pipe pieces between the water main (the red wheel, left) and
# the tenant's sink (right). Tap a piece to turn it a quarter clockwise; water runs from the main
# through every piece joined to it, so you see how far it gets, and drips out of open ends. Join
# the main to the sink and the water splashes into it ("¡AGUA!"). The board is made from a random
# run of pieces from the main to the sink (straights and elbows) with the rest filled at random
# (straights, elbows, tees), then every piece of the run turned wrong: it always has a way, and
# spinning everything in turn never joins it (checked when the board is made). Score: 1 when the
# water reaches the sink, else PART times the share of the run's pieces the water reaches.

const COLS := 5
const ROWS := 4
const TILE := 80.0
const STEP := 84.0
const GRID := Vector2(92, 148)
const BOARD := Rect2(80, 136, 440, 356)
# the openings of a piece, as bits: north, east, south, west (dir i is bit 1 << i)
const N := 1
const E := 2
const S := 4
const W := 8
const DIRS: Array[Vector2i] = [Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0)]
const STRAIGHT := N | S
const ELBOW := N | E
const TEE := N | E | S
# the run from the main to the sink, in pieces, and the most turns it may take to fix: a decent
# player fixes it in about half the job's time (game_check plays one)
const LEN_MIN := 7
const LEN_MAX := 9
const TURNS_MAX := 13
# how many ways the run's pieces can lie, in bits (a straight lies 2 ways, an elbow 4): at least
# this many, so random tapping hardly ever lands on the one that joins
const WAYS_MIN := 13
# pieces of run the water fills a second, and how long it takes down the sink's pipe
const FLOW := 14.0
const STUB_S := 0.12
# the most a board the water does not cross pays
const PART := 0.9
# pipe widths: the ink, the steel and the channel (half widths)
const H_INK := 16.0
const H_STEEL := 12.0
const H_WATER := 6.0
const MAIN_X := 40.0
const WHEEL_Y := 140.0
const SINK_X := 554.0

# each tile's openings now, and the run's: sol[k] is the piece's way on the run (-1 off it)
var mask: Array[int] = []
var sol: Array[int] = []
# the run's tiles from the main to the sink
var path: Array[int] = []
var src_row := 0
var out_row := 0
var turns := 0
# per tile: when the water got in (on the t + since clock; -1 dry) and from which side
var _wet_at: Array[float] = []
var _from: Array[int] = []
var _turn_t: Array[float] = []
var _arrive := INF
var _popped := false


func setup() -> void:
	src_row = rng.randi() % ROWS
	out_row = rng.randi() % ROWS
	# a way with enough elbows that random taps hardly ever find it
	for _try in 60:
		path = _make_path()
		if _ways(path) >= WAYS_MIN:
			break
	mask.resize(COLS * ROWS)
	sol.resize(COLS * ROWS)
	sol.fill(-1)
	for i in path.size():
		var k := path[i]
		var into := 3 if i == 0 else _dir_to(k, path[i - 1])
		var out := 1 if i == path.size() - 1 else _dir_to(k, path[i + 1])
		sol[k] = (1 << into) | (1 << out)
	for k in COLS * ROWS:
		if sol[k] >= 0:
			continue
		var r := rng.randf()
		var piece := STRAIGHT if r < 0.4 else (ELBOW if r < 0.8 else TEE)
		mask[k] = rot(piece, rng.randi() % 4)
	_scramble()
	_wet_at.resize(COLS * ROWS)
	_wet_at.fill(-1.0)
	_from.resize(COLS * ROWS)
	_from.fill(-1)
	_turn_t.resize(COLS * ROWS)
	_turn_t.fill(-10.0)
	_reflow()


func how() -> String:
	return "Gira las tuberías para llevar el agua hasta el lavabo"


func hint() -> String:
	if won:
		return "¡El agua llega al lavabo!"
	return "Toca una tubería para girarla"


func score() -> float:
	if won:
		return 1.0
	return PART * wet_path() / path.size()


func outro() -> float:
	return maxf(OUTRO_S, _arrive - t + 0.8) if won else OUTRO_S


# the clock the water runs on: it keeps flowing after the game ends
func clock() -> float:
	return t + since


func step(dt: float) -> void:
	super.step(dt)
	if won and not _popped and clock() >= _arrive:
		_popped = true
		_pop("¡AGUA!", Vector2(SINK_X - 30, _row_y(out_row) - 34), Ui.CYAN)


# a piece's openings turned n quarters clockwise
static func rot(m: int, n: int) -> int:
	for _i in posmod(n, 4):
		m = ((m << 1) | (m >> 3)) & 15
	return m


# taps until a tile of the run is right (0 when it is; -1 off the run)
func turns_needed(k: int) -> int:
	if sol[k] < 0:
		return -1
	for n in 4:
		if rot(mask[k], n) == sol[k]:
			return n
	return -1


func tile_rect(k: int) -> Rect2:
	return Rect2(GRID + Vector2(k % COLS, k / COLS) * STEP, Vector2(TILE, TILE))


func tile_under(at: Vector2) -> int:
	for k in COLS * ROWS:
		if tile_rect(k).has_point(at):
			return k
	return -1


func wet(k: int) -> bool:
	return _from[k] >= 0


# the run's tiles the water reaches
func wet_path() -> int:
	var n := 0
	for k in path:
		if wet(k):
			n += 1
	return n


func connected() -> bool:
	return joins(mask)


func press(at: Vector2) -> void:
	if over:
		return
	var k := tile_under(at)
	if k < 0:
		return
	mask[k] = rot(mask[k], 1)
	turns += 1
	_turn_t[k] = t
	# a turned piece fills again from its way in
	_wet_at[k] = -1.0
	_reflow()
	if connected():
		var last := out_row * COLS + COLS - 1
		_arrive = _wet_at[last] + 1.0 / FLOW + STUB_S
		_win()


# where the water gets from the main: tile -> the side it came in by, in the order it gets there
func flow_of(m: Array[int]) -> Dictionary:
	var out := {}
	var first := src_row * COLS
	if m[first] & W == 0:
		return out
	out[first] = 3
	var queue: Array[int] = [first]
	var qi := 0
	while qi < queue.size():
		var k := queue[qi]
		qi += 1
		for i in 4:
			if m[k] & (1 << i) == 0:
				continue
			var nk := _next(k, i)
			if nk < 0 or out.has(nk) or m[nk] & (1 << ((i + 2) % 4)) == 0:
				continue
			out[nk] = (i + 2) % 4
			queue.append(nk)
	return out


func joins(m: Array[int]) -> bool:
	var last := out_row * COLS + COLS - 1
	return m[last] & E != 0 and flow_of(m).has(last)


# the tile next to k on side i, or -1 off the board
func _next(k: int, i: int) -> int:
	var x := k % COLS + DIRS[i].x
	var y := k / COLS + DIRS[i].y
	if x < 0 or y < 0 or x >= COLS or y >= ROWS:
		return -1
	return y * COLS + x


# the bits of a run: one per straight, two per elbow
func _ways(run: Array[int]) -> int:
	var bits := 0
	for i in run.size():
		var into := 3 if i == 0 else _dir_to(run[i], run[i - 1])
		var out := 1 if i == run.size() - 1 else _dir_to(run[i], run[i + 1])
		bits += 1 if (into + 2) % 4 == out else 2
	return bits


func _dir_to(k: int, other: int) -> int:
	for i in 4:
		if _next(k, i) == other:
			return i
	return -1


# a random run from the main's tile (left column) to the sink's (right column), LEN_MIN..LEN_MAX
# long; its length must match the rows' distance in parity
func _make_path() -> Array[int]:
	var start := src_row * COLS
	var goal := out_row * COLS + COLS - 1
	var lens: Array[int] = []
	for n in range(LEN_MIN, LEN_MAX + 1):
		if n >= COLS + absi(src_row - out_row) and (n - COLS - absi(src_row - out_row)) % 2 == 0:
			lens.append(n)
	var want := lens[rng.randi() % lens.size()]
	var run: Array[int] = [start]
	if _walk(run, goal, want):
		return run
	# never reached on a 5 x 4 board, kept so a board is always made: along the top row's way
	run = [start]
	for x in range(1, COLS):
		run.append(src_row * COLS + x)
	var y := src_row
	while y != out_row:
		y += signi(out_row - y)
		run.append(y * COLS + COLS - 1)
	return run


func _walk(run: Array[int], goal: int, want: int) -> bool:
	var k := run[-1]
	if run.size() == want:
		return k == goal
	if k == goal:
		return false
	var left := want - run.size()
	var order: Array[int] = [0, 1, 2, 3]
	for i in range(3, 0, -1):
		var j := rng.randi() % (i + 1)
		var tmp := order[i]
		order[i] = order[j]
		order[j] = tmp
	for i in order:
		var nk := _next(k, i)
		if nk < 0 or run.has(nk):
			continue
		var d := absi(nk % COLS - goal % COLS) + absi(nk / COLS - goal / COLS)
		if d > left - 1:
			continue
		run.append(nk)
		if _walk(run, goal, want):
			return true
		run.pop_back()
	return false


# every piece of the run turned wrong (the first one shut to the main, so nothing runs before you
# play), within TURNS_MAX, and no sweep of taps over every tile in turn joins it
func _scramble() -> void:
	for _try in 200:
		var total := 0
		for i in path.size():
			var k := path[i]
			var opts: Array[int] = []
			for n in range(1, 4):
				var m := rot(sol[k], -n)
				if m != sol[k] and not (i == 0 and m & W != 0) and not opts.has(m):
					opts.append(m)
			mask[k] = opts[rng.randi() % opts.size()]
			total += turns_needed(k)
		if total <= TURNS_MAX and _mash_safe():
			return


# a player who taps every tile in turn, row by row, column by column or backwards, for four
# rounds never joins the main to the sink
func _mash_safe() -> bool:
	var orders: Array = []
	var rows: Array[int] = []
	var cols: Array[int] = []
	for k in COLS * ROWS:
		rows.append(k)
		cols.append((k % ROWS) * COLS + k / ROWS)
	var back := rows.duplicate()
	back.reverse()
	orders = [rows, cols, back]
	for order: Array[int] in orders:
		var m := mask.duplicate()
		for _round in 4:
			for k in order:
				m[k] = rot(m[k], 1)
				if joins(m):
					return false
	return true


# the water after a turn: tiles still reached the same way keep their water, new ones fill one
# after another from the one before
func _reflow() -> void:
	var fl := flow_of(mask)
	var now := clock()
	var at: Array[float] = []
	at.resize(COLS * ROWS)
	at.fill(-1.0)
	for k: int in fl:
		var into: int = fl[k]
		if _wet_at[k] >= 0.0 and _from[k] == into:
			at[k] = _wet_at[k]
			continue
		var before := now - 1.0 / FLOW
		var p := _next(k, into)
		if p >= 0 and at[p] >= 0.0:
			before = at[p]
		at[k] = maxf(now, before + 1.0 / FLOW)
	for k in COLS * ROWS:
		_wet_at[k] = at[k]
		_from[k] = fl.get(k, -1)


func _row_y(row: int) -> float:
	return GRID.y + row * STEP + TILE * 0.5


func draw(c: CanvasItem) -> void:
	c.draw_rect(AREA, Ui.SL0)
	# the wall's big tiles, the board let into it
	for j in 9:
		for i in 12:
			var r := Rect2(AREA.position + Vector2(i * 48, j * 48), Vector2(46, 46))
			r = r.intersection(AREA)
			if r.has_area():
				c.draw_rect(r, Ui.SL1 if (i + j) % 2 == 0 else Ui.SL0)
	JobGame.inked(c, BOARD, Ui.STEEL.darkened(0.35))
	for p: Vector2 in [BOARD.position + Vector2(2, 2), Vector2(BOARD.end.x - 6, BOARD.position.y
			+ 2), BOARD.end - Vector2(6, 6), Vector2(BOARD.position.x + 2, BOARD.end.y - 6)]:
		c.draw_rect(Rect2(p, Vector2(4, 4)), Ui.RIM_DIM)
	_draw_main(c)
	_draw_sink(c)
	for k in COLS * ROWS:
		_draw_tile(c, k)
	_draw_leaks(c)
	_draw_pops(c)


# an axis-aligned run of pipe from a to b, h either side, carried ext_a / ext_b past its ends
static func _run(a: Vector2, b: Vector2, h: float, ext_a: float, ext_b: float) -> Rect2:
	var d := (b - a).normalized() if a != b else Vector2.RIGHT
	var r := Rect2(a - d * ext_a, Vector2.ZERO).expand(b + d * ext_b)
	if absf(d.x) > 0.5:
		return r.grow_individual(0, h, 0, h)
	return r.grow_individual(h, 0, h, 0)


# pipes as runs [a, b, ext_a, ext_b], drawn layer by layer so joints merge: ink, steel with
# its light and dark walls, then collars where a piece meets the next
func _pipes(c: CanvasItem, runs: Array, collars: Array) -> void:
	for r: Array in runs:
		c.draw_rect(_run(r[0], r[1], H_INK, r[2], r[3]), Ui.VOID)
	for r: Array in runs:
		c.draw_rect(_run(r[0], r[1], H_STEEL, r[2] * 0.75, r[3] * 0.75), Pal.c("CON2"))
	# the walls run up to a joint, then the joint's own open sides get theirs
	var joints := {}
	for r: Array in runs:
		var a: Vector2 = r[0]
		var b: Vector2 = r[1]
		var d := (b - a).normalized()
		var from := a + d * H_STEEL if float(r[2]) > 0.0 else a
		var to := b - d * H_STEEL if float(r[3]) > 0.0 else b
		var body := _run(from, to, H_STEEL, 0.0, 0.0)
		if absf(a.y - b.y) < 0.5:
			c.draw_rect(Rect2(body.position, Vector2(body.size.x, 4)), Pal.c("CON0"))
			c.draw_rect(Rect2(body.position.x, body.end.y - 4, body.size.x, 4), Pal.c("CON3"))
		else:
			c.draw_rect(Rect2(body.position, Vector2(4, body.size.y)), Pal.c("CON1"))
			c.draw_rect(Rect2(body.end.x - 4, body.position.y, 4, body.size.y), Pal.c("CON3"))
		for end in 2:
			if float(r[2 + end]) > 0.0:
				var at: Vector2 = r[end]
				var away := d if end == 0 else -d
				joints[at] = int(joints.get(at, 0)) | (1 << DIRS.find(Vector2i(away.round())))
	for at: Vector2 in joints:
		var arms: int = joints[at]
		var sq := Rect2(at - Vector2(H_STEEL, H_STEEL), Vector2(H_STEEL, H_STEEL) * 2.0)
		if arms & W == 0:
			c.draw_rect(Rect2(sq.position, Vector2(4, sq.size.y)), Pal.c("CON1"))
		if arms & N == 0:
			c.draw_rect(Rect2(sq.position, Vector2(sq.size.x, 4)), Pal.c("CON0"))
		if arms & S == 0:
			c.draw_rect(Rect2(sq.position.x, sq.end.y - 4, sq.size.x, 4), Pal.c("CON3"))
		if arms & E == 0:
			c.draw_rect(Rect2(sq.end.x - 4, sq.position.y, 4, sq.size.y), Pal.c("CON3"))
	for cl: Array in collars:
		var at: Vector2 = cl[0]
		var i: int = cl[1]
		var along := Vector2(DIRS[i])
		var r := Rect2(at - along * 4.0, Vector2.ZERO).expand(at - along * 12.0)
		r = r.grow_individual(0, 20, 0, 20) if i % 2 == 1 else r.grow_individual(20, 0, 20, 0)
		JobGame.inked(c, r, Pal.c("CON1"), 4.0)
		var lip := r
		if i % 2 == 1:
			lip.position.y = r.end.y - 4
			lip.size.y = 4
		else:
			lip.position.x = r.end.x - 4
			lip.size.x = 4
		c.draw_rect(lip, Pal.c("CON3"))


# water in a pipe's channel from a towards b, `frac` of the way, flowing that way
func _water(c: CanvasItem, a: Vector2, b: Vector2, frac: float, ext_a: float,
		ext_b: float) -> void:
	if frac <= 0.0:
		return
	var to := (a.lerp(b, frac) / 4.0).round() * 4.0
	var r := _run(a, to, H_WATER, ext_a, ext_b if frac >= 1.0 else 0.0)
	c.draw_rect(r, Pal.c("CYAN_M"))
	var flat := absf(a.y - b.y) < 0.5
	if flat:
		c.draw_rect(Rect2(r.position, Vector2(r.size.x, 4)), Ui.CYAN)
	else:
		c.draw_rect(Rect2(r.position, Vector2(4, r.size.y)), Ui.CYAN)
	# glints carried along with the flow
	var d := (b - a).normalized()
	var len := a.distance_to(to)
	var phase := fmod(floorf(clock() * 12.0) * 4.0, 16.0)
	var s := phase
	while s < len - 4.0:
		var p := a + d * s
		var q := Rect2(p - Vector2(2, 2), Vector2(4, 4))
		q.position += Vector2(0, 2) if flat else Vector2(2, 0)
		c.draw_rect(q, Pal.c("GLS0"))
		s += 16.0


func _fill(k: int) -> float:
	if not wet(k):
		return 0.0
	return clampf((clock() - _wet_at[k]) * FLOW, 0.0, 1.0)


func _draw_tile(c: CanvasItem, k: int) -> void:
	var r := tile_rect(k)
	var on_hot := r.has_point(hot) and not over
	var turned := t - _turn_t[k] < 0.1
	c.draw_rect(r, Ui.CREAM if on_hot else Ui.VOID)
	c.draw_rect(r.grow(-4), Ui.SL2 if turned else Ui.SL1)
	c.draw_rect(Rect2(r.position + Vector2(4, 4), Vector2(r.size.x - 8, 4)), Ui.SL2 if not turned
		else Ui.SL3)
	var mid := r.get_center()
	var runs: Array = []
	var collars: Array = []
	for i in 4:
		if mask[k] & (1 << i) != 0:
			var edge := mid + Vector2(DIRS[i]) * TILE * 0.5
			runs.append([mid, edge, H_INK, 0.0])
			collars.append([edge, i])
	_pipes(c, runs, collars)
	var f := _fill(k)
	if f <= 0.0:
		return
	var into := _from[k]
	var e_in := mid + Vector2(DIRS[into]) * TILE * 0.5
	_water(c, e_in, mid, minf(1.0, f * 2.0), 0.0, H_WATER)
	var g := clampf(f * 2.0 - 1.0, 0.0, 1.0)
	if g <= 0.0:
		return
	for i in 4:
		if i != into and mask[k] & (1 << i) != 0:
			_water(c, mid, mid + Vector2(DIRS[i]) * TILE * 0.5, g, H_WATER, 0.0)


# water running out of open ends: drops falling from the end of each full pipe that leads nowhere
func _draw_leaks(c: CanvasItem) -> void:
	var last := out_row * COLS + COLS - 1
	for k in COLS * ROWS:
		if _fill(k) < 1.0:
			continue
		var mid := tile_rect(k).get_center()
		for i in 4:
			if mask[k] & (1 << i) == 0 or i == _from[k] or (k == last and i == 1):
				continue
			var nk := _next(k, i)
			if nk >= 0 and mask[nk] & (1 << ((i + 2) % 4)) != 0:
				continue
			var edge := mid + Vector2(DIRS[i]) * (TILE * 0.5 + 2.0)
			for j in 2:
				var fall := fmod((clock() - _wet_at[k]) * 60.0 + j * 14.0, 28.0)
				var p := edge + Vector2(-4 + j * 4 if i % 2 == 0 else -4, floorf(fall / 4.0) * 4.0)
				if i == 2:
					p.y += 4.0
				c.draw_rect(Rect2(p - Vector2(2, 2), Vector2(8, 8)), Ui.VOID)
				c.draw_rect(Rect2(p, Vector2(4, 4)), Ui.CYAN)


# the water main down the wall, its red wheel, and into the board on the main's row
func _draw_main(c: CanvasItem) -> void:
	var y := _row_y(src_row)
	var top := Vector2(MAIN_X, AREA.position.y)
	var bend := Vector2(MAIN_X, y)
	var into := Vector2(GRID.x, y)
	_pipes(c, [[top, bend, 0.0, H_INK], [bend, into, H_INK, 0.0]], [[into, 1]])
	_water(c, top, bend, 1.0, 0.0, H_WATER)
	_water(c, bend, into, 1.0, H_WATER, 0.0)
	# the wheel on its stem
	var w := Vector2(MAIN_X + 22, minf(WHEEL_Y, y - 40))
	c.draw_rect(Rect2(w.x - 26, w.y - 2, 22, 8), Ui.VOID)
	c.draw_rect(Rect2(w.x - 24, w.y, 18, 4), Pal.c("CON2"))
	var rows: Array[String] = ["..111..", ".1.1.1.", "1..1..1", "1111111", "1..1..1", ".1.1.1.",
		"..111.."]
	var at := w - Vector2(14, 14)
	for o: Vector2 in [Vector2(-4, 0), Vector2(4, 0), Vector2(0, -4), Vector2(0, 4)]:
		JobGame.sprite(c, rows, at + o, 4.0, {"1": Ui.VOID})
	JobGame.sprite(c, rows, at, 4.0, {"1": Ui.RED})
	c.draw_rect(Rect2(w - Vector2(2, 2), Vector2(4, 4)), Ui.BLOOD)


# the sink: a pipe out of the board on the sink's row, down into the basin; it fills once the
# water gets there
func _draw_sink(c: CanvasItem) -> void:
	var y := _row_y(out_row)
	var out := Vector2(GRID.x + COLS * STEP - (STEP - TILE), y)
	var bend := Vector2(SINK_X, y)
	var spout := Vector2(SINK_X, y + 20)
	_pipes(c, [[out, bend, 0.0, H_INK], [bend, spout, H_INK, 0.0]], [[out, 3]])
	var since_in := clock() - (_arrive - STUB_S) if won else -1.0
	if since_in > 0.0:
		var f := clampf(since_in / STUB_S, 0.0, 1.0)
		_water(c, out, bend, minf(1.0, f * 2.0), 0.0, H_WATER)
		if f > 0.5:
			_water(c, bend, spout, f * 2.0 - 1.0, H_WATER, 0.0)
	# the nozzle, the basin on its pedestal under it
	var nozzle := Rect2(SINK_X - 6, spout.y, 12, 8)
	JobGame.inked(c, nozzle, Pal.c("CON1"), 4.0)
	var basin := Rect2(SINK_X - 32, y + 44, 64, 24)
	var foot := Rect2(SINK_X - 10, basin.end.y, 20, 16)
	JobGame.inked(c, foot, Pal.c("CRM1"))
	c.draw_rect(Rect2(foot.end.x - 4, foot.position.y, 4, foot.size.y), Pal.c("CRM2"))
	JobGame.inked(c, basin, Pal.c("CRM0"))
	c.draw_rect(Rect2(basin.position.x, basin.end.y - 4, basin.size.x, 4), Pal.c("CRM2"))
	var bowl := Rect2(basin.position + Vector2(8, 0), Vector2(basin.size.x - 16, 12))
	c.draw_rect(bowl, Ui.SL1)
	c.draw_rect(Rect2(bowl.position.x, bowl.end.y, bowl.size.x, 4), Pal.c("CRM1"))
	var poured := clock() - _arrive if won else -1.0
	if poured < 0.0:
		return
	# the stream from the nozzle, the basin filling, a splash
	var top := nozzle.end.y + 4.0
	c.draw_rect(Rect2(SINK_X - 4, top, 8, basin.position.y - top + 4), Pal.c("CYAN_M"))
	c.draw_rect(Rect2(SINK_X - 4, top, 4, basin.position.y - top + 4), Ui.CYAN)
	var level := floorf(clampf(poured / 0.4, 0.0, 1.0) * 3.0) * 4.0
	if level > 0.0:
		c.draw_rect(Rect2(bowl.position.x, bowl.end.y - level, bowl.size.x, level), Pal.c("CYAN_M"))
		c.draw_rect(Rect2(bowl.position.x, bowl.end.y - level, bowl.size.x, 4), Ui.CYAN)
	if poured < 0.5:
		for j in 5:
			var vx := (j - 2) * 44.0
			var vy := 170.0 + (j % 2) * 90.0
			var p := Vector2(SINK_X + vx * poured, basin.position.y - 4 - vy * poured
				+ 380.0 * poured * poured)
			c.draw_rect(Rect2(p.round() - Vector2(2, 2), Vector2(8, 8)), Ui.VOID)
			c.draw_rect(Rect2(p.round(), Vector2(4, 4)), Ui.CYAN)
