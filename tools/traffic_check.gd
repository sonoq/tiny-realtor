extends SceneTree

# Runs an office's traffic headless for MINUTES simulated minutes (the window fixed on the office
# at x2, as the game opens it) and checks it: every car stays on a street (within its width of a
# drivable road line), no two cars ever stand on top of each other, the traffic keeps flowing (no
# car stuck for ever, cars all the way through) and a seed always plays the same (two runs with
# one seed agree to the last bit, another seed differs). By default it uses the made-up
# fixture areas (no network); --file adds saved office areas:
#
#   godot --headless --path . --script res://tools/traffic_check.gd
#   godot --headless --path . --script res://tools/traffic_check.gd -- --file=/abs/office.json \
#       [--minutes=10]
#
# Prints PASS and exits 0, or prints what failed and exits 1.

const MINUTES := 10.0
# metres a car may stray past a street's edge (its body is inside, its middle is checked)
const ROAD_TOL := 0.6
# two cars' middles closer than this stand on each other (a car is 2 m wide)
const MIN_SEP := 2.0
# no car may stand still longer than this (s): the traffic would be jammed for good
const STUCK_MAX := 120.0
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
		print("PASS traffic_check")
		quit(0)
	else:
		print("FAIL traffic_check: %d problems" % _bad)
		quit(1)


func _check(block: Dictionary, label: String, minutes: float) -> void:
	var t0 := Time.get_ticks_msec()
	var grid := _road_grid(block)
	var seed: String = block.get("office", {}).get("id", "x")
	var traffic := _traffic(block, seed)
	var ticks := roundi(minutes * 60.0 / Traffic.TICK)
	var mark := roundi(60.0 / Traffic.TICK)
	var early := ""
	var off_road := 0
	var stacked := 0
	var worst_stuck := 0.0
	var fewest := 9999
	var moved := 0.0
	var usec := 0
	for k in ticks:
		traffic.step()
		usec += traffic.tick_usec
		for i in traffic.count:
			moved += traffic.v[i] * Traffic.TICK
			if traffic.stuck[i] > STUCK_MAX and worst_stuck <= STUCK_MAX:
				print("  %s: car %d stuck at %s (tick %d): %s" % [label, i, traffic.pos[i], k,
					_where(traffic, i)])
			worst_stuck = maxf(worst_stuck, traffic.stuck[i])
		if k + 1 == mark:
			early = _state(traffic)
		if k % CHECK_EVERY != 0:
			continue
		fewest = mini(fewest, traffic.count)
		for i in traffic.count:
			var p := traffic.pos[i]
			if not p.is_finite():
				_fail("%s: car %d has no position at tick %d" % [label, i, k])
				return
			var lane := traffic.path[i]
			if not _on_road(grid, p):
				off_road += 1
				if off_road <= 3:
					print("  %s: car %d off the street at %s (tick %d, path %d, conn %d)" % [
						label, i, p, k, lane, traffic.net.is_conn[lane]])
			for j in range(i + 1, traffic.count):
				if p.distance_to(traffic.pos[j]) < MIN_SEP:
					stacked += 1
					if stacked <= 3:
						print("  %s: cars %d and %d on top of each other at %s (tick %d): %s, %s"
							% [label, i, j, p, k, _where(traffic, i), _where(traffic, j)])
	var final := _state(traffic)
	print("%s: %d lanes, %d paths, %d cars wanted, %d..%d on the streets, %d came, %d went, "
		% [label, traffic.net.lane_count, traffic.net.path_count(), traffic.target, fewest,
		traffic.count, traffic.spawned, traffic.recycled]
		+ "%.1f km driven in %.0f min, longest wait %.0f s, %.3f ms per tick, %d ms" % [
		moved / 1000.0, minutes, worst_stuck, usec / 1000.0 / ticks, Time.get_ticks_msec() - t0])
	if traffic.target > 0 and fewest == 0:
		_fail("%s: the streets emptied" % label)
	if off_road > 0:
		_fail("%s: %d times a car was off the street" % [label, off_road])
	if stacked > 0:
		_fail("%s: %d times two cars stood on each other" % [label, stacked])
	if worst_stuck > STUCK_MAX:
		_fail("%s: a car stood still for %.0f s" % [label, worst_stuck])
	if traffic.target > 0 and moved < traffic.target * minutes * 60.0:
		_fail("%s: the traffic hardly moved (%.1f km)" % [label, moved / 1000.0])
	var wanted := traffic.target
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
	# the window as the game opens the office: x2, the office a little below the middle
	t.set_view(Rect2(focus - OfficeView.ANCHOR / 2.0, Ui.CANVAS / 2.0))
	t.populate()
	return t


func _where(t: Traffic, i: int) -> String:
	var p := t.path[i]
	return "path %d%s %.1f/%.1f m from node %d to %d, next %d, granted %d, %.1f m/s" % [p,
		" (junction)" if t.net.is_conn[p] == 1 else "", t.s[i], t.net.length[p],
		t.net.from_node[p], t.net.to_node[p], t.nxt[i], t.granted[i], t.v[i]]


# every car's lane, place and speed, to the bit
func _state(t: Traffic) -> String:
	var parts := PackedStringArray()
	for i in t.count:
		parts.append("%d:%d:%s:%s:%d" % [t.path[i], t.kind[i], var_to_str(t.pos[i]),
			var_to_str(t.v[i]), t.nxt[i]])
	return str(t.count) + "|" + "|".join(parts)


# the drivable street segments by grid cell, each with its half width
func _road_grid(block: Dictionary) -> Dictionary:
	var grid := {}
	for road: Dictionary in block["roads"]:
		if road["kind"] == "pedestrian":
			continue
		var line := AreaBuilder._pts(road["line"])
		var half := float(road["width"]) * 0.5
		for i in range(1, line.size()):
			var a := line[i - 1]
			var b := line[i]
			var lo := (a.min(b) - Vector2.ONE * (half + 2.0)) / CELL
			var hi := (a.max(b) + Vector2.ONE * (half + 2.0)) / CELL
			for cy in range(floori(lo.y), floori(hi.y) + 1):
				for cx in range(floori(lo.x), floori(hi.x) + 1):
					var key := Vector2i(cx, cy)
					if not grid.has(key):
						grid[key] = []
					grid[key].append([a, b, half])
	return grid


func _on_road(grid: Dictionary, p: Vector2) -> bool:
	var key := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
	for seg: Array in grid.get(key, []):
		var q := Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1])
		if q.distance_to(p) <= float(seg[2]) + ROAD_TOL:
			return true
	return false


func _fail(why: String) -> void:
	print("FAIL: " + why)
	_bad += 1
