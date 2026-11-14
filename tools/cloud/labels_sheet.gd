extends SceneTree

# The street-name looks side by side, for Oscar to pick one (OfficeView.LABEL_STYLE): opens a
# saved office (the first one, or --id=) in the real game with a grown save (level 5, every lot
# owned and built as high as it may go), and for each StreetNames look (A, B, C, D) the same
# view at x2 with the cars driving; D points at a street. Saves labels_<letter>.png per look,
# labels_options.png (all four, labelled) and labels_final.png (the look the game uses). Needs a
# display (xvfb-run, as screenshot.sh). Overwrites user://save.json.
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/labels_sheet.gd -- --out=/abs/dir [--id=office_id] \
#       [--pan=x,y]

const LABEL_H := 64

var _out := "user://renders"
var _app: App


func _init() -> void:
	var want := ""
	var pan := Vector2.ZERO
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--id="):
			want = arg.substr(5)
		elif arg.begins_with("--pan="):
			var p := arg.substr(6).split(",")
			pan = Vector2(float(p[0]), float(p[1]))
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
	var g := Game.new(Game.save_path())
	g.fresh(g.now())
	g.add_office(id, block.get("office_plot", ""))
	g.state["offices"][id]["level"] = Economy.max_level()
	g.state["money"] = 1e15
	for info: Dictionary in Economy.lot_infos(block):
		if info["id"] == block.get("office_plot", ""):
			continue
		g.buy(id, info)
		var l := g.lot(id, info["id"])
		if not l.is_empty():
			l["t"] = int(l["mx"])
	g.state["last_office"] = id
	g.save()
	_app = load("res://main.tscn").instantiate()
	root.add_child(_app)
	var sheet := Image.create(1200 + 8, (600 + LABEL_H) * 2 + 8, false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	for style in 4:
		OfficeView.labels = style
		_app.open_office(meta)
		var view := await _office()
		if view == null:
			return
		var traffic: Traffic = view._traffic
		var t0 := Time.get_ticks_msec()
		while not traffic.is_drawing() and Time.get_ticks_msec() - t0 < 30000:
			await process_frame
		view.set_zoom_step(1)
		view.pan_by(pan)
		await _frames(60)
		if style == StreetNames.HOVER:
			var spot := _street_near(view, Vector2(300, 300))
			view.hover(spot)
		else:
			view.hover(Vector2(-100, -100))
		await _frames(4)
		var img := await _grab()
		var letter := StreetNames.NAMES[style].left(1).to_lower()
		img.save_png("%s/labels_%s.png" % [_out, letter])
		if style == OfficeView.LABEL_STYLE:
			# the look the game uses, pointing at a street as a player would
			view.hover(_street_near(view, Vector2(300, 300)))
			await _frames(4)
			(await _grab()).save_png("%s/labels_final.png" % _out)
		var at := Vector2i(style % 2 * 608, style / 2 * (600 + LABEL_H + 8))
		_label(sheet, at + Vector2i(10, 14), StreetNames.NAMES[style], 7, "GOLD")
		sheet.blit_rect(img, Rect2i(0, 0, 600, 600), at + Vector2i(0, LABEL_H))
		print("LABELS %s shot, %d cars, %d names painted in the area, %d over the map" % [
			StreetNames.NAMES[style], traffic.count, view._view._area.painted.size(),
			view._labels_now().size() if style in [StreetNames.MICRO, StreetNames.PLATES] else 0])
	sheet.save_png("%s/labels_options.png" % _out)
	OfficeView.labels = OfficeView.LABEL_STYLE
	print("DONE labels_sheet")
	quit(0)


# a point on the named street nearest `at` (screen), for the hover look
func _street_near(view: OfficeView, at: Vector2) -> Vector2:
	var best := at
	var dist := INF
	for run: Array in view._runs_px:
		if run[0] == "":
			continue
		var z := float(OfficeView.ZOOMS[view.zoom_step()])
		var q := Geometry2D.get_closest_point_to_segment(at, view._pan + run[1] * z,
			view._pan + run[2] * z)
		if q.distance_to(at) < dist:
			dist = q.distance_to(at)
			best = q
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


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _label(img: Image, at: Vector2i, text: String, px: int, colour: String) -> void:
	var dots := {}
	Sprites.micro(dots, 0, 0, text, Pal.i(colour))
	for q: Vector2i in dots:
		img.fill_rect(Rect2i(at + q * px, Vector2i(px, px)), Pal.color(dots[q]))


func _fail(why: String) -> void:
	printerr("LABELS FAILED: " + why)
	quit(1)
