extends SceneTree

# Runs an office's walkers headless with its traffic for MINUTES simulated minutes (the window
# fixed on the office at x2, as the game opens it) and checks them: every walker stands on a
# pavement (on no carriageway, lot or garden) or on its crossing, and on a carriageway only while
# it holds the crossing; no two walkers ever stand inside each other, none on a car; everyone
# keeps moving (nobody still for STILL_MAX, nobody jumps), people cross the streets, no
# crossing stays busy for ever and no car waits long for people crossing (how the cars do
# otherwise is traffic_check's business; the longest wait is printed); the crossings' busy
# counts match who is on them; a seed always plays the same and another seed differs. By default the made-up fixture areas (no
# network); --file adds saved office areas:
#
#   godot --headless --path . --script res://tools/walker_check.gd
#   godot --headless --path . --script res://tools/walker_check.gd -- --file=/abs/office.json \
#       [--minutes=5]
#
# Prints PASS and exits 0, or prints what failed and exits 1.

const MINUTES := 5.0
# two walkers' middles closer than this stand inside each other (m)
const MIN_SEP := 0.3
# a walker may not stand still longer than this (s): waiting at a kerb gives up at 45 s
const STILL_MAX := 60.0
# nor a crossing stay busy, nor a car wait, longer than this (s)
const BUSY_MAX := 90.0
const CAR_HELD_MAX := 60.0
# no walker moves further than this in one tick (m)
const JUMP_MAX := 0.5
# how far (m) a walker may stray from its crossing's line, and into a carriageway's edge
const CROSS_TOL := 1.0
const KERB_TOL := 0.1
# a car's footprint, a little shrunk (m)
const CAR_HALF_W := 0.8
const CHECK_EVERY := 5
const CELL := 20.0

var _bad := 0


func _init() -> void:
	var files: Array[String] = []
	var minutes := MINUTES
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--file="):
			files.append(arg.substr(7))
		elif arg.begins_with("--minutes="):
			minutes = arg.substr(10).to_float()
	var areas: Array = []
	for at: Vector2 in [Vector2(41.3925, 2.1640), Vector2(35.6595, 139.7005),
			Vector2(52.2297, 21.0122)]:
		var block := BlockBaker.bake(Fixture.area(at.x, at.y, 500.0), at.x, at.y, 500.0)
		block["office"] = {"id": "fixture_%d" % areas.size(),
			"city": ["barcelona", "tokyo", "warszawa"][areas.size()]}
		areas.append([block, "fixture %s" % block["office"]["city"]])
	for f in files:
		var block: Variant = Store.read_json(f)
		if not block is Dictionary:
			_fail("cannot read " + f)
			continue
		if int(block.get("format_version", 0)) == 2:
			block = BlockBaker.upgrade(block)
		areas.append([block, f.get_file()])
	for a: Array in areas:
		_check(a[0], a[1], minutes)
	if _bad == 0:
		print("PASS walker_check")
		quit(0)
	else:
		print("FAIL walker_check: %d problems" % _bad)
		quit(1)


func _check(block: Dictionary, label: String, minutes: float) -> void:
	var t0 := Time.get_ticks_msec()
	var grid := _grid(block)
	var seed: String = block.get("office", {}).get("id", "x")
	var traffic := _traffic(block, seed)
	var w := traffic.walkers
	var net := w.net
	var ticks := roundi(minutes * 60.0 / Traffic.TICK)
	var mark := roundi(60.0 / Traffic.TICK)
	var early := ""
	var off_way := 0
	var unheld := 0
	var inside := 0
	var on_car := 0
	var miscount := 0
	var worst_still := 0.0
	var worst_car := 0.0
	var worst_held := 0.0
	var jumps := 0
	var held_for := PackedFloat32Array()
	held_for.resize(Traffic.CAP)
	held_for.fill(0.0)
	var walked := 0.0
	var usec := 0
	var waits := 0
	var busy_for := PackedFloat32Array()
	busy_for.resize(net.c_mid.size())
	busy_for.fill(0.0)
	var worst_busy := 0.0
	var start_crossed := w.crossed
	for k in ticks:
		traffic.step()
		usec += w.tick_usec
		for i in w.count:
			walked += w.moved[i]
			if w.pos[i].distance_to(w.prev[i]) > JUMP_MAX:
				jumps += 1
				if jumps <= 3:
					print("  %s: walker %d jumped from %s to %s (tick %d): %s" % [label, i,
						w.prev[i], w.pos[i], k, _where(w, i)])
			if w.state[i] == Walkers.WAIT:
				waits += 1
			if w.still[i] > STILL_MAX and worst_still <= STILL_MAX:
				print("  %s: walker %d still at %s (tick %d): %s" % [label, i, w.pos[i], k,
					_where(w, i)])
			worst_still = maxf(worst_still, w.still[i])
		for i in traffic.count:
			worst_car = maxf(worst_car, traffic.stuck[i])
			# standing before a crossing someone is on
			if traffic.v[i] < 0.05 and traffic._walk_gap(i) < 4.0:
				held_for[i] += Traffic.TICK
				if held_for[i] > CAR_HELD_MAX and worst_held <= CAR_HELD_MAX:
					print("  %s: car %d held by walkers at %s (tick %d): %s" % [label, i,
						traffic.pos[i], k, _car(traffic, i)])
				worst_held = maxf(worst_held, held_for[i])
			else:
				held_for[i] = 0.0
		for c in net.busy.size():
			busy_for[c] = busy_for[c] + Traffic.TICK if net.busy[c] > 0 else 0.0
			worst_busy = maxf(worst_busy, busy_for[c])
		if k + 1 == mark:
			early = _state(traffic)
		if k % CHECK_EVERY != 0:
			continue
		var held := PackedInt32Array()
		held.resize(net.c_mid.size())
		held.fill(0)
		for i in w.count:
			var p := w.pos[i]
			if not p.is_finite():
				_fail("%s: walker %d has no position at tick %d" % [label, i, k])
				return
			if w.on_cross[i] >= 0:
				held[w.on_cross[i]] += 1
			var e := w.edge[i]
			var road := _carriageway(grid, p)
			if net.kind[e] == WalkNet.PAVE:
				if road or _in_block(grid, p):
					off_way += 1
					if off_way <= 3:
						print("  %s: walker %d off the pavement (%s) at %s (tick %d): %s" % [
							label, i, "on a carriageway" if road else "on a lot", p, k,
							_where(w, i)])
			else:
				var line := net.pts[e]
				var d := Geometry2D.get_closest_point_to_segment(p, line[0], line[1]).distance_to(p)
				if d > CROSS_TOL:
					off_way += 1
					if off_way <= 3:
						print("  %s: walker %d off its crossing by %.2f m at %s (tick %d)" % [
							label, i, d, p, k])
				if road and net.kind[e] == WalkNet.CROSS and w.on_cross[i] < 0:
					unheld += 1
					if unheld <= 3:
						print("  %s: walker %d on the road without the crossing at %s (tick %d): %s"
							% [label, i, p, k, _where(w, i)])
			for j in range(i + 1, w.count):
				if p.distance_to(w.pos[j]) < MIN_SEP:
					inside += 1
					if inside <= 3:
						print("  %s: walkers %d and %d inside each other at %s (tick %d): %s, %s"
							% [label, i, j, p, k, _where(w, i), _where(w, j)])
			for j in traffic.count:
				if _under_car(p, traffic, j):
					on_car += 1
					if on_car <= 3:
						print("  %s: walker %d under car %d at %s (tick %d): %s" % [label, i,
							j, p, k, _where(w, i)])
		for c in net.c_mid.size():
			if held[c] != net.busy[c]:
				miscount += 1
	var crossed := w.crossed - start_crossed
	var final := _state(traffic)
	print("%s: %d walkway edges (%.1f km), %d crossings, %d walkers wanted, %d on foot, " % [
		label, net.edge_count(), net.pave_m / 1000.0, net.c_mid.size(), w.target, w.count]
		+ "%d came, %d went, %.1f km walked in %.0f min, %d crossed, %d turned back, " % [
		w.spawned, w.recycled, walked / 1000.0, minutes, crossed, w.turned]
		+ "%.0f s waited at kerbs, longest still %.0f s, longest busy crossing %.0f s, " % [
		waits * Traffic.TICK, worst_still, worst_busy]
		+ "longest car wait %.0f s (%.0f s for people), %.3f ms per tick, %d ms" % [worst_car,
		worst_held, usec / 1000.0 / ticks, Time.get_ticks_msec() - t0])
	if w.target > 0 and w.count == 0:
		_fail("%s: nobody walked" % label)
	if off_way > 0:
		_fail("%s: %d times a walker was off the pavement or its crossing" % [label, off_way])
	if unheld > 0:
		_fail("%s: %d times a walker was on the road without holding the crossing" % [label,
			unheld])
	if inside > 0:
		_fail("%s: %d times two walkers stood inside each other" % [label, inside])
	if on_car > 0:
		_fail("%s: %d times a walker stood under a car" % [label, on_car])
	if miscount > 0:
		_fail("%s: %d times a crossing's busy count was wrong" % [label, miscount])
	if worst_still > STILL_MAX:
		_fail("%s: a walker stood still for %.0f s" % [label, worst_still])
	if worst_busy > BUSY_MAX:
		_fail("%s: a crossing was busy for %.0f s" % [label, worst_busy])
	if worst_held > CAR_HELD_MAX:
		_fail("%s: a car waited %.0f s for people crossing" % [label, worst_held])
	if jumps > 0:
		_fail("%s: %d times a walker jumped" % [label, jumps])
	if w.target > 0 and walked < w.target * minutes * 60.0 * 0.5:
		_fail("%s: the walkers hardly moved (%.1f km)" % [label, walked / 1000.0])
	if net.c_mid.size() > 0 and w.target > 0 and crossed == 0:
		_fail("%s: nobody crossed a street" % label)
	var wanted := w.target
	traffic.free()
	# the same seed plays the same, another seed does not
	var again := _traffic(block, seed)
	for k in mark:
		again.step()
	if _state(again) != early:
		_fail("%s: the same seed played differently" % label)
	again.free()
	var other := _traffic(block, seed + "!")
	for k in mark:
		other.step()
	if wanted > 0 and _state(other) == early:
		_fail("%s: another seed played the same" % label)
	other.free()
	if final == "":
		_fail("%s: no final state" % label)


func _traffic(block: Dictionary, seed: String) -> Traffic:
	var t := Traffic.new()
	var focus := Iso.new().p(0.0, 0.0) + Vector2(800, 500)
	t.setup(block, focus, seed)
	t.set_view(Rect2(focus - OfficeView.ANCHOR / 2.0, Ui.CANVAS / 2.0))
	t.populate()
	return t


# everything a walker does, for reports and the seed comparison
func _state(t: Traffic) -> String:
	var w := t.walkers
	var out := "%d %d|" % [w.count, t.count]
	for i in w.count:
		out += "%d,%d,%.4f,%.4f,%d;" % [w.edge[i], w.dir[i], w.pos[i].x, w.pos[i].y, w.state[i]]
	for i in t.count:
		out += "%.4f,%.4f;" % [t.pos[i].x, t.pos[i].y]
	return out


func _where(w: Walkers, i: int) -> String:
	var e := w.edge[i]
	return "edge %d (%s, %.1f m) dir %d at %.2f, state %d, crossing %d, still %.1f s, off %s" % [
		e, ["pave", "cross", "free"][w.net.kind[e]], w.net.length[e], w.dir[i], w.t[i],
		w.state[i], w.on_cross[i], w.still[i], w.off[i]]


func _car(t: Traffic, i: int) -> String:
	var p := t.path[i]
	return "path %d%s %.1f/%.1f m, next %d, granted %d, held %d, wait %.0f s, %.1f m/s, " % [p,
		" (junction)" if t.net.is_conn[p] == 1 else "", t.s[i], t.net.length[p], t.nxt[i],
		t.granted[i], t.held[i], t.wait[i], t.v[i]] \
		+ "walkers ahead at %.1f m" % t._walk_gap(i)


# whether ground point p lies under car j (its footprint: length by 2 m, a little shrunk)
func _under_car(p: Vector2, t: Traffic, j: int) -> bool:
	var d := p - t.pos[j]
	if d.length_squared() > 36.0:
		return false
	var f := t.fwd[j]
	return absf(d.dot(f)) < t.size[j] * 0.5 - 0.1 and absf(d.cross(f)) < CAR_HALF_W


# the roads and blocks by grid cell
func _grid(block: Dictionary) -> Dictionary:
	var g := {"roads": {}, "blocks": {}}
	for r: Dictionary in block["roads"]:
		if r["kind"] == "pedestrian":
			continue
		var line := WalkNet._line(r["line"])
		var half := float(r["width"]) * 0.5
		for i in range(1, line.size()):
			_file(g["roads"], Rect2(line[i - 1], Vector2.ZERO).expand(line[i]).grow(half),
				[line[i - 1], line[i], half])
	for key: String in ["plots", "courts"]:
		for b: Dictionary in block[key]:
			var poly := WalkNet._line(b["poly"])
			_file(g["blocks"], Geo.bounds(poly), poly)
	return g


static func _file(into: Dictionary, box: Rect2, item: Variant) -> void:
	for cy in range(floori(box.position.y / CELL), floori(box.end.y / CELL) + 1):
		for cx in range(floori(box.position.x / CELL), floori(box.end.x / CELL) + 1):
			var key := Vector2i(cx, cy)
			if not into.has(key):
				into[key] = []
			into[key].append(item)


func _carriageway(g: Dictionary, p: Vector2) -> bool:
	for seg: Array in g["roads"].get(Vector2i(floori(p.x / CELL), floori(p.y / CELL)), []):
		if Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1]).distance_to(p) \
				< float(seg[2]) - KERB_TOL:
			return true
	return false


func _in_block(g: Dictionary, p: Vector2) -> bool:
	for poly: PackedVector2Array in g["blocks"].get(Vector2i(floori(p.x / CELL),
			floori(p.y / CELL)), []):
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


func _fail(why: String) -> void:
	print("FAIL " + why)
	_bad += 1
