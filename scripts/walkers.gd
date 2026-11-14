class_name Walkers
extends RefCounted

# People walking the pavements (WalkNet) of an office's area, simulated with the cars and drawn
# with them by Traffic, which owns this and steps it at its own tick.
#
# Each walker follows its walkway, keeping to the right of it, at its own pace, turns at the
# corners and picks its way at random at every node. Some stop for a moment at a shop front, a
# dog walker more often. At a crossing it waits at the kerb until no car is on it or coming too
# fast to stop, nor has a car been waiting there long (cars waiting for their junction stop
# before the zebra and let people cross in front); then it steps out, and from then on the
# crossing is `busy` and cars keep out of it until the last one is across. Walkers on a crossing
# never wait for a car, so the two never block each other for good. A walker never moves closer
# than SEP to another one (whoever moves later in the tick checks against the other's new place)
# and one held up for STUCK_TURN seconds turns back. They gather around the view like the cars:
# one far away and out of sight makes way for a new one near the view, out of sight. Every
# choice comes from one RandomNumberGenerator seeded by the office id.

const CAP := 48
# walkers per 100 m of walkway near the view
const DENSITY := 4.0
# share of Traffic's region round the view (it reaches past the view's corners) they keep to
const REGION := 0.8
# closest two walkers' middles ever come (m)
const SEP := 0.45
# keeping right: how far from the walkway's middle line (m)
const LAT_MIN := 0.25
const LAT_MAX := 0.4
# passing someone in the way: how far over to step (m) and for how long (s)
const DODGE := 0.75
const DODGE_FOR := 2.0
# how far sideways a walker drifts per tick, to round corners and change sides smoothly (m)
const LAT_RATE := 0.07
# a walker waits this far before the kerb (m)
const WAIT_BACK := 0.7
# seconds a walker waits at a kerb before it gives up and turns back
const PATIENCE := 30.0
# seconds held up before turning back
const STUCK_TURN := 4.0
# a car that has waited this long at its junction gets to go first (s)
const CAR_TURN := 6.0
# the braking a walker counts on from a car coming (m/s2), gentler than Traffic.BRAKE
const CAR_SLOW := 1.5
# a granted car this close along its way (m) crosses first
const GRANTED_NEAR := 50.0
# half the band (m, along the street) a walker crossing takes, for the cars standing on it
const WALK_BAND := 1.0
# a walker counts as in sight this many art pixels beyond the view
const SPRITE_PAD := 12.0
# grid cell (m) for finding walkers near a walker
const CELL := 3.0
# metres walked per frame of the walk
const STRIDE := 0.32
enum { WALK, PAUSE, WAIT }

var net: WalkNet
var traffic: Traffic
var count := 0
var target := 0
var spawned := 0
var recycled := 0
var turned := 0
var crossed := 0
var tick_usec := 0

# --- one entry per walker (the first `count`) ---
var edge := PackedInt32Array()
var dir := PackedInt32Array()
# distance walked along the edge from the node it entered by
var t := PackedFloat32Array()
var seg := PackedInt32Array()
var pace := PackedFloat32Array()
var lat := PackedFloat32Array()
var off := PackedVector2Array()
var pos := PackedVector2Array()
var prev := PackedVector2Array()
var fwd := PackedVector2Array()
var head := PackedInt32Array()
var frame := PackedInt32Array()
var stride := PackedFloat32Array()
var look := PackedInt32Array()
var kind := PackedInt32Array()
var state := PackedInt32Array()
var timer := PackedFloat32Array()
var stuck := PackedFloat32Array()
# seconds left stepping out to the other side of the walkway, to pass someone in the way
var dodge := PackedFloat32Array()
# the crossing it is on (busy), -1 none
var on_cross := PackedInt32Array()
# where along the edge it stops for a moment (-1 none) and for how long
var pause_at := PackedFloat32Array()
var pause_for := PackedFloat32Array()
var moved := PackedFloat32Array()
# seconds since it last took a step, whatever it was doing (for checks)
var still := PackedFloat32Array()

var _rng := RandomNumberGenerator.new()
var _origin := Vector2.ZERO
var _view := Rect2()
var _centre := Vector2.ZERO
var _reach := 300.0
var _clock := 0
var _near := PackedInt32Array()
var _near_total := 0.0
var _cells := 0
var _half := 0.0
var _cell_first := PackedInt32Array()
var _cell_link := PackedInt32Array()
var _cell_of := PackedInt32Array()


func setup(block: Dictionary, origin: Vector2, seed_key: String, cars: Traffic) -> void:
	_origin = origin
	traffic = cars
	_rng.seed = (seed_key + "/walk").hash()
	net = WalkNet.new()
	net.build(block)
	edge.resize(CAP)
	dir.resize(CAP)
	seg.resize(CAP)
	head.resize(CAP)
	frame.resize(CAP)
	look.resize(CAP)
	kind.resize(CAP)
	state.resize(CAP)
	on_cross.resize(CAP)
	t.resize(CAP)
	pace.resize(CAP)
	lat.resize(CAP)
	stride.resize(CAP)
	timer.resize(CAP)
	stuck.resize(CAP)
	dodge.resize(CAP)
	pause_at.resize(CAP)
	pause_for.resize(CAP)
	moved.resize(CAP)
	still.resize(CAP)
	off.resize(CAP)
	pos.resize(CAP)
	prev.resize(CAP)
	fwd.resize(CAP)
	_half = net.radius + 40.0
	_cells = ceili(_half * 2.0 / CELL)
	_cell_first.resize(_cells * _cells)
	_cell_first.fill(-1)
	_cell_link.resize(CAP)
	_cell_of.resize(CAP)


# the part of the drawing the window shows (drawing pixels), for what counts as in sight
func set_view(view: Rect2) -> void:
	_view = view


# the ground region around the view (Traffic's): walkers gather inside it
func set_region(centre: Vector2, reach: float) -> void:
	_centre = centre
	_reach = reach * REGION
	var want := 0.0
	_near.clear()
	_near_total = 0.0
	for e in net.edge_count():
		if net.kind[e] != WalkNet.PAVE:
			continue
		var d := net.mid[e].distance_to(_centre)
		if d < _reach + net.length[e] * 0.5:
			if d < _reach:
				want += net.length[e] * DENSITY / 100.0
			if net.length[e] >= 2.0:
				_near.append(e)
				_near_total += net.length[e]
	target = clampi(roundi(want), 0, CAP)


func populate() -> void:
	for k in target * 4:
		if count >= target:
			break
		_spawn(true)


# one tick (Traffic.TICK), after the cars have moved
func step() -> void:
	var t0 := Time.get_ticks_usec()
	_clock += 1
	for i in count:
		var c := clampi(floori((pos[i].x + _half) / CELL), 0, _cells - 1) \
			+ clampi(floori((pos[i].y + _half) / CELL), 0, _cells - 1) * _cells
		_cell_of[i] = c
		_cell_link[i] = _cell_first[c]
		_cell_first[c] = i
	for i in count:
		prev[i] = pos[i]
		_walk(i)
	for i in count:
		_cell_first[_cell_of[i]] = -1
	if _clock % 10 == 0:
		_upkeep()
	tick_usec = Time.get_ticks_usec() - t0


func _walk(i: int) -> void:
	var e := edge[i]
	var L := net.length[e]
	var go := pace[i] * Traffic.TICK
	var k := net.kind[e]
	var cr := net.cross[e]
	match state[i]:
		PAUSE:
			timer[i] -= Traffic.TICK
			go = 0.0
			if timer[i] <= 0.0:
				state[i] = WALK
		WAIT:
			go = 0.0
			timer[i] += Traffic.TICK
			# a look both ways first, then asked a few times a second, each on its own beat
			if timer[i] > pause_for[i] and (_clock + i) % 2 == 0 and _clear(cr):
				_commit(i, cr)
			elif timer[i] > PATIENCE:
				_turn(i)
				return
	if state[i] == WALK:
		if k == WalkNet.CROSS and on_cross[i] < 0:
			var near := _near_kerb(i)
			if t[i] <= _far_kerb(i):
				var stop := maxf(0.0, near - WAIT_BACK)
				if t[i] + go >= stop - 0.01:
					go = maxf(0.0, stop - t[i])
					state[i] = WAIT
					timer[i] = 0.0
					pause_for[i] = _rng.randf_range(0.3, 1.5)
		elif pause_at[i] >= 0.0 and t[i] + go >= pause_at[i]:
			go = maxf(0.0, pause_at[i] - t[i])
			pause_at[i] = -1.0
			state[i] = PAUSE
			timer[i] = pause_for[i]
	var by := _move(i, go)
	moved[i] = by
	still[i] = 0.0 if by > 0.0 else still[i] + Traffic.TICK
	if by < go * 0.5 and state[i] == WALK:
		stuck[i] += Traffic.TICK
		if stuck[i] > STUCK_TURN:
			_turn(i)
			return
	else:
		stuck[i] = 0.0
	if on_cross[i] >= 0 and t[i] > _far_kerb(i) + 0.35:
		_release(i)
	if t[i] >= L - 1e-4:
		_next(i, t[i] - L)


# moves walker i on by up to `go` (m) along its edge, sideways towards its side of the walkway,
# as far as it can without coming closer than SEP to anyone; returns how far it went. Held up,
# it steps out to the other side for a moment to pass
func _move(i: int, go: float) -> float:
	var e := edge[i]
	var L := net.length[e]
	var want_t := minf(t[i] + go, L)
	var side_lat := lat[i]
	# never on a crossing: there the cars stop just clear of the walkers' side of it
	if net.kind[e] != WalkNet.PAVE:
		dodge[i] = 0.0
	if dodge[i] > 0.0:
		dodge[i] -= Traffic.TICK
		side_lat -= DODGE
	for attempt in 3:
		var nt := want_t if attempt < 2 else t[i]
		var se := nt if dir[i] == 1 else L - nt
		var sg := net.seg_at(e, se, seg[i])
		var d := net.direction(e, sg) * float(dir[i])
		var o := off[i]
		if attempt != 1:
			o = o.move_toward(Vector2(d.y, -d.x) * side_lat, LAT_RATE)
		if attempt == 2 and o == off[i]:
			return 0.0
		var np := net.point(e, se, sg) + o
		if _free(i, np):
			var by := nt - t[i]
			t[i] = nt
			seg[i] = sg
			off[i] = o
			pos[i] = np
			if by > 0.0:
				fwd[i] = d
			elif go > 0.0 and dodge[i] <= 0.0 and net.kind[e] == WalkNet.PAVE:
				dodge[i] = DODGE_FOR
			_face(i, by)
			return by
		if attempt == 1 and go > 0.0 and dodge[i] <= 0.0 and net.kind[e] == WalkNet.PAVE:
			dodge[i] = DODGE_FOR
	return 0.0


# whether walker i may stand at p: no one within SEP, unless it is moving away from them
func _free(i: int, p: Vector2) -> bool:
	var c := _cell_of[i]
	var cx := c % _cells
	var cy := c / _cells
	for oy in range(maxi(cy - 1, 0), mini(cy + 2, _cells)):
		for ox in range(maxi(cx - 1, 0), mini(cx + 2, _cells)):
			var j := _cell_first[oy * _cells + ox]
			while j >= 0:
				if j != i:
					var d2 := p.distance_squared_to(pos[j])
					if d2 < SEP * SEP and d2 <= pos[i].distance_squared_to(pos[j]) + 1e-6:
						return false
				j = _cell_link[j]
	return true


# heading and walk frame: the way it walks, the shop window it looks at, the way across
func _face(i: int, by: float) -> void:
	var look_dir := fwd[i]
	if state[i] == PAUSE and net.kind[edge[i]] == WalkNet.PAVE:
		var e := edge[i]
		look_dir = Vector2(fwd[i].y, -fwd[i].x) * float(net.side[e] * dir[i])
	head[i] = WalkerSprites.heading(look_dir)
	if by <= 0.0:
		frame[i] = 1
		return
	stride[i] += by
	var phase := int(stride[i] / STRIDE) % 4
	frame[i] = [0, 1, 2, 1][phase]


# at the end of its edge: on along another one from that node (not straight back unless it is
# a dead end), with what was left of the step
func _next(i: int, rest: float) -> void:
	var e := edge[i]
	var node := net.eb[e] if dir[i] == 1 else net.ea[e]
	var back := e * 2 + (1 if dir[i] == 1 else 0)
	var outs := net.node_out[node]
	var total := 0.0
	for h in outs:
		total += _weight(i, h, back)
	var pick := back
	if total > 0.0:
		var r := _rng.randf() * total
		for h in outs:
			var w := _weight(i, h, back)
			if w <= 0.0:
				continue
			pick = h
			r -= w
			if r <= 0.0:
				break
	_enter(i, pick, rest)


func _weight(i: int, h: int, back: int) -> float:
	if h == back:
		return 0.0
	var e := h >> 1
	var k := net.kind[e]
	if k == WalkNet.PAVE:
		return 1.0
	# no queueing three deep at a kerb
	var d := 1 if (h & 1) == 0 else -1
	var queued := 0
	for j in count:
		if j != i and edge[j] == e and dir[j] == d and on_cross[j] < 0:
			queued += 1
	if queued >= 3:
		return 0.0
	# people cross the street often: a walk zigzags rather than rounding the same block
	return 1.3 if k == WalkNet.CROSS else 0.8


func _enter(i: int, h: int, rest: float) -> void:
	var e := h >> 1
	edge[i] = e
	dir[i] = 1 if (h & 1) == 0 else -1
	t[i] = clampf(rest, 0.0, net.length[e])
	seg[i] = 0 if dir[i] == 1 else net.pts[e].size() - 2
	state[i] = WALK
	stuck[i] = 0.0
	pause_at[i] = -1.0
	if net.kind[e] == WalkNet.PAVE and net.length[e] > 4.0:
		var odds := 0.25 if kind[i] == WalkerSprites.DOG else 0.1
		if _rng.randf() < odds:
			pause_at[i] = _rng.randf_range(1.0, net.length[e] - 1.0)
			pause_for[i] = _rng.randf_range(1.5, 5.0)


# turns round where it stands (held up too long, or tired of waiting at a kerb)
func _turn(i: int) -> void:
	var L := net.length[edge[i]]
	t[i] = L - t[i]
	dir[i] = -dir[i]
	state[i] = WALK
	stuck[i] = 0.0
	pause_at[i] = -1.0
	turned += 1


# --- crossings -----------------------------------------------------------------------------------

# the near and far kerbs along walker i's crossing, in its own direction
func _near_kerb(i: int) -> float:
	var c := net.cross[edge[i]]
	return net.c_k0[c] if dir[i] == 1 else net.length[edge[i]] - net.c_k1[c]


func _far_kerb(i: int) -> float:
	var c := net.cross[edge[i]]
	if c < 0:
		return -INF
	return net.c_k1[c] if dir[i] == 1 else net.length[edge[i]] - net.c_k0[c]


func _commit(i: int, c: int) -> void:
	state[i] = WALK
	on_cross[i] = c
	net.busy[c] += 1
	net.busy_total += 1
	crossed += 1


func _release(i: int) -> void:
	net.busy[on_cross[i]] -= 1
	net.busy_total -= 1
	on_cross[i] = -1


# whether crossing c may be stepped onto now: no car on it, none coming that could not stop
# gently, none that has its junction and will drive through it, none on its way through it that
# has waited long for its junction
func _clear(c: int) -> bool:
	if traffic == null or net.c_free[c] == 1:
		return true
	var tr := traffic
	var m := net.c_mid[c]
	var along := net.c_along[c]
	var across := net.c_across[c]
	var reach := net.c_half[c] + 1.5
	for j in tr.count:
		var d := tr.pos[j] - m
		if d.length_squared() > 4900.0:
			continue
		var hl := tr.size[j] * 0.5
		if absf(d.dot(across)) < reach and absf(d.dot(along)) < WALK_BAND + hl + 0.4:
			return false
		var dist := car_distance(j, c)
		if dist == INF:
			continue
		var v := tr.v[j]
		if tr.granted[j] == 1 and dist < GRANTED_NEAR:
			return false
		if v > 0.3 and dist < v * v / (2.0 * CAR_SLOW) + 4.0 + v * 0.6:
			return false
		if tr.wait[j] > CAR_TURN and dist < GRANTED_NEAR:
			return false
	return true


# how far car j's front is from crossing c's band along the way it is going (its path and the
# next two), INF when it does not go through it
func car_distance(j: int, c: int) -> float:
	var tr := traffic
	var rn := tr.net
	var p := tr.path[j]
	var front := tr.s[j] + tr.size[j] * 0.5
	for depth in 3:
		var b := net.bands(rn, p)
		for k in range(0, b.size(), 3):
			if int(b[k]) == c and front - tr.size[j] < b[k + 2]:
				return maxf(0.0, b[k + 1] - front)
		front -= rn.length[p]
		if depth == 0:
			p = tr.nxt[j]
		elif rn.is_conn[p] == 1:
			p = rn.dst[p]
		else:
			break
		if p < 0:
			break
	return INF


# --- population ----------------------------------------------------------------------------------

func _upkeep() -> void:
	var i := 0
	while i < count:
		var gone := pos[i].distance_to(_centre) > _reach or stuck[i] > 30.0
		if gone and not _visible(pos[i]):
			_remove(i)
			recycled += 1
		else:
			i += 1
	for k in 2:
		if count < target:
			_spawn(false)


func _remove(i: int) -> void:
	if on_cross[i] >= 0:
		_release(i)
	var last := count - 1
	if i != last:
		edge[i] = edge[last]
		dir[i] = dir[last]
		seg[i] = seg[last]
		head[i] = head[last]
		frame[i] = frame[last]
		look[i] = look[last]
		kind[i] = kind[last]
		state[i] = state[last]
		on_cross[i] = on_cross[last]
		t[i] = t[last]
		pace[i] = pace[last]
		lat[i] = lat[last]
		stride[i] = stride[last]
		timer[i] = timer[last]
		stuck[i] = stuck[last]
		dodge[i] = dodge[last]
		pause_at[i] = pause_at[last]
		pause_for[i] = pause_for[last]
		moved[i] = moved[last]
		still[i] = still[last]
		off[i] = off[last]
		pos[i] = pos[last]
		prev[i] = prev[last]
		fwd[i] = fwd[last]
	count -= 1


func _spawn(anywhere: bool) -> bool:
	if count >= CAP or _near_total <= 0.0:
		return false
	for attempt in 12:
		var pick := _rng.randf() * _near_total
		var k := 0
		while k < _near.size() - 1 and pick > net.length[_near[k]]:
			pick -= net.length[_near[k]]
			k += 1
		var e := _near[k]
		var d := 1 if _rng.randf() < 0.5 else -1
		var at := _rng.randf_range(0.5, net.length[e] - 0.5)
		var se := at if d == 1 else net.length[e] - at
		var sg := net.seg_at(e, se, 0)
		var dv := net.direction(e, sg) * float(d)
		var side_lat := _rng.randf_range(LAT_MIN, LAT_MAX)
		var o := Vector2(dv.y, -dv.x) * side_lat
		var p := net.point(e, se, sg) + o
		if p.distance_to(_centre) > _reach or (not anywhere and _visible(p)):
			continue
		var free := true
		for j in count:
			if pos[j].distance_to(p) < 1.5:
				free = false
				break
		if not free:
			continue
		var i := count
		count += 1
		edge[i] = e
		dir[i] = d
		t[i] = at
		seg[i] = sg
		lat[i] = side_lat
		off[i] = o
		pos[i] = p
		prev[i] = p
		fwd[i] = dv
		look[i] = _rng.randi() % WalkerSprites.LOOK_COUNT
		var r := _rng.randf()
		kind[i] = WalkerSprites.DOG if r < 0.08 else (WalkerSprites.PRAM if r < 0.13 else 0)
		pace[i] = _rng.randf_range(1.0, 1.5) * (0.85 if kind[i] != 0 else 1.0)
		state[i] = WALK
		timer[i] = 0.0
		stuck[i] = 0.0
		dodge[i] = 0.0
		stride[i] = _rng.randf() * STRIDE * 4.0
		on_cross[i] = -1
		pause_at[i] = -1.0
		moved[i] = 0.0
		still[i] = 0.0
		_face(i, 0.0)
		spawned += 1
		return true
	return false


func _visible(p: Vector2) -> bool:
	return _view.grow(SPRITE_PAD).has_point(_screen(p))


func _screen(m: Vector2) -> Vector2:
	return Vector2((m.x + m.y) * Iso.S, (m.x - m.y) * Iso.S * 0.5) + _origin
