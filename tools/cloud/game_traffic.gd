extends SceneTree

# The game and the traffic together, for Oscar: opens a saved office (the first one, or --id=)
# in the real game with a grown save (level 5, every lot owned and built as high as it may go,
# two lots under works with a crane), lets the cars drive, and saves at x2
# game_with_traffic_<city>.png. Then the check that a car hides behind what was just built: a car
# is stopped on a street just behind an empty lot, the lot is built up to a tower through the
# game's one-lot redraw, and the same crop is saved before | after (cars_hide_<city>.png, x3);
# it fails when the car is still drawn over the new tower. Needs a display (xvfb-run, as
# screenshot.sh). Overwrites user://save.json.
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/game_traffic.gd -- --out=/abs/dir [--id=office_id]

var _out := "user://renders"
var _app: App


func _init() -> void:
	var want := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--id="):
			want = arg.substr(5)
	DirAccess.make_dir_recursive_absolute(_out)
	await process_frame
	var meta := {}
	for o in Store.offices():
		if want == "" or o["id"] == want:
			meta = o
			break
	if meta.is_empty():
		_fail("no saved office to open")
		return
	var id: String = meta["id"]
	var block: Dictionary = Store.read_json(Store.office_path(id))
	var infos := Economy.lot_infos(block)
	# a grown game: everything owned at its highest tier, two lots near the office under works,
	# and one empty lot kept for the hiding check
	var g := Game.new(Game.save_path())
	g.fresh(g.now())
	g.add_office(id, block.get("office_plot", ""))
	g.state["offices"][id]["level"] = Economy.max_level()
	g.state["money"] = 1e15
	var order: Array[int] = []
	for i in infos.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return float(infos[a]["dist"]) < float(infos[b]["dist"]))
	var works: Array[int] = []
	var spare := -1
	for i in order:
		var info: Dictionary = infos[i]
		if info["id"] == block.get("office_plot", ""):
			continue
		g.buy(id, info)
		var l := g.lot(id, info["id"])
		if l.is_empty():
			continue
		l["t"] = int(l["mx"])
		if int(l["mx"]) == 5 and float(info["dist"]) > 40.0:
			if works.size() < 2:
				l["t"] = 3
				l["to"] = 5
				l["start"] = g.now()
				l["end"] = g.now() + 3.0 * 3600.0
				works.append(i)
			elif spare < 0 and float(info["dist"]) < 220.0 and _behind(block["roads"],
					Iso.centroid(AreaBuilder._pts(block["plots"][i]["poly"]))) != Vector2.INF:
				l["t"] = 0
				spare = i
	g.state["last_office"] = id
	g.save()
	_app = load("res://main.tscn").instantiate()
	root.add_child(_app)
	var view := await _office()
	if view == null:
		return
	var traffic: Traffic = view._traffic
	var t0 := Time.get_ticks_msec()
	while not traffic.is_drawing() and Time.get_ticks_msec() - t0 < 30000:
		await process_frame
	await _frames(90)
	view.set_zoom_step(1)
	view.focus_lot(works[0])
	view.pan_by(Vector2(40, 150))
	await _frames(30)
	var city: String = meta["city"]
	await _save("game_with_traffic_%s" % city)
	print("GAME+TRAFFIC %d cars on screen setup, works on %s and %s" % [traffic.count,
		infos[works[0]]["id"], infos[works[1]]["id"]])
	if spare < 0:
		_fail("no empty lot for the hiding check")
		return
	if not await _hide_check(view, traffic, g, id, spare, city):
		return
	print("DONE game_traffic")
	quit(0)


# a car stopped on a street just behind the empty lot, then the lot built up to a tower
func _hide_check(view: OfficeView, traffic: Traffic, g: Game, id: String, lot: int,
		city: String) -> bool:
	traffic.frozen = true
	var best := _behind(view._view.roads(), Iso.centroid(view.lots[lot]["poly"]))
	if best == Vector2.INF or traffic.count == 0:
		_fail("no street behind the empty lot for the hiding check")
		return false
	var was := traffic.pos[0]
	traffic.pos[0] = best
	traffic.prev[0] = best
	traffic.run(0)
	print("HIDE car 0 moved from %s to %s, screen %s" % [str(was), str(best),
		str(traffic._px[0])])
	view.set_zoom_step(2)
	view.pan_by(Vector2(300, 330) - view.drawing_to_screen(view._view.project(best)))
	# street names and the HUD off, so only the drawing and the cars are compared
	view._over.visible = false
	view.play().visible = false
	await _frames(4)
	var before := await _grab()
	var car_at := view.drawing_to_screen(view._view.project(best))
	# build it the way the game does: change the lot, redraw only it
	# (the game the app loaded from the save, not the one written above)
	var game := view.play().game
	var l := game.lot(id, view.play().infos[lot]["id"])
	l["t"] = int(l["mx"])
	view.play().refresh_lot(lot)
	await view._view.redrawn
	await _frames(4)
	var after := await _grab()
	var box := Rect2i(Vector2i(car_at) - Vector2i(150, 200), Vector2i(300, 300))
	box = box.intersection(Rect2i(Vector2i.ZERO, before.get_size()))
	var sheet := Image.create(box.size.x * 2 + 12, box.size.y, false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	sheet.blit_rect(before, box, Vector2i.ZERO)
	sheet.blit_rect(after, box, Vector2i(box.size.x + 12, 0))
	sheet.save_png("%s/cars_hide_%s.png" % [_out, city])
	# the real test: the same frame without the car (moved back where it was) must look the same
	# at the car's spot, so nothing of the car shows through the new tower
	traffic.pos[0] = was
	traffic.prev[0] = was
	traffic.run(0)
	await _frames(4)
	var empty := await _grab()
	var r := Rect2i(Vector2i(car_at) - Vector2i(12, 14), Vector2i(24, 22))
	var shows := 0
	var was_there := 0
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			if after.get_pixel(x, y) != empty.get_pixel(x, y):
				shows += 1
			if before.get_pixel(x, y) != after.get_pixel(x, y):
				was_there += 1
	print("HIDE car at %s behind lot %s: %d pixels changed when the tower went up, %d of the car still show" % [
		str(best), view.play().infos[lot]["id"], was_there, shows])
	if shows > 0 or was_there == 0:
		_fail("the car still shows where the new tower stands")
		return false
	return true


# a point on a street just behind a lot's middle as the camera sees it (smaller x - y), close
# enough that a tower on the lot stands in front of it; INF when there is none
static func _behind(roads: Array, c: Vector2) -> Vector2:
	var best := Vector2.INF
	for road: Dictionary in roads:
		if road["kind"] == "pedestrian":
			continue
		var line := AreaBuilder._pts(road["line"])
		for k in range(1, line.size()):
			for f in 9:
				var p := line[k - 1].lerp(line[k], f / 8.0)
				var behind := (c.x - c.y) - (p.x - p.y)
				if behind < 10.0 or behind > 50.0 or absf((p.x + p.y) - (c.x + c.y)) > 14.0:
					continue
				if best == Vector2.INF or p.distance_to(c) < best.distance_to(c):
					best = p
	return best


func _office() -> OfficeView:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 60000:
		await process_frame
		var v := _app.screen as OfficeView
		if v != null and v.is_drawn():
			return v
	_fail("the office never opened")
	return null


func _grab() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _save(name: String) -> void:
	var img := await _grab()
	img.save_png("%s/%s.png" % [_out, name])
	print("shot %s" % name)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _fail(why: String) -> void:
	printerr("GAME TRAFFIC FAILED: " + why)
	quit(1)
