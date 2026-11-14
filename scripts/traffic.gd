class_name Traffic
extends Node2D

# Moving traffic over an office's drawing: cars, vans, taxis and buses driving the area's real
# streets (RoadNet), drawn live as one batch of sprites (CarSprites) over BlockView's texture.
# It lives as a child of the sprite that shows the drawing, so it draws in drawing pixels and is
# scaled with it; a car sits on whole art pixels and moves in whole-pixel steps.
#
# Simulation, at TICK (10 Hz; positions are interpolated between ticks for drawing): each car
# follows its lane, keeps a gap to whoever is ahead (on its lane or the next connector), brakes
# into turns, and at a junction waits at the kerb line until its connector is clear of every
# crossing car's (first come, first served) and there is room on the street it turns into.
# Brake lights show while it slows. Cars live around what the window shows: one far away and out
# of sight is taken off and a new one comes in out of sight, near the view. Every choice comes
# from one RandomNumberGenerator seeded by the office id, so a seed always plays the same.
#
# Occlusion: BlockView's depth pass holds, per drawing pixel, the depth of what is drawn there;
# the car shader hides a car's pixel where something nearer than the car stands (a building in
# front, a tree on the near pavement, a price tag), and shades it in cast shadows and fades it
# outside the office's radius, all through the palette's tables like the drawing.

const TICK := 1.0 / 10.0
const CAP := 80
const ACCEL := 1.8
const BRAKE := 3.0
# bumper-to-bumper gap a car keeps when it stops (m)
const GAP := 1.6
# cars look at the junction ahead from this far (m)
const LOOK := 10.0
# depth a building must stand in front of a car's middle to hide it (m)
const HIDE_TOL := 1.5
const WARMUP := 6.0
# a car further than this from the view's middle (beyond its corners) may be swapped out (m)
const REGION_PAD := 20.0
const SPRITE_PAD := 24.0
const CELL := 12.0
# a car in front within this much to either side is in the way, whatever its path (m)
const SENSE_SIDE := 2.1
# countries that drive on the left (CityDb's names)
const LEFT_HAND: Array[String] = ["Reino Unido", "Japón", "Singapur", "Australia", "India",
	"Irlanda", "Sudáfrica", "Nueva Zelanda", "Tailandia", "Indonesia", "Hong Kong"]

var net: RoadNet
# how many cars there are and want to be
var count := 0
var target := 0
# totals since setup, for checks and logs
var spawned := 0
var recycled := 0
var ticks := 0
var tick_usec := 0
# tools stop the clock and step it themselves (run())
var frozen := false

# --- one entry per car (the first `count`) ---
var path := PackedInt32Array()
var s := PackedFloat32Array()
var v := PackedFloat32Array()
var nxt := PackedInt32Array()
# the junction after the next one, taken in the same go when the street between is too short
# to wait on: -1 not planned yet, -2 none needed
var nxt2 := PackedInt32Array()
var granted := PackedByteArray()
var braking := PackedByteArray()
var wait := PackedFloat32Array()
var stuck := PackedFloat32Array()
var kind := PackedInt32Array()
var size := PackedFloat32Array()
var pace := PackedFloat32Array()
var seg := PackedInt32Array()
var pos := PackedVector2Array()
var prev := PackedVector2Array()
var head := PackedInt32Array()
var fwd := PackedVector2Array()

var _rng := RandomNumberGenerator.new()
var _origin := Vector2.ZERO
var _view := Rect2()
var _centre := Vector2.ZERO
var _reach := 300.0
var _acc := 0.0
var _clock := 0
# per path, the first car on it, and per car the next on the same path (-1 ends)
var _first := PackedInt32Array()
var _link := PackedInt32Array()
# the same by grid cell (CELL m), for cars that meet off their paths (streets that merge)
var _cells := 0
var _cell_first := PackedInt32Array()
var _cell_link := PackedInt32Array()
var _cell_of := PackedInt32Array()
# this tick's ways across junctions (node, connector, car) and the cars waiting at one
var _res_node := PackedInt32Array()
var _res_conn := PackedInt32Array()
var _res_car := PackedInt32Array()
var _res_count := 0
var _waiting := PackedInt32Array()
var _wait_count := 0
# drawing
var _ready_to_draw := false
var _px := PackedVector2Array()
var _drawn := PackedVector2Array()
var _order := PackedInt32Array()
var _quad_pts := PackedVector2Array()
var _quad_uv := PackedVector2Array()
var _quad_col := PackedColorArray()
var _quad_idx := PackedInt32Array()
var _spawn_w := PackedFloat32Array()
var _spawn_total := 0.0
var _adv := PackedFloat32Array()
var _exit := PackedByteArray()


# block: the office area (v3); origin: where ground (0, 0) lands in the drawing (BlockView.focus)
func setup(block: Dictionary, origin: Vector2, seed_key: String) -> void:
	_origin = origin
	_rng.seed = seed_key.hash()
	var office: Dictionary = block.get("office", {})
	var country: String = CityDb.get_city(office.get("city", "")).get("country", "")
	net = RoadNet.new()
	net.build(block.get("roads", []), country in LEFT_HAND, float(block.get("radius_m", 500.0)))
	path.resize(CAP)
	nxt.resize(CAP)
	nxt2.resize(CAP)
	kind.resize(CAP)
	seg.resize(CAP)
	head.resize(CAP)
	s.resize(CAP)
	v.resize(CAP)
	wait.resize(CAP)
	stuck.resize(CAP)
	size.resize(CAP)
	pace.resize(CAP)
	granted.resize(CAP)
	braking.resize(CAP)
	pos.resize(CAP)
	prev.resize(CAP)
	fwd.resize(CAP)
	_px.resize(CAP)
	_drawn.resize(CAP)
	_adv.resize(CAP)
	_exit.resize(CAP)
	_link.resize(CAP)
	_order.resize(CAP)
	_quad_pts.resize(CAP * 4)
	_quad_uv.resize(CAP * 4)
	_quad_col.resize(CAP * 4)
	_quad_idx.resize(CAP * 6)
	for i in CAP:
		for k in 6:
			_quad_idx[i * 6 + k] = i * 4 + [0, 1, 2, 0, 2, 3][k]
	_first.resize(net.path_count())
	_first.fill(-1)
	_cells = ceili((float(block.get("radius_m", 500.0)) + 40.0) * 2.0 / CELL)
	_cell_first.resize(_cells * _cells)
	_cell_first.fill(-1)
	_cell_link.resize(CAP)
	_cell_of.resize(CAP)
	_res_node.resize(CAP * 3)
	_res_conn.resize(CAP * 3)
	_res_car.resize(CAP * 3)
	_waiting.resize(CAP)
	# lanes long enough to start on, weighted by how busy their street is
	_spawn_w.resize(net.lane_count)
	_spawn_total = 0.0
	for l in net.lane_count:
		_spawn_w[l] = net.length[l] * net.density[l] if net.length[l] >= LOOK + 6.0 else 0.0
		_spawn_total += _spawn_w[l]
	if _view.size == Vector2.ZERO:
		set_view(Rect2(origin - Vector2(150, 150), Vector2(300, 300)))


# the part of the drawing the window shows (drawing pixels); cars gather around it
func set_view(rect: Rect2) -> void:
	_view = rect
	if net == null:
		return
	var c := _ground(rect.get_center())
	var far := 0.0
	for corner: Vector2 in [rect.position, rect.end, Vector2(rect.position.x, rect.end.y),
			Vector2(rect.end.x, rect.position.y)]:
		far = maxf(far, c.distance_to(_ground(corner)))
	if c.distance_to(_centre) < 15.0 and absf(far * 0.85 - _reach + REGION_PAD) < 15.0:
		return
	_centre = c
	_reach = far * 0.85 + REGION_PAD
	var want := 0.0
	for l in net.lane_count:
		if net.mid[l].distance_to(_centre) < _reach:
			want += net.length[l] * net.density[l] / 100.0
	target = clampi(roundi(want), 6 if want > 3.0 else 0, CAP)


# fills the streets near the view and lets them settle for a few seconds, so the first frame
# already shows cars queued at junctions rather than all freshly placed
func populate() -> void:
	for k in target * 4:
		if count >= target:
			break
		_spawn(true)
	for k in roundi(WARMUP / TICK):
		step()


# hands the drawing's depth and shadow images to the car shader and draws the sprites; cars
# show once their atlas is ready
func attach(view: BlockView, active_radius: float) -> void:
	material = _material(view, active_radius)
	populate()
	await CarSprites.build(self)
	(material as ShaderMaterial).set_shader_parameter("atlas", CarSprites.atlas)
	_ready_to_draw = true
	_acc = 0.0
	queue_redraw()


# n ticks at once, drawn where they end; for tools that shoot frames at set times
func run(n: int) -> void:
	for k in n:
		step()
	for i in count:
		prev[i] = pos[i]
		_px[i] = _screen(pos[i]).round()
	queue_redraw()


func is_drawing() -> bool:
	return _ready_to_draw


func _process(delta: float) -> void:
	if not _ready_to_draw or frozen:
		return
	_acc += delta
	var n := 0
	while _acc >= TICK and n < 4:
		step()
		_acc -= TICK
		n += 1
	if n == 4:
		_acc = 0.0
	var t := _acc / TICK
	var moved := n > 0
	for i in count:
		var q := _screen(prev[i].lerp(pos[i], t)).round()
		if q != _drawn[i]:
			moved = true
		_px[i] = q
	if moved:
		queue_redraw()


# one tick of the simulation
func step() -> void:
	var t0 := Time.get_ticks_usec()
	ticks += 1
	_clock += 1
	var half := float(_cells) * CELL * 0.5
	for i in count:
		_link[i] = _first[path[i]]
		_first[path[i]] = i
		var c := clampi(floori((pos[i].x + half) / CELL), 0, _cells - 1) \
			+ clampi(floori((pos[i].y + half) / CELL), 0, _cells - 1) * _cells
		_cell_of[i] = c
		_cell_link[i] = _cell_first[c]
		_cell_first[c] = i
	# who holds a way across which junction, and who waits at one
	_res_count = 0
	_wait_count = 0
	for j in count:
		var pj := path[j]
		if net.is_conn[pj] == 1:
			_reserve(net.to_node[pj], pj, j)
		elif granted[j] == 1 and nxt[j] >= 0:
			_reserve(net.to_node[nxt[j]], nxt[j], j)
		elif nxt[j] >= 0 and net.length[pj] - s[j] < LOOK:
			_waiting[_wait_count] = j
			_wait_count += 1
		if granted[j] == 1 and nxt2[j] >= 0:
			_reserve(net.to_node[nxt2[j]], nxt2[j], j)
	# speeds first, from where everyone is now; then everyone moves
	for i in count:
		_adv[i] = _drive(i)
	for i in count:
		_first[path[i]] = -1
		_cell_first[_cell_of[i]] = -1
	for i in count:
		prev[i] = pos[i]
		_advance(i, _adv[i])
	# cars that drove off the disc's edge
	for i in range(count - 1, -1, -1):
		if _exit[i] == 1:
			_exit[i] = 0
			_remove(i)
			recycled += 1
	if _clock % 10 == 0:
		_upkeep()
	tick_usec = Time.get_ticks_usec() - t0


# the speed car i settles on this tick and how far it may go
func _drive(i: int) -> float:
	var p := path[i]
	var half := size[i] * 0.5
	var top := net.speed[p] * (pace[i] if net.is_conn[p] == 0 else 1.0)
	var want := top
	var room := INF
	if net.is_conn[p] == 0 and nxt[i] < 0:
		# nowhere to go: off the world at the disc's edge, else a stop at the end
		if net.node_rim[net.to_node[p]] == 0:
			room = maxf(0.0, net.length[p] - s[i] - half - 0.3)
			want = minf(want, sqrt(2.0 * BRAKE * room))
	elif net.is_conn[p] == 0:
		var to_end := net.length[p] - s[i]
		# into the coming turn no faster than it allows
		var vt := net.speed[nxt[i]]
		want = minf(want, sqrt(vt * vt + 2.0 * BRAKE * maxf(0.0, to_end - 0.5)))
		if granted[i] == 0 and to_end < LOOK + v[i] * v[i] / (2.0 * BRAKE):
			wait[i] += TICK
			# asked a few times a second, each car on its own beat
			if (_clock + i) % 3 == 0 and _may_enter(i):
				granted[i] = 1
				_reserve(net.to_node[nxt[i]], nxt[i], i)
				if nxt2[i] >= 0:
					_reserve(net.to_node[nxt2[i]], nxt2[i], i)
		if granted[i] == 0:
			var line := maxf(0.0, to_end - half - 0.3)
			want = minf(want, sqrt(2.0 * BRAKE * line))
			room = line
	var gap := _gap(i)
	# a car held up anyway (queued, at its kerb line) needs no look around
	if minf(room, gap - GAP * 0.5) > 0.01:
		gap = minf(gap, _sense(i))
	if gap < INF:
		want = minf(want, sqrt(2.0 * BRAKE * maxf(0.0, gap - GAP)))
		room = minf(room, maxf(0.0, gap - GAP * 0.5))
	var was := v[i]
	v[i] = minf(was + ACCEL * TICK, want)
	var by := minf(v[i] * TICK, room)
	if by > 0.001 and (_would_hit(i, by) or _into_way(i, by)):
		v[i] = 0.0
		by = 0.0
	braking[i] = 1 if v[i] < was - 0.02 or (v[i] < 0.3 and want < 0.3) else 0
	return by


# bumper-to-bumper distance to the car ahead, on this path or the next two, INF for none
func _gap(i: int) -> float:
	var p := path[i]
	var best := INF
	var j := _first[p]
	while j >= 0:
		if j != i and s[j] > s[i] and s[j] - s[i] < best:
			best = s[j] - s[i] - (size[i] + size[j]) * 0.5
		j = _link[j]
	if best < INF:
		return best
	var ahead := net.length[p] - s[i]
	var q := nxt[i]
	for depth in 2:
		if q < 0 or ahead > 40.0:
			break
		var lead := INF
		j = _first[q]
		while j >= 0:
			if j != i and s[j] < lead:
				lead = s[j]
				best = ahead + s[j] - (size[i] + size[j]) * 0.5
			j = _link[j]
		if lead < INF:
			return best
		ahead += net.length[q]
		q = net.dst[q] if net.is_conn[q] == 1 else -1
	return INF


# bumper-to-bumper distance to the nearest car in front going roughly the same way, on whatever
# path: where two streets merge their lanes meet before any junction does. "In front" is along
# both cars' mean heading, so of two cars only one ever waits for the other
func _sense(i: int) -> float:
	var best := INF
	var d := fwd[i]
	var cx := _cell_of[i] % _cells
	var cy := _cell_of[i] / _cells
	for oy in range(maxi(cy - 1, 0), mini(cy + 2, _cells)):
		for ox in range(maxi(cx - 1, 0), mini(cx + 2, _cells)):
			var j := _cell_first[oy * _cells + ox]
			while j >= 0:
				var rel := pos[j] - pos[i]
				if j != i and rel.length_squared() < 400.0 and d.dot(fwd[j]) > 0.5 \
						and not _waits_for(j, i):
					var m := (d + fwd[j]).normalized()
					var a := rel.dot(m)
					if a > 0.0 and absf(rel.cross(m)) < SENSE_SIDE:
						best = minf(best, a - (size[i] + size[j]) * 0.5)
				j = _cell_link[j]
	return best


# whether car j is waiting to cross a junction car i has its way across: then i does not wait
# for it (j is waiting for i)
func _waits_for(j: int, i: int) -> bool:
	var pj := path[j]
	if net.is_conn[pj] == 1 or granted[j] == 1 or nxt[j] < 0:
		return false
	var node := net.to_node[pj]
	var pi := path[i]
	if net.is_conn[pi] == 1:
		if net.to_node[pi] == node:
			return true
	elif granted[i] == 1 and nxt[i] >= 0 and net.to_node[nxt[i]] == node:
		return true
	return granted[i] == 1 and nxt2[i] >= 0 and net.to_node[nxt2[i]] == node


# the last safeguard, for odd street shapes the rules above miss (a lane that starts beside
# another, a slip road): whether moving car i on by `by` would put it into a car it must give
# way to: one whose way across a junction it is waiting for, else the one in front along their
# mean heading unless that one is waiting for i
func _would_hit(i: int, by: float) -> bool:
	var to := pos[i] + fwd[i] * by
	var cx := _cell_of[i] % _cells
	var cy := _cell_of[i] / _cells
	for oy in range(maxi(cy - 1, 0), mini(cy + 2, _cells)):
		for ox in range(maxi(cx - 1, 0), mini(cx + 2, _cells)):
			var j := _cell_first[oy * _cells + ox]
			while j >= 0:
				if j != i and to.distance_to(pos[j]) < (size[i] + size[j]) * 0.5 + 0.5:
					var m := fwd[i] + fwd[j]
					m = fwd[i] if m.length() < 0.1 else m.normalized()
					# who gives way: the one waiting for the other's junction, else the one behind
					var yields := _waits_for(i, j) or ((pos[j] - pos[i]).dot(m) > 0.0
						and not _waits_for(j, i))
					if yields and _overlap(to, fwd[i], size[i], pos[j], fwd[j], size[j]) \
							and not _overlap(pos[i], fwd[i], size[i], pos[j], fwd[j], size[j]):
						return true
				j = _cell_link[j]
	return false


# whether car i, rolling up to a junction it has no way across yet, would move into the way
# another car has across it (where streets meet at a slant, the kerb line of one street can lie
# in the curve from another)
func _into_way(i: int, by: float) -> bool:
	var p := path[i]
	var node := -1
	if net.is_conn[p] == 0:
		if granted[i] == 1 or nxt[i] < 0 or net.length[p] - s[i] > size[i] + 6.0:
			return false
		node = net.to_node[p]
	else:
		# about to come off a junction onto a street too short to wait on
		var lane := nxt[i]
		if nxt2[i] >= 0 or net.length[p] - s[i] + net.length[lane] > size[i] + 6.0:
			return false
		node = net.to_node[lane]
	var to := pos[i] + fwd[i] * by
	for r in _res_count:
		if _res_node[r] == node and _res_car[r] != i and _on_way(to, i, _res_conn[r]) \
				and not _on_way(pos[i], i, _res_conn[r]):
			return true
	return false


# whether car i standing at `at` would be in the way of connector c
func _on_way(at: Vector2, i: int, c: int) -> bool:
	var line := net.pts[c]
	for k in range(1, line.size()):
		if line[k].distance_to(at) < size[i] * 0.5 + 6.0:
			if _overlap(at, fwd[i], size[i], line[k], (line[k] - line[k - 1]).normalized(),
					4.4):
				return true
	return false


# whether two cars' footprints (length by 2 m, a little shrunk) overlap
static func _overlap(a: Vector2, da: Vector2, la: float, b: Vector2, db: Vector2,
		lb: float) -> bool:
	for axis: Vector2 in [da, da.orthogonal(), db, db.orthogonal()]:
		var ra := absf(axis.dot(da)) * (la * 0.5 - 0.15) + absf(axis.dot(da.orthogonal())) * 0.85
		var rb := absf(axis.dot(db)) * (lb * 0.5 - 0.15) + absf(axis.dot(db.orthogonal())) * 0.85
		if absf(axis.dot(b - a)) > ra + rb:
			return false
	return true


func _reserve(node: int, c: int, car: int) -> void:
	if _res_count >= _res_node.size():
		return
	_res_node[_res_count] = node
	_res_conn[_res_count] = c
	_res_car[_res_count] = car
	_res_count += 1


# whether car i, at the end of its lane, may start across the junction now: its way across
# must be clear, and when the street beyond is too short to wait on (the gap between the two
# halves of a dual carriageway) so must the way across the junction after it
func _may_enter(i: int) -> bool:
	var c := nxt[i]
	var m := net.dst[c]
	if nxt2[i] == -1:
		nxt2[i] = -2
		if net.length[m] < size[i] + GAP + 1.0:
			var out := net.choose(m, _rng)
			if out >= 0:
				nxt2[i] = net.connector(m, out)
				_grow()
	if not _swept_clear(i, c):
		return false
	if nxt2[i] < 0:
		return _clear(i, c, true)
	return _first[m] < 0 and _swept_clear(i, nxt2[i]) and _clear(i, c, false) \
		and _clear(i, nxt2[i], true)


# whether no car stands anywhere along connector c but those crossing its own junction (which
# _clear weighs): where streets meet at odd angles a car waiting on another street, or for
# another junction, can stand in the way
func _swept_clear(i: int, c: int) -> bool:
	var line := net.pts[c]
	var lo := line[0]
	var hi := line[0]
	for q in line:
		lo = lo.min(q)
		hi = hi.max(q)
	var box := Rect2(lo, hi - lo).grow(size[i] * 0.5 + 6.0)
	var node := net.to_node[c]
	for j in count:
		if j == i or not box.has_point(pos[j]):
			continue
		if net.is_conn[path[j]] == 1 and net.to_node[path[j]] == node:
			continue
		var near := (size[i] + size[j]) * 0.5 + 0.5
		for k in range(1, line.size()):
			if line[k].distance_squared_to(pos[j]) < near * near and _overlap(line[k],
					(line[k] - line[k - 1]).normalized(), size[i], pos[j], fwd[j], size[j]):
				return false
	return true


# whether connector c is free of every crossing car's way, and nobody has waited longer for a
# crossing way at its junction; with `room`, whether the street it leads to has room for car i
func _clear(i: int, c: int, room: bool) -> bool:
	var node := net.to_node[c]
	for r in _res_count:
		if _res_node[r] == node and _res_car[r] != i and net.conflict(c, _res_conn[r]):
			return false
	for k in _wait_count:
		var j := _waiting[k]
		if j != i and granted[j] == 0 and net.to_node[path[j]] == node \
				and wait[j] > wait[i] + 0.5 and net.conflict(c, nxt[j]):
			return false
	if not room:
		return true
	var lane := net.dst[c]
	var need := size[i] + GAP
	var j := _first[lane]
	while j >= 0:
		if s[j] - size[j] * 0.5 < need or net.length[lane] < need:
			return false
		j = _link[j]
	return true


func _advance(i: int, by: float) -> void:
	stuck[i] = stuck[i] + TICK if by < 0.01 else 0.0
	if by <= 0.0:
		return
	s[i] += by
	var p := path[i]
	for guard in 8:
		if s[i] <= net.length[p]:
			break
		if net.is_conn[p] == 0 and nxt[i] < 0:
			s[i] = net.length[p]
			_exit[i] = net.node_rim[net.to_node[p]]
			break
		if net.is_conn[p] == 0 and granted[i] == 0:
			s[i] = net.length[p]
			break
		s[i] -= net.length[p]
		if net.is_conn[p] == 0:
			p = nxt[i]
			nxt[i] = net.dst[p]
		else:
			p = net.dst[p]
			_plan(i, p)
		path[i] = p
		seg[i] = 0
	_place(i)


# car i's place, direction and sprite heading from its path and distance along it
func _place(i: int) -> void:
	var p := path[i]
	seg[i] = net.seg_at(p, s[i], seg[i])
	pos[i] = net.point(p, s[i], seg[i])
	fwd[i] = net.direction(p, seg[i])
	head[i] = CarSprites.heading(fwd[i])


# car i has just come onto lane p: picks its way out at the far end (already granted when it
# was planned with the junction before)
func _plan(i: int, p: int) -> void:
	wait[i] = 0.0
	if nxt2[i] >= 0:
		nxt[i] = nxt2[i]
		nxt2[i] = -1
		granted[i] = 1
		return
	var out := net.choose(p, _rng)
	nxt[i] = net.connector(p, out) if out >= 0 else -1
	nxt2[i] = -1
	granted[i] = 0
	_grow()


# new connectors were made: room for them in the per-path lists
func _grow() -> void:
	if net.path_count() > _first.size():
		var old := _first.size()
		_first.resize(net.path_count())
		for k in range(old, _first.size()):
			_first[k] = -1


# once a second: cars far out of sight make way for new ones near the view
func _upkeep() -> void:
	var i := 0
	while i < count:
		var gone := pos[i].distance_to(_centre) > _reach or stuck[i] > 40.0 \
				or (nxt[i] < 0 and stuck[i] > 3.0)
		if gone and not _visible(pos[i]):
			_remove(i)
			recycled += 1
		else:
			i += 1
	for k in 2:
		if count < target:
			_spawn(false)


func _remove(i: int) -> void:
	var last := count - 1
	if i != last:
		path[i] = path[last]
		s[i] = s[last]
		v[i] = v[last]
		nxt[i] = nxt[last]
		nxt2[i] = nxt2[last]
		granted[i] = granted[last]
		braking[i] = braking[last]
		wait[i] = wait[last]
		stuck[i] = stuck[last]
		kind[i] = kind[last]
		size[i] = size[last]
		pace[i] = pace[last]
		seg[i] = seg[last]
		pos[i] = pos[last]
		prev[i] = prev[last]
		head[i] = head[last]
		fwd[i] = fwd[last]
		_px[i] = _px[last]
		_drawn[i] = _drawn[last]
		_exit[i] = _exit[last]
	count -= 1


# a new car somewhere near the view, out of sight unless `anywhere`; false when no spot was free
func _spawn(anywhere: bool) -> bool:
	if count >= CAP or _spawn_total <= 0.0:
		return false
	for attempt in 12:
		var pick := _rng.randf() * _spawn_total
		var lane := 0
		while lane < net.lane_count - 1 and pick > _spawn_w[lane]:
			pick -= _spawn_w[lane]
			lane += 1
		var at := _rng.randf_range(4.0, net.length[lane] - LOOK)
		var vk := _vehicle(lane)
		var p := net.point(lane, at, net.seg_at(lane, at, 0))
		if p.distance_to(_centre) > _reach or (not anywhere and _visible(p)):
			continue
		var free := true
		for j in count:
			if pos[j].distance_to(p) < 9.0:
				free = false
				break
		if not free:
			continue
		var i := count
		count += 1
		path[i] = lane
		s[i] = at
		kind[i] = vk
		size[i] = float(CarSprites.VARIANTS[vk]["len"])
		pace[i] = _rng.randf_range(0.85, 1.1) * (0.8 if vk == CarSprites.BUS else 1.0)
		v[i] = net.speed[lane] * pace[i] * 0.7
		stuck[i] = 0.0
		braking[i] = 0
		seg[i] = 0
		nxt2[i] = -1
		_plan(i, lane)
		_place(i)
		prev[i] = pos[i]
		_px[i] = _screen(pos[i]).round()
		_drawn[i] = Vector2(-1, -1)
		spawned += 1
		return true
	return false


# what drives on this lane: buses on the avenues and bus lanes, the odd taxi and van, cars
func _vehicle(lane: int) -> int:
	var k: String = net.kind[lane]
	var r := _rng.randf()
	if k == "busway" or (k in ["primary", "secondary", "trunk"] and r < 0.08):
		return CarSprites.BUS
	r = _rng.randf()
	if r < 0.12:
		return CarSprites.TAXI
	if r < 0.24:
		return CarSprites.VANS[_rng.randi() % CarSprites.VANS.size()]
	return _rng.randi() % 5


func _visible(p: Vector2) -> bool:
	return _view.grow(SPRITE_PAD).has_point(_screen(p))


# where a ground point lands in the drawing (Iso.p), and back
func _screen(m: Vector2) -> Vector2:
	return Vector2((m.x + m.y) * Iso.S, (m.x - m.y) * Iso.S * 0.5) + _origin


func _ground(px: Vector2) -> Vector2:
	var a := (px.x - _origin.x) / Iso.S
	var b := 2.0 * (px.y - _origin.y) / Iso.S
	return Vector2((a + b) * 0.5, (a - b) * 0.5)


# --- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	if not _ready_to_draw:
		return
	# far cars first: nearer ones are drawn over them
	for i in count:
		_order[i] = i
	for a in range(1, count):
		var x := _order[a]
		var dx := pos[x].x - pos[x].y
		var b := a - 1
		while b >= 0 and pos[_order[b]].x - pos[_order[b]].y > dx:
			_order[b + 1] = _order[b]
			b -= 1
		_order[b + 1] = x
	for k in CAP:
		var o := k * 4
		if k >= count:
			for c in 4:
				_quad_pts[o + c] = Vector2.ZERO
			continue
		var i := _order[k]
		var n := CarSprites.sprite(kind[i], head[i], braking[i] == 1)
		var r := CarSprites.rects[n]
		var at := _px[i] + CarSprites.offsets[n]
		_drawn[i] = _px[i]
		_quad_pts[o] = at
		_quad_pts[o + 1] = at + Vector2(r.size.x, 0)
		_quad_pts[o + 2] = at + r.size
		_quad_pts[o + 3] = at + Vector2(0, r.size.y)
		_quad_uv[o] = r.position
		_quad_uv[o + 1] = r.position + Vector2(r.size.x, 0)
		_quad_uv[o + 2] = r.end
		_quad_uv[o + 3] = r.position + Vector2(0, r.size.y)
		var code := BlockView.depth_code(pos[i].x - pos[i].y)
		var col := Color8(code & 255, code >> 8, 0)
		for c in 4:
			_quad_col[o + c] = col
	RenderingServer.canvas_item_add_triangle_array(get_canvas_item(), _quad_idx, _quad_pts,
		_quad_col, _quad_uv)


static var _shader: Shader


func _material(view: BlockView, active_radius: float) -> ShaderMaterial:
	if _shader == null:
		_shader = Shader.new()
		_shader.code = """shader_type canvas_item;
render_mode blend_disabled;
uniform sampler2D lut : filter_nearest;
uniform sampler2D atlas : filter_nearest;
uniform sampler2D depth_tex : filter_nearest;
uniform sampler2D shade_tex : filter_nearest;
// where ground (0, 0) lands in the drawing, pixels per metre, the active radius (m)
uniform vec2 origin;
uniform float scale;
uniform float active;
uniform float tol;
""" + Pal.shader_consts() + """
varying vec2 lp;
int pal_at(int x, int row) {
	return int(round(texelFetch(lut, ivec2(x, row), 0).r * 255.0));
}
void vertex() {
	lp = VERTEX;
}
void fragment() {
	vec4 t = texelFetch(atlas, ivec2(floor(UV)), 0);
	if (t.a < 0.5) discard;
	ivec2 size = textureSize(depth_tex, 0);
	ivec2 p = clamp(ivec2(floor(lp)), ivec2(0), size - 1);
	vec4 d = texelFetch(depth_tex, p, 0);
	float occ = round(d.r * 255.0) + round(d.g * 255.0) * 256.0;
	float mine = round(COLOR.r * 255.0) + round(COLOR.g * 255.0) * 256.0;
	// something stands nearer than the car here
	if (occ > 0.5 && occ > mine + tol) discard;
	int idx = int(round(t.r * 255.0));
	if (idx != INK) {
		// the ground just under this pixel of the car: faded beyond the radius, darker in shade
		vec2 c = vec2(p) + vec2(0.5, 1.5) - origin;
		float a = c.x / scale;
		float b = 2.0 * c.y / scale;
		float u = (a + b) * 0.5;
		float v = (b - a) * 0.5;
		if (u * u + v * v > active * active) idx = pal_at(idx, 3);
		if (texelFetch(shade_tex, clamp(p + ivec2(0, 1), ivec2(0), size - 1), 0).r > 0.5)
			idx = pal_at(idx, 1);
	}
	COLOR = vec4(texelFetch(lut, ivec2(idx, 0), 0).rgb, 1.0);
}
"""
	var m := ShaderMaterial.new()
	m.shader = _shader
	m.set_shader_parameter("lut", Pal.lut())
	m.set_shader_parameter("depth_tex", view.depth_tex)
	m.set_shader_parameter("shade_tex", view.shade_tex)
	m.set_shader_parameter("origin", _origin)
	m.set_shader_parameter("scale", Iso.S)
	m.set_shader_parameter("active", active_radius + 2.0 if active_radius > 0.0 else 1.0e9)
	m.set_shader_parameter("tol", HIDE_TOL * BlockView.DEPTH_K)
	return m
