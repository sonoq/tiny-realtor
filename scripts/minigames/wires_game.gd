class_name WiresGame
extends JobGame

# "Sin luz": a fuse box with four coloured wires coming in on the left and four sockets on the
# right in another order; join each wire to the socket of its colour. Click a wire's end, then
# its socket (either side first), or drag from one to the other: dragging over the right socket
# joins it. A wrong socket flashes red and keeps the wire in hand. Each colour also has its own
# shape on the caps (square, triangle, diamond, circle) so it reads without colour too. When all
# four are joined the lamp over the box lights.

const N := 4
const BOARD := Rect2(48, 140, 504, 372)
const LEFT_X := 120.0
const RIGHT_X := 480.0
const TOP_Y := 200.0
const GAP := 88.0
# the hit box round each end, well over MIN_HIT
const HIT := Vector2(96, 72)
const CAP := 32.0
const WIRE := 12.0
const SHAPES: Array[String] = ["square", "triangle", "diamond", "circle"]

# links[k] = socket slot the left wire k is joined to, or -1
var links: Array[int] = []
# the socket slot of each colour, and the colour in each slot
var slot_of: Array[int] = []
var color_in: Array[int] = []
# the end in hand: side 0 (left wires) or 1 (right sockets), and its index; -1 for none
var held_side := -1
var held := -1
var _bad := -1
var _bad_t := -10.0
var _done_t := []


func setup() -> void:
	var order: Array[int] = [0, 1, 2, 3]
	# any order but the straight one
	while order[0] == 0 and order[1] == 1 and order[2] == 2 and order[3] == 3:
		for i in range(N - 1, 0, -1):
			var j := rng.randi() % (i + 1)
			var tmp := order[i]
			order[i] = order[j]
			order[j] = tmp
	color_in = order
	slot_of = [0, 0, 0, 0]
	for j in N:
		slot_of[order[j]] = j
	links = [-1, -1, -1, -1]
	_done_t = [-1.0, -1.0, -1.0, -1.0]


static func colors() -> Array[Color]:
	return [Ui.BLOOD, Ui.GOLD, Ui.CYAN, Ui.MINT]


func how() -> String:
	return "Une cada cable con el enchufe de su color"


func hint() -> String:
	if held >= 0:
		return "Ahora toca el enchufe de su color"
	return "Toca un cable y luego su enchufe · %d/%d" % [joined(), N]


func joined() -> int:
	var n := 0
	for j in links:
		if j >= 0:
			n += 1
	return n


func score() -> float:
	return float(joined()) / N


# the middle of left wire k's end, or right socket slot j's
func end_at(side: int, k: int) -> Vector2:
	return Vector2(LEFT_X if side == 0 else RIGHT_X, TOP_Y + k * GAP)


func end_rect(side: int, k: int) -> Rect2:
	return Rect2(end_at(side, k) - HIT * 0.5, HIT)


func _end_under(at: Vector2) -> Vector2i:
	for side in 2:
		for k in N:
			if end_rect(side, k).has_point(at):
				return Vector2i(side, k)
	return Vector2i(-1, -1)


func _free(side: int, k: int) -> bool:
	if side == 0:
		return links[k] < 0
	return not links.has(k)


func press(at: Vector2) -> void:
	if over:
		return
	var e := _end_under(at)
	if e.x < 0:
		return
	if held >= 0 and e.x != held_side:
		_try(e.x, e.y)
	elif _free(e.x, e.y):
		held_side = e.x
		held = e.y


# dragging the wire in hand over the right socket joins it
func drag(at: Vector2) -> void:
	hot = at
	if over or held < 0:
		return
	var e := _end_under(at)
	if e.x >= 0 and e.x != held_side and _free(e.x, e.y):
		var colour := held if held_side == 0 else color_in[held]
		var other := color_in[e.y] if e.x == 1 else e.y
		if colour == other:
			_try(e.x, e.y)
		elif _bad != e.x * N + e.y:
			_try(e.x, e.y)


func _try(side: int, k: int) -> void:
	if not _free(side, k):
		return
	var wire := held if held_side == 0 else k
	var socket := k if side == 1 else held
	if slot_of[wire] == socket:
		links[wire] = socket
		_done_t[wire] = t
		held = -1
		held_side = -1
		_bad = -1
		_pop("¡CLIC!", end_at(1, socket) + Vector2(-60, -24), colors()[wire])
		if joined() >= N:
			_win()
	else:
		_bad = side * N + k
		_bad_t = t


func draw(c: CanvasItem) -> void:
	c.draw_rect(AREA, Ui.SL0)
	# the wall and the box
	JobGame.inked(c, BOARD, Ui.STEEL.darkened(0.35))
	c.draw_rect(Rect2(BOARD.position + Vector2(8, 8), Vector2(BOARD.size.x - 16, 4)), Ui.SL3)
	for p: Vector2 in [BOARD.position + Vector2(14, 14), BOARD.position + Vector2(BOARD.size.x
			- 22, 14), BOARD.end - Vector2(22, 22), Vector2(BOARD.position.x + 14, BOARD.end.y - 22)]:
		c.draw_rect(Rect2(p, Vector2(8, 8)), Ui.RIM_DIM)
	_draw_lamp(c)
	var cols := colors()
	# the joined wires, sagging a little
	for k in N:
		if links[k] >= 0:
			JobGame.thick(c, _sag(end_at(0, k), end_at(1, links[k])), WIRE, cols[k])
	# the wire in hand follows the pointer
	if held >= 0 and not over:
		var from := end_at(held_side, held)
		var to := hot.clamp(BOARD.position + Vector2(12, 12), BOARD.end - Vector2(12, 12))
		if not BOARD.has_point(hot):
			to = from + Vector2(60 if held_side == 0 else -60, 0)
		var col := cols[held] if held_side == 0 else cols[color_in[held]]
		JobGame.thick(c, _sag(from, to), WIRE, col.lightened(0.15))
	for k in N:
		# stubs from the box's sides to the ends
		var a := end_at(0, k)
		JobGame.thick(c, PackedVector2Array([Vector2(BOARD.position.x + 8, a.y), a]), WIRE,
			cols[k])
		var b := end_at(1, k)
		JobGame.thick(c, PackedVector2Array([b, Vector2(BOARD.end.x - 8, b.y)]), WIRE,
			cols[color_in[k]])
	for k in N:
		_cap(c, 0, k, k)
		_cap(c, 1, k, color_in[k])
	_draw_pops(c)


func _cap(c: CanvasItem, side: int, k: int, colour: int) -> void:
	var at := end_at(side, k)
	var r := Rect2(at - Vector2(CAP, CAP) * 0.5, Vector2(CAP, CAP))
	var on_hot := end_rect(side, k).has_point(hot) and not over
	var joined_here := (side == 0 and links[k] >= 0) or (side == 1 and links.has(k))
	var rim := Ui.CREAM if (held_side == side and held == k) or on_hot else Ui.VOID
	if _bad == side * N + k and t - _bad_t < 0.35:
		rim = Ui.BLOOD
		r.position.x += 4.0 if int((t - _bad_t) * 20.0) % 2 == 0 else -4.0
	c.draw_rect(r.grow(6), rim)
	c.draw_rect(r.grow(2), Ui.VOID)
	c.draw_rect(r, colors()[colour] if not joined_here else colors()[colour].darkened(0.25))
	_shape(c, r.grow(-8), SHAPES[colour])


# each colour's own mark, so the wires read without telling the colours apart
static func _shape(c: CanvasItem, r: Rect2, kind: String) -> void:
	var rows: Array[String] = []
	match kind:
		"square":
			rows = ["1111", "1111", "1111", "1111"]
		"triangle":
			rows = [".11.", ".11.", "1111", "1111"]
		"diamond":
			rows = [".11.", "1111", "1111", ".11."]
		"circle":
			rows = [".11.", "1..1", "1..1", ".11."]
	JobGame.sprite(c, rows, r.position, r.size.x / 4.0, {"1": Ui.VOID})


func _draw_lamp(c: CanvasItem) -> void:
	var at := Vector2(AREA.get_center().x, BOARD.position.y - 4)
	var on := won
	var r := Rect2(at - Vector2(28, 20), Vector2(56, 24))
	JobGame.inked(c, r, Ui.GOLD if on else Ui.SL2)
	c.draw_rect(Rect2(r.position, Vector2(r.size.x, 6)), Ui.CREAM if on else Ui.SL3)
	if on:
		for k in 5:
			var ang := PI + (k + 1) * PI / 6.0
			var p := at + Vector2(cos(ang), sin(ang)) * (44.0 + minf(since, 0.3) * 30.0)
			c.draw_rect(Rect2((p / 4.0).round() * 4.0 - Vector2(4, 4), Vector2(8, 8)), Ui.GOLD)
	# one small light per wire joined
	for k in N:
		var p := Rect2(BOARD.position.x + 40 + k * 28, BOARD.position.y + 18, 16, 16)
		JobGame.inked(c, p, colors()[k] if links[k] >= 0 else Ui.SL2, 2.0)


# the points of a wire hanging between two ends
static func _sag(a: Vector2, b: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var drop := minf(28.0, a.distance_to(b) * 0.08)
	for i in 13:
		var f := i / 12.0
		out.append(a.lerp(b, f) + Vector2(0, drop * 4.0 * f * (1.0 - f)))
	return out
