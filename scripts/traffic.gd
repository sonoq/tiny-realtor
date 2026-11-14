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
	_px.resize(CAP)
	_drawn.resize(CAP)
	_adv.resize(CAP)
	_exit.resize(CAP)
	_link.resize(CAP)
	_order.resize(QUADS)
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
		if granted[i] == 0 and to_end < LOOK + v[i] * v[i] / (2.0 * BRAKE):
			wait[i] += TICK
			# not while people cross before the junction or just after it: the others waiting
			# there do not give way to it meanwhile
			var held_up := walk < to_end + net.length[nxt[i]] + 6.0
			if held_up:
				held[i] = 1
			# asked a few times a second, each car on its own beat
			if not held_up and (_clock + i) % 3 == 0 and _may_enter(i):
				granted[i] = 1
				_reserve(net.to_node[nxt[i]], nxt[i], i)
				if nxt2[i] >= 0:
					_reserve(net.to_node[nxt2[i]], nxt2[i], i)
		if granted[i] == 0:
			# at the kerb line, or before the zebra on it
			var line := maxf(0.0, to_end - half - 0.3)
			if to_end < LOOK + half + 6.0:
				line = minf(line, _zebra_line(i))
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
	# a lane crosses in turn: never before the car in front of it (meanwhile it is not free to
	# go, so the others waiting here do not give way to it)
	var j := _first[path[i]]
	while j >= 0:
		if j != i and s[j] > s[i] and granted[j] == 0:
			held[i] = 1
			return false
		j = _link[j]
	# held up by a car standing in its way: the others waiting here do not give way to it
	# meanwhile (that car may be one of them)
	held[i] = 1
	if not _swept_clear(i, c):
		return false
	if nxt2[i] >= 0 and (_first[m] >= 0 or not _swept_clear(i, nxt2[i])):
		return false
	held[i] = 0
	return _clear(i, c) and (nxt2[i] < 0 or _clear(i, nxt2[i])) \
		and _room(i, nxt2[i] if nxt2[i] >= 0 else c)


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


# whether connector c is free of every crossing car's way, and nobody free to go has waited
# longer for a crossing way at its junction
func _clear(i: int, c: int) -> bool:
	var node := net.to_node[c]
	for r in _res_count:
		if _res_node[r] == node and _res_car[r] != i and net.conflict(c, _res_conn[r]):
			return false
	for k in _wait_count:
		var j := _waiting[k]
		if j != i and granted[j] == 0 and held[j] == 0 and net.to_node[path[j]] == node \
				and wait[j] > wait[i] + 0.5 and net.conflict(c, nxt[j]):
			return false
	return true


# whether the street connector c leads to has room for the whole of car i
func _room(i: int, c: int) -> bool:
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
	held[i] = 0
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
	for a in range(1, n_all):
		var x := _order[a]
		var dx := _sort_key(x)
		var b := a - 1
		while b >= 0 and _sort_key(_order[b]) > dx:
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


# depth order of sprite x (cars, then walkers): bigger is nearer
func _sort_key(x: int) -> float:
	if x < count:
		return pos[x].x - pos[x].y
	var w := x - count
	return walkers.pos[w].x - walkers.pos[w].y


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
