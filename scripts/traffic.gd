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
# Fair turns: a queue moves off a few cars together (a train), a car whose way fits with what is
# crossing may go before an older one held up by it (not once that one has waited PASS_MAX),
# and where a street joins another inside its queue the queued cars keep its way clear for a
# car that has waited longer (_keep_clear), so no one starves. Brake lights show while it
# slows. Cars live around what the window shows: one far away and out of sight is taken off
# and a new one comes in out of sight, near the view. Every choice comes
# from one RandomNumberGenerator seeded by the office id, so a seed always plays the same.
#
# People walk the pavements too (Walkers, stepped here after the cars and drawn in the same
# batch, sorted with them): at a crossing they wait for a gap, and while one is on it the cars
# keep out (`walkers.net.busy`); cars waiting for their junction stop before the zebra.
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
# depth a building must stand in front of a car's middle to hide it (m), and a walker's feet
const HIDE_TOL := 1.5
const WALK_TOL := 0.3
# how far before its junction (m) a car keeps clear of the ways of others there (_keep_clear)
const KEEP_LOOK := 30.0
# a car's length (m), for telling odd junctions (_mark_odd)
const CAR_LEN := 4.4
# a car slower than this (m/s) stands
const STANDING := 0.5
# a car this close (m) behind one crossing a junction may follow it in the same go, up to TRAIN
# cars together
const FOLLOW := 7.0
const TRAIN := 3
# until a car has waited this long (s) at its junction, one whose way fits with the car that
# holds it up there may go first (and a train keep going); after that nobody passes it
const PASS_MAX := 35.0
# cars stop this far (m) before a crossing's band
const CROSS_STOP := 0.6
# seconds simulated before the first frame, so queues have formed at the junctions
const WARMUP := 6.0
# a car further than this from the view's middle (beyond its corners) may be swapped out (m)
const REGION_PAD := 20.0
# art pixels round the view where a car still counts as in sight (half a bus)
const SPRITE_PAD := 24.0
# grid cell (m) for finding cars near a car: bigger than a car's look ahead
const CELL := 12.0
# seconds between redraws of the moving cars
const DRAW_EVERY := 1.0 / 30.0
# sprites drawn in one go: the cars and the walkers
const QUADS := CAP + Walkers.CAP
# a footprint's half width, and how much shorter it counts than the car (m)
const HALF_W := 0.85
const SHRINK := 0.15
# a car in front within this much to either side is in the way, whatever its path (m)
const SENSE_SIDE := 2.1
# countries that drive on the left (CityDb's names)
const LEFT_HAND: Array[String] = ["Reino Unido", "Japón", "Singapur", "Australia", "India",
	"Irlanda", "Sudáfrica", "Nueva Zelanda", "Tailandia", "Indonesia", "Hong Kong"]

var net: RoadNet
# the people on the pavements, null without
var walkers: Walkers
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
var held := PackedByteArray()
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
# how many cars cross together, this one the last: 1 alone, 2 following one...
var train := PackedByteArray()
# 1 while it stands back to keep another's way clear (it waits for its junction there)
var kept := PackedByteArray()

var _rng := RandomNumberGenerator.new()
var _origin := Vector2.ZERO
var _view := Rect2()
var _centre := Vector2.ZERO
var _have_view := false
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
# the same by junction: per node the first entry, per entry the next at its node (-1 ends)
var _node_res := PackedInt32Array()
var _res_link := PackedInt32Array()
var _node_wait := PackedInt32Array()
var _wait_link := PackedInt32Array()
# per lane, whether a way across its junction crosses its end (_mark_odd: paths checked so far)
var _odd_lane := PackedByteArray()
var _odd_done := 0
# per node, the lanes that end at it
var _in_lanes: Array[PackedInt32Array] = []
# cars per lane at this tick's start, so new ways avoid full streets
var _load := PackedInt32Array()
# per lane, connector and the two cars' lengths: where a car stands clear of the other's way
var _tails := {}
# drawing
var _ready_to_draw := false
var _attached := false
# beyond this distance (m) from the office a car is drawn faded
var _active := 1.0e9
var _since_draw := 0.0
var _px := PackedVector2Array()
var _drawn := PackedVector2Array()
var _wpx := PackedVector2Array()
var _wdrawn := PackedVector2Array()
var _order := PackedInt32Array()
# per sprite (cars, then walkers) its ground depth, bigger is nearer
var _keys := PackedFloat32Array()
var _quad_pts := PackedVector2Array()
var _quad_uv := PackedVector2Array()
var _quad_col := PackedColorArray()
var _quad_idx := PackedInt32Array()
var _spawn_w := PackedFloat32Array()
# lanes that reach into the view's surroundings, where new cars start
var _near := PackedInt32Array()
var _near_total := 0.0
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
	walkers = Walkers.new()
	walkers.setup(block, origin, seed_key, self)
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
	held.resize(CAP)
	braking.resize(CAP)
	pos.resize(CAP)
	prev.resize(CAP)
	fwd.resize(CAP)
	train.resize(CAP)
	kept.resize(CAP)
	_px.resize(CAP)
	_drawn.resize(CAP)
	_adv.resize(CAP)
	_exit.resize(CAP)
	_link.resize(CAP)
	_order.resize(QUADS)
	_keys.resize(QUADS)
	_wpx.resize(Walkers.CAP)
	_wdrawn.resize(Walkers.CAP)
	_quad_pts.resize(QUADS * 4)
	_quad_uv.resize(QUADS * 4)
	_quad_col.resize(QUADS * 4)
	_quad_idx.resize(QUADS * 6)
	for i in QUADS:
		for k in 6:
			_quad_idx[i * 6 + k] = i * 4 + [0, 1, 2, 0, 2, 3][k]
	_first.resize(net.path_count())
	_first.fill(-1)
	_load.resize(net.lane_count)
	_load.fill(0)
	_odd_lane.resize(net.lane_count)
	_odd_lane.fill(0)
	_odd_done = net.lane_count
	_in_lanes.resize(net.node_pos.size())
	for n in net.node_pos.size():
		_in_lanes[n] = PackedInt32Array()
	for l in net.lane_count:
		_in_lanes[net.to_node[l]].append(l)
	_cells = ceili((float(block.get("radius_m", 500.0)) + 40.0) * 2.0 / CELL)
	_cell_first.resize(_cells * _cells)
	_cell_first.fill(-1)
	_cell_link.resize(CAP)
	_cell_of.resize(CAP)
	_res_node.resize(CAP * 3)
	_res_conn.resize(CAP * 3)
	_res_car.resize(CAP * 3)
	_waiting.resize(CAP)
	_res_link.resize(CAP * 3)
	_wait_link.resize(CAP)
	_node_res.resize(net.node_pos.size())
	_node_res.fill(-1)
	_node_wait.resize(net.node_pos.size())
	_node_wait.fill(-1)
	# lanes long enough to start on, weighted by how busy their street is
	_spawn_w.resize(net.lane_count)
	for l in net.lane_count:
		_spawn_w[l] = net.length[l] * net.density[l] if net.length[l] >= LOOK + 6.0 else 0.0
	_have_view = false
	set_view(_view if _view.size != Vector2.ZERO
		else Rect2(origin - Vector2(150, 150), Vector2(300, 300)))


# the part of the drawing the window shows (drawing pixels); cars gather around it
func set_view(rect: Rect2) -> void:
	_view = rect
	if net == null:
		return
	walkers.set_view(rect)
	var c := _ground(rect.get_center())
	var far := 0.0
	for corner: Vector2 in [rect.position, rect.end, Vector2(rect.position.x, rect.end.y),
			Vector2(rect.end.x, rect.position.y)]:
		far = maxf(far, c.distance_to(_ground(corner)))
	if _have_view and c.distance_to(_centre) < 15.0 \
			and absf(far * 0.85 - _reach + REGION_PAD) < 15.0:
		return
	_have_view = true
	_centre = c
	_reach = far * 0.85 + REGION_PAD
	var want := 0.0
	_near.clear()
	_near_total = 0.0
	for l in net.lane_count:
		if net.mid[l].distance_to(_centre) < _reach + net.length[l] * 0.5:
			if net.mid[l].distance_to(_centre) < _reach:
				want += net.length[l] * net.density[l] / 100.0
			if _spawn_w[l] > 0.0:
				_near.append(l)
				_near_total += _spawn_w[l]
	target = clampi(roundi(want), 6 if want > 3.0 else 0, CAP)
	walkers.set_region(_centre, _reach)


# fills the streets near the view and lets them settle for a few seconds, so the first frame
# already shows cars queued at junctions rather than all freshly placed
func populate() -> void:
	# the crossings: where new cars may not start
	walkers.ensure()
	for k in target * 4:
		if count >= target:
			break
		_spawn(true)
	walkers.populate()
	for k in roundi(WARMUP / TICK):
		step()


# hands the drawing's depth and shadow images to the car shader and draws the sprites; cars
# show once their atlas is ready
func attach(view: BlockView, active_radius: float) -> void:
	material = _material(view, active_radius)
	WalkerSprites.build()
	(material as ShaderMaterial).set_shader_parameter("walk_atlas", WalkerSprites.atlas)
	populate()
	# drawn under the root (it outlives this screen); _process waits for it
	CarSprites.build(get_tree().root)
	_attached = true


# n ticks at once, drawn where they end; for tools that shoot frames at set times
func run(n: int) -> void:
	for k in n:
		step()
	for i in count:
		prev[i] = pos[i]
		_px[i] = _screen(pos[i]).round()
	for i in walkers.count:
		walkers.prev[i] = walkers.pos[i]
		_wpx[i] = _screen(walkers.pos[i]).round()
	queue_redraw()


func is_drawing() -> bool:
	return _ready_to_draw


func _process(delta: float) -> void:
	if not _ready_to_draw:
		if not _attached or CarSprites.atlas == null:
			return
		(material as ShaderMaterial).set_shader_parameter("atlas", CarSprites.atlas)
		_ready_to_draw = true
		_acc = 0.0
		queue_redraw()
	if frozen:
		return
	_acc += delta
	_since_draw += delta
	var n := 0
	while _acc >= TICK and n < 4:
		step()
		_acc -= TICK
		n += 1
	if n == 4:
		_acc = 0.0
	# whole-pixel steps look the same redrawn 30 times a second as 60
	if _since_draw < DRAW_EVERY:
		return
	_since_draw = 0.0
	var t := _acc / TICK
	var moved := n > 0
	for i in count:
		var q := _screen(prev[i].lerp(pos[i], t)).round()
		if q != _drawn[i]:
			moved = true
		_px[i] = q
	for i in walkers.count:
		var q := _screen(walkers.prev[i].lerp(walkers.pos[i], t)).round()
		if q != _wdrawn[i]:
			moved = true
		_wpx[i] = q
	if moved:
		queue_redraw()


func _notification(what: int) -> void:
	# never leave the walking network's thread running
	if what == NOTIFICATION_PREDELETE and walkers != null:
		walkers.ensure()


# one tick of the simulation
func step() -> void:
	var t0 := Time.get_ticks_usec()
	ticks += 1
	_clock += 1
	var half := float(_cells) * CELL * 0.5
	_load.fill(0)
	for i in count:
		_link[i] = _first[path[i]]
		_first[path[i]] = i
		if path[i] < net.lane_count:
			_load[path[i]] += 1
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
		elif nxt[j] >= 0 and (net.length[pj] - s[j] < LOOK or kept[j] == 1):
			var node := net.to_node[pj]
			_waiting[_wait_count] = j
			_wait_link[_wait_count] = _node_wait[node]
			_node_wait[node] = _wait_count
			_wait_count += 1
		if granted[j] == 1 and nxt2[j] >= 0:
			_reserve(net.to_node[nxt2[j]], nxt2[j], j)
	# speeds first, from where everyone is now; then everyone moves
	for i in count:
		_adv[i] = _drive(i)
	for i in count:
		_first[path[i]] = -1
		_cell_first[_cell_of[i]] = -1
	for r in _res_count:
		_node_res[_res_node[r]] = -1
	for k in _wait_count:
		_node_wait[net.to_node[path[_waiting[k]]]] = -1
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
	walkers.step()


# the speed car i settles on this tick and how far it may go
func _drive(i: int) -> float:
	var p := path[i]
	var half := size[i] * 0.5
	var top := net.speed[p] * (pace[i] if net.is_conn[p] == 0 else 1.0)
	var want := top
	var room := INF
	# someone on a crossing ahead: stop before it
	var walk := _walk_gap(i)
	if walk < INF:
		want = minf(want, sqrt(2.0 * BRAKE * maxf(0.0, walk - 0.3)))
		room = maxf(0.0, walk - 0.3)
	if net.is_conn[p] == 0 and nxt[i] < 0:
		# nowhere to go: off the world at the disc's edge, else a stop at the end
		if net.node_rim[net.to_node[p]] == 0:
			room = minf(room, maxf(0.0, net.length[p] - s[i] - half - 0.3))
			want = minf(want, sqrt(2.0 * BRAKE * room))
	elif net.is_conn[p] == 0:
		var to_end := net.length[p] - s[i]
		# into the coming turn no faster than it allows
		var vt := net.speed[nxt[i]]
		want = minf(want, sqrt(vt * vt + 2.0 * BRAKE * maxf(0.0, to_end - 0.5)))
		var stop := v[i] * v[i] / (2.0 * BRAKE)
		# at the kerb line, or before the zebra on it
		var line := INF
		var keep := INF
		if granted[i] == 0:
			line = maxf(0.0, to_end - half - 0.3)
			if to_end < LOOK + half + 6.0:
				line = minf(line, _zebra_line(i))
			# and where it keeps clear of others' ways (only at odd junctions)
			if to_end < KEEP_LOOK and _odd_lane[p] == 1:
				keep = _keep_clear(i, minf(line, maxf(0.0, walk - 0.3)))
		# near its kerb line, or where it keeps clear of an older car's way: it waits there (and
		# asks for its way only near the kerb line)
		kept[i] = 1 if granted[i] == 0 and keep < 1.0 + stop else 0
		var near := to_end < LOOK + stop
		if granted[i] == 0 and (near or kept[i] == 1):
			wait[i] += TICK
			# not while people cross before the junction or just after it: the others waiting
			# there do not give way to it meanwhile
			var held_up := walk < to_end + net.length[nxt[i]] + 6.0
			if held_up:
				held[i] = 1
			# asked a few times a second, each car on its own beat
			if near and not held_up and (_clock + i) % 3 == 0 and _may_enter(i):
				granted[i] = 1
				_reserve(net.to_node[nxt[i]], nxt[i], i)
				if nxt2[i] >= 0:
					_reserve(net.to_node[nxt2[i]], nxt2[i], i)
		if granted[i] == 0:
			line = minf(line, keep)
			want = minf(want, sqrt(2.0 * BRAKE * line))
			room = minf(room, line)
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


# distance from car i's front to the nearest crossing someone is on, along its way (this path
# and the next two), INF for none; a crossing its front is already in does not count (it drives
# out of it)
func _walk_gap(i: int) -> float:
	var wn := walkers.net
	if wn.busy_total == 0:
		return INF
	var p := path[i]
	var front := s[i] + size[i] * 0.5
	var best := INF
	for depth in 3:
		var b := wn.bands(net, p)
		for k in range(0, b.size(), 3):
			if wn.busy[int(b[k])] > 0 and front < b[k + 1] + 0.05:
				best = minf(best, b[k + 1] - front)
		if best < INF:
			return best
		front -= net.length[p]
		if front < -45.0:
			break
		if depth == 0:
			p = nxt[i]
		elif net.is_conn[p] == 1:
			p = net.dst[p]
		else:
			break
		if p < 0:
			break
	return INF


# distance from car i's front to where it waits before a crossing at the end of its lane, INF
# for none: a car waiting for its junction leaves the zebra clear
func _zebra_line(i: int) -> float:
	var p := path[i]
	if net.is_conn[p] == 1:
		return INF
	var b := walkers.net.bands(net, p)
	var front := s[i] + size[i] * 0.5
	var best := INF
	for k in range(0, b.size(), 3):
		# only where it still waits within LOOK of its lane's end (where it asks for its way)
		if b[k + 1] - CROSS_STOP - size[i] * 0.5 > net.length[p] - LOOK + 0.5 \
				and front < b[k + 1] + 0.2:
			best = minf(best, maxf(0.0, b[k + 1] - CROSS_STOP - front))
	return best


# distance from car i's front to where it stops so as not to stand in the way of a car that has
# waited longer at its junction, or of one crossing it now, INF for none: where a street joins
# another inside its queue (at a slant, or into the middle of a wide junction) the cars queued
# at their kerb line stand on the joining car's way, and a new one rolling up each time the
# last one went would starve it
func _keep_clear(i: int, line: float) -> float:
	var p := path[i]
	var node := net.to_node[p]
	if _node_wait[node] < 0 and _node_res[node] < 0:
		return INF
	var front := s[i] + size[i] * 0.5
	# where it would stop otherwise: its line (kerb, zebra, people) or the car in front (whose
	# rear only moves on); one that stops beyond a way does not stand in it
	var reach := front + line
	var a := _first[p]
	while a >= 0:
		if s[a] > s[i]:
			reach = minf(reach, s[a] - size[a] * 0.5 - GAP)
		a = _link[a]
	# a stop in front of one way can fall in another: until it falls in none
	var at := reach
	for guard in 4:
		var was := at
		var k := _node_wait[node]
		while k >= 0:
			var j := _waiting[k]
			if j != i and path[j] != p and _older(j, i):
				at = _short_of(_tail(p, size[i], nxt[j], size[j]), front, at)
			k = _wait_link[k]
		var r := _node_res[node]
		while r >= 0:
			var j := _res_car[r]
			var rc := _res_conn[r]
			if j != i and net.src[rc] != p:
				var t := _tail(p, size[i], rc, size[j])
				if path[j] != rc or s[j] < t.y + 0.5:
					at = _short_of(t, front, at)
			r = _res_link[r]
		if at == was:
			break
	return INF if at >= reach else maxf(0.0, at - front)


# where a car whose front is at `front` and would stop at `at` stops instead so as not to stand
# in way t (_tail): before it, unless it is already in it or would stop beyond it
static func _short_of(t: Vector3, front: float, at: float) -> float:
	if t.y < 0.0 or front >= t.x + 0.5 or at <= t.x or at >= t.z + 0.5:
		return at
	return t.x


# marks the lanes whose end a way across their junction crosses at all (odd junctions: a street
# joining inside the queue), for the connectors made since the last call; most never are,
# and there nobody keeps clear. Tested for cars (where only a bus would reach, the bus is not
# kept clear of: rare, and the safeguards hold)
func _mark_odd() -> void:
	while _odd_done < net.path_count():
		var c := _odd_done
		_odd_done += 1
		if net.is_conn[c] == 0:
			continue
		for l in _in_lanes[net.to_node[c]]:
			if _odd_lane[l] == 0 and net.src[c] != l and _near_end(l, c) \
					and _tail(l, CAR_LEN, c, CAR_LEN).y >= 0.0:
				_odd_lane[l] = 1


# whether connector c comes within a car's reach of the last KEEP_LOOK metres of lane l (a
# cheap test before _tail's)
func _near_end(l: int, c: int) -> bool:
	var lane := net.pts[l]
	var cum := net.cum[l]
	var from := net.length[l] - KEEP_LOOK
	var reach := CAR_LEN + HALF_W * 2.0 + 0.5
	for k in range(1, net.pts[c].size()):
		var q := net.pts[c][k]
		for e in range(1, lane.size()):
			if cum[e] < from:
				continue
			var d := Geometry2D.get_closest_point_to_segment(q, lane[e - 1], lane[e]).distance_to(q)
			if d < reach:
				return true
	return false


# whether car j has waited longer than car i at their junction (one order for both: a tie goes
# to the lower number)
func _older(j: int, i: int) -> bool:
	return wait[j] > wait[i] + 0.25 or (wait[j] >= wait[i] - 0.25 and j < i)


# where the way a car of length lc takes across connector c crosses the last KEEP_LOOK metres
# of lane l, for a car of length li on it: x, the furthest its front may be before it stands in
# that way (the kerb line when the way never comes near); y, how far along c the way last
# touches it (-1 for never; a car on c past y is out of the way); z, the furthest front that
# still stands in it (past z it has gone by). Cached: the streets never change
func _tail(l: int, li: float, c: int, lc: float) -> Vector3:
	var key := (l * 65536 + c) * 16384 + roundi(li * 10.0) * 128 + roundi(lc * 10.0)
	if _tails.has(key):
		return _tails[key]
	var line := net.pts[c]
	var kerb := net.length[l] - 0.3
	var lo := maxf(li * 0.5, net.length[l] - KEEP_LOOK)
	var out := Vector3(kerb, -1.0, -1.0)
	var hit_lo := INF
	var f := kerb
	while f >= lo:
		for k in range(1, line.size()):
			if _stands_on(l, li, f, line, k, lc):
				hit_lo = f
				out.z = maxf(out.z, f)
				break
		f -= 0.5
	if hit_lo < INF:
		out.x = hit_lo - 0.5
		out.y = 0.0
		for k in range(line.size() - 1, 0, -1):
			var hit := false
			f = out.z
			while f >= hit_lo and not hit:
				hit = _stands_on(l, li, f, line, k, lc)
				f -= 0.5
			if hit:
				out.y = net.cum[c][k]
				break
	_tails[key] = out
	return out


# whether a car of length li standing on lane l with its front at f overlaps a car of length lc
# at point k of a connector's line
func _stands_on(l: int, li: float, f: float, line: PackedVector2Array, k: int,
		lc: float) -> bool:
	var mid := maxf(f - li * 0.5, 0.0)
	var seg := net.seg_at(l, mid, 0)
	var q := net.point(l, mid, seg)
	return line[k].distance_squared_to(q) < ((li + lc) * 0.5 + 0.5) ** 2 and _overlap(line[k],
		(line[k] - line[k - 1]).normalized(), lc, q, net.direction(l, seg), li)


# bumper-to-bumper distance to the car ahead, on this path or the next two, INF for none
func _gap(i: int) -> float:
	var p := path[i]
	var best := INF
	var nearest := INF
	var j := _first[p]
	while j >= 0:
		if j != i and s[j] > s[i] and s[j] - s[i] < nearest:
			nearest = s[j] - s[i]
			best = nearest - (size[i] + size[j]) * 0.5
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
	var r := _node_res[node]
	while r >= 0:
		if _res_car[r] != i and _on_way(to, i, _res_conn[r]) \
				and not _on_way(pos[i], i, _res_conn[r]):
			return true
		r = _res_link[r]
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
	var d := b - a
	var na := da.orthogonal()
	var nb := db.orthogonal()
	var ha := la * 0.5 - SHRINK
	var hb := lb * 0.5 - SHRINK
	return _apart(da, d, da, na, ha, db, nb, hb) == false \
		and _apart(na, d, da, na, ha, db, nb, hb) == false \
		and _apart(db, d, da, na, ha, db, nb, hb) == false \
		and _apart(nb, d, da, na, ha, db, nb, hb) == false


# whether two footprints are apart along one axis (separating axis test)
static func _apart(axis: Vector2, d: Vector2, da: Vector2, na: Vector2, ha: float, db: Vector2,
		nb: Vector2, hb: float) -> bool:
	var ra := absf(axis.dot(da)) * ha + absf(axis.dot(na)) * HALF_W
	var rb := absf(axis.dot(db)) * hb + absf(axis.dot(nb)) * HALF_W
	return absf(axis.dot(d)) > ra + rb


func _reserve(node: int, c: int, car: int) -> void:
	if _res_count >= _res_node.size():
		return
	_res_node[_res_count] = node
	_res_conn[_res_count] = c
	_res_car[_res_count] = car
	_res_link[_res_count] = _node_res[node]
	_node_res[node] = _res_count
	_res_count += 1


# whether car i, at the end of its lane, may start across the junction now: its way across
# must be clear, and when the street beyond is too short to wait on (the gap between the two
# halves of a dual carriageway) so must the way across the junction after it
func _may_enter(i: int) -> bool:
	var c := nxt[i]
	var m := net.dst[c]
	if nxt2[i] == -1:
		nxt2[i] = -2
		if net.length[m] < size[i] + 1.0:
			var out := net.choose(m, _rng, _load)
			if out >= 0:
				nxt2[i] = net.connector(m, out)
				_grow()
	# a lane crosses in turn: never before the car in front of it (meanwhile it is not free to
	# go, so the others waiting here do not give way to it)
	var lead := -1
	var j := _first[path[i]]
	while j >= 0:
		if j != i and s[j] > s[i]:
			if granted[j] == 0:
				held[i] = 1
				return false
			if lead < 0 or s[j] < s[lead]:
				lead = j
		j = _link[j]
	# right behind a car that has just gone the same way: it follows in the same go (a few
	# cars at most), as a queue moves off together, which saves each its own start
	var follow := _leader(i, lead)
	# a short street beyond not free yet is like no room: the others still give way to it
	if nxt2[i] >= 0 and not _via_free(i, m):
		held[i] = 0
		return false
	# held up by a car standing in its way: the others waiting here do not give way to it
	# meanwhile (that car may be one of them); one driving through is gone in a moment
	var way := maxi(_swept(i, c, follow), _swept(i, nxt2[i], follow) if nxt2[i] >= 0 else 0)
	if way > 0:
		held[i] = 1 if way == 2 else 0
		return false
	held[i] = 0
	if not _clear(i, c, true, follow >= 0):
		return false
	if nxt2[i] >= 0 and not _clear(i, nxt2[i], false, false):
		return false
	if not _room(i, nxt2[i] if nxt2[i] >= 0 else c, _train_room(i, c) if follow >= 0 else 0.0):
		return false
	train[i] = train[follow] + 1 if follow >= 0 else 1
	return true


# the car that car i may follow across its junction without waiting its own turn, -1 for none: the
# nearest in front on its lane (lead) if it has its way, else the last one onto its connector;
# it must take the same way, be close in front and not lead a long train already
func _leader(i: int, lead: int) -> int:
	var c := nxt[i]
	if nxt2[i] >= 0:
		return -1
	var front := s[i] + size[i] * 0.5
	var gap := INF
	if lead >= 0:
		if nxt[lead] == c and nxt2[lead] < 0:
			gap = s[lead] - size[lead] * 0.5 - front
	else:
		var j := _first[c]
		while j >= 0:
			if lead < 0 or s[j] < s[lead]:
				lead = j
			j = _link[j]
		if lead >= 0:
			gap = net.length[path[i]] - front + s[lead] - size[lead] * 0.5
	if gap > FOLLOW or train[lead] >= TRAIN:
		return -1
	return lead


# the room (m) the cars of car i's train take that are not on the street beyond yet: the one
# in front on its lane, if it has its way, and those on connector c
func _train_room(i: int, c: int) -> float:
	var need := 0.0
	var j := _first[path[i]]
	while j >= 0:
		if j != i and s[j] > s[i] and granted[j] == 1 and nxt[j] == c:
			need += size[j] + GAP
		j = _link[j]
	j = _first[c]
	while j >= 0:
		need += size[j] + GAP
		j = _link[j]
	return need


# whether the short street m between car i's two junctions is free for it: nobody on it and
# nobody on the way into it (one in front on the same lane is not caught by the conflicts). It
# holds one car: one there, even with its way on, can stand (people on the zebra beyond) and i
# would stop in the junction behind it
func _via_free(i: int, m: int) -> bool:
	if _first[m] >= 0:
		return false
	var r := _node_res[net.from_node[m]]
	while r >= 0:
		if _res_car[r] != i and net.dst[_res_conn[r]] == m:
			return false
		r = _res_link[r]
	return true


# what stands along connector c, besides the cars crossing its own junction (which _clear
# weighs): 0 nobody, 1 a car driving by, 2 a car standing in the way. Where streets meet at odd
# angles a car waiting on another street, or for another junction, can stand there
func _swept(i: int, c: int, skip: int) -> int:
	var line := net.pts[c]
	var lo := line[0]
	var hi := line[0]
	for q in line:
		lo = lo.min(q)
		hi = hi.max(q)
	var box := Rect2(lo, hi - lo).grow(size[i] * 0.5 + 6.0)
	var node := net.to_node[c]
	var into := net.dst[c]
	var found := 0
	for j in count:
		# one on the street it leads to is _room's business (no room yet, not held up)
		if j == i or j == skip or path[j] == into or not box.has_point(pos[j]):
			continue
		if net.is_conn[path[j]] == 1 and net.to_node[path[j]] == node:
			continue
		var near := (size[i] + size[j]) * 0.5 + 0.5
		for k in range(1, line.size()):
			if line[k].distance_squared_to(pos[j]) < near * near and _overlap(line[k],
					(line[k] - line[k - 1]).normalized(), size[i], pos[j], fwd[j], size[j]):
				if v[j] < STANDING:
					return 2
				found = 1
				break
	return found


# whether connector c is free of every crossing car's way, and nobody free to go has waited
# longer for a way that crosses it (but see _crossed; and a car following another across,
# `follow`, keeps up with it unless that one has waited over PASS_MAX); with `tail`, also of the
# ways that cross the end of car i's lane in front of it (a street joining inside the queue)
func _clear(i: int, c: int, tail: bool, follow: bool) -> bool:
	var node := net.to_node[c]
	var p := path[i]
	var front := s[i] + size[i] * 0.5
	var r := _node_res[node]
	while r >= 0:
		var rc := _res_conn[r]
		var j := _res_car[r]
		if j != i:
			if net.conflict(c, rc):
				if not _past(j, rc, c):
					return false
			elif tail and net.src[rc] != p and _odd_lane[p] == 1:
				var t := _tail(p, size[i], rc, size[j])
				if _ahead(t, front) and (path[j] != rc or s[j] < t.y + 0.5):
					return false
		r = _res_link[r]
	var k := _node_wait[node]
	while k >= 0:
		var j := _waiting[k]
		if j != i and granted[j] == 0 and held[j] == 0 and wait[j] > wait[i] + 0.5 \
				and (net.conflict(c, nxt[j]) or (tail and path[j] != p and _odd_lane[p] == 1
				and _in_way(p, i, front, nxt[j], j))) \
				and (wait[j] > PASS_MAX or (not follow and not _crossed(j, i))):
			return false
		k = _wait_link[k]
	return true


# whether the way car j takes across connector c crosses lane p ahead of car i's front
func _in_way(p: int, i: int, front: float, c: int, j: int) -> bool:
	return _ahead(_tail(p, size[i], c, size[j]), front)


# whether way t (_tail) crosses the lane still ahead of a car whose front is at `front`
static func _ahead(t: Vector3, front: float) -> bool:
	return t.y >= 0.0 and front <= t.z


# whether car j, on its way across connector rc, is already past where rc meets connector c
# (its rear beyond the stretch where they come close): then it is out of c's way
func _past(j: int, rc: int, c: int) -> bool:
	return path[j] == rc and s[j] - size[j] * 0.5 > net.conflict_end(rc, c) + 0.5


# whether the way of car j (waiting at its junction) is crossed now by a car other than car i:
# j cannot go yet anyway, and one that does not cross that car may go meanwhile (only while j
# has not waited long: PASS_MAX), so the junction lets through what fits together
func _crossed(j: int, i: int) -> bool:
	var c := nxt[j]
	var r := _node_res[net.to_node[c]]
	while r >= 0:
		var k := _res_car[r]
		var rc := _res_conn[r]
		if k != i and k != j and net.conflict(c, rc) and not _past(k, rc, c):
			return true
		r = _res_link[r]
	return false


# whether the street connector c leads to has room for the whole of car i (and `extra` m more:
# the car it follows, not on it yet)
func _room(i: int, c: int, extra: float) -> bool:
	var lane := net.dst[c]
	var need := size[i] + GAP + extra
	if extra > 0.0 and net.length[lane] < need:
		return false
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
	held[i] = 0
	kept[i] = 0
	if nxt2[i] >= 0:
		nxt[i] = nxt2[i]
		nxt2[i] = -1
		granted[i] = 1
		return
	var out := net.choose(p, _rng, _load)
	nxt[i] = net.connector(p, out) if out >= 0 else -1
	nxt2[i] = -1
	granted[i] = 0
	_grow()


# new connectors were made: room for them in the per-path lists
func _grow() -> void:
	_mark_odd()
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
		held[i] = held[last]
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
		train[i] = train[last]
		kept[i] = kept[last]
		_px[i] = _px[last]
		_drawn[i] = _drawn[last]
		_exit[i] = _exit[last]
	count -= 1


# a new car somewhere near the view, out of sight unless `anywhere`; false when no spot was free
func _spawn(anywhere: bool) -> bool:
	if count >= CAP or _near_total <= 0.0:
		return false
	for attempt in 12:
		var pick := _rng.randf() * _near_total
		var k := 0
		while k < _near.size() - 1 and pick > _spawn_w[_near[k]]:
			pick -= _spawn_w[_near[k]]
			k += 1
		var lane := _near[k]
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
		# nor on a crossing (someone may be on it)
		var bands := walkers.net.bands(net, lane)
		for n in range(0, bands.size(), 3):
			if at + 8.0 > bands[n + 1] and at - 8.0 < bands[n + 2]:
				free = false
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
	# far sprites first: nearer ones are drawn over them (walkers numbered after the cars)
	var n_all := count + walkers.count
	for k in n_all:
		_order[k] = k
		_keys[k] = pos[k].x - pos[k].y if k < count \
			else walkers.pos[k - count].x - walkers.pos[k - count].y
	for a in range(1, n_all):
		var x := _order[a]
		var dx := _keys[x]
		var b := a - 1
		while b >= 0 and _keys[_order[b]] > dx:
			_order[b + 1] = _order[b]
			b -= 1
		_order[b + 1] = x
	for k in QUADS:
		var o := k * 4
		if k >= n_all:
			for c in 4:
				_quad_pts[o + c] = Vector2.ZERO
			continue
		var x := _order[k]
		var r: Rect2
		var at: Vector2
		var ground: Vector2
		var flags := 0
		if x < count:
			var n := CarSprites.sprite(kind[x], head[x], braking[x] == 1)
			r = CarSprites.rects[n]
			at = _px[x] + CarSprites.offsets[n]
			_drawn[x] = _px[x]
			ground = pos[x]
		else:
			var w := x - count
			var n := WalkerSprites.sprite(walkers.look[w], walkers.kind[w], walkers.head[w],
				walkers.frame[w])
			r = WalkerSprites.rects[n]
			at = _wpx[w] + WalkerSprites.offsets[n]
			_wdrawn[w] = _wpx[w]
			ground = walkers.pos[w]
			flags = 2
		_quad_pts[o] = at
		_quad_pts[o + 1] = at + Vector2(r.size.x, 0)
		_quad_pts[o + 2] = at + r.size
		_quad_pts[o + 3] = at + Vector2(0, r.size.y)
		_quad_uv[o] = r.position
		_quad_uv[o + 1] = r.position + Vector2(r.size.x, 0)
		_quad_uv[o + 2] = r.end
		_quad_uv[o + 3] = r.position + Vector2(0, r.size.y)
		var code := BlockView.depth_code(ground.x - ground.y)
		# faded as a whole when its middle is beyond the radius, like a lot's buildings
		if ground.length() > _active:
			flags += 1
		var col := Color8(code & 255, code >> 8, flags)
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
uniform sampler2D walk_atlas : filter_nearest;
uniform sampler2D depth_tex : filter_nearest;
uniform sampler2D shade_tex : filter_nearest;
// where ground (0, 0) lands in the drawing, pixels per metre, the active radius (m)
uniform float tol;
uniform float walk_tol;
""" + Pal.shader_consts() + """
varying vec2 lp;
int pal_at(int x, int row) {
	return int(round(texelFetch(lut, ivec2(x, row), 0).r * 255.0));
}
void vertex() {
	lp = VERTEX;
}
void fragment() {
	// COLOR.b: 1 = faded beyond the radius, 2 = a walker (its own atlas and tolerance)
	int flags = int(round(COLOR.b * 255.0));
	bool walker = (flags & 2) != 0;
	vec4 t;
	if (walker) t = texelFetch(walk_atlas, ivec2(floor(UV)), 0);
	else t = texelFetch(atlas, ivec2(floor(UV)), 0);
	if (t.a < 0.5) discard;
	ivec2 size = textureSize(depth_tex, 0);
	ivec2 p = clamp(ivec2(floor(lp)), ivec2(0), size - 1);
	vec4 d = texelFetch(depth_tex, p, 0);
	float occ = round(d.r * 255.0) + round(d.g * 255.0) * 256.0;
	float mine = round(COLOR.r * 255.0) + round(COLOR.g * 255.0) * 256.0;
	// something stands nearer than the car here
	if (occ > 0.5 && occ > mine + (walker ? walk_tol : tol)) discard;
	int idx = int(round(t.r * 255.0));
	if (idx != INK) {
		// faded beyond the radius (per sprite); darker where the ground just under this pixel
		// lies in a cast shadow
		if ((flags & 1) != 0) idx = pal_at(idx, 3);
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
	_active = active_radius + 2.0 if active_radius > 0.0 else 1.0e9
	m.set_shader_parameter("tol", HIDE_TOL * BlockView.DEPTH_K)
	m.set_shader_parameter("walk_tol", WALK_TOL * BlockView.DEPTH_K)
	return m
