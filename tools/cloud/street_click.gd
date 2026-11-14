extends SceneTree

# Street names only on click: opens a saved office (the first one, or --id=) in the real game
# with a grown save (level 5, every lot owned and built as high as it may go), shoots the view at
# x2 with no names on it, then clicks the street nearest the middle of the view and shoots its
# name plate. Saves click_street_name.png (the two side by side). Fails when the plain view
# shows a plate, the click shows none, or the plate is still up after the next click. Needs a
# display (xvfb-run, as screenshot.sh). Overwrites user://save.json.
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/street_click.gd -- --out=/abs/dir [--id=office_id] \
#       [--pan=x,y]

const LABEL_H := 56

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
	_app.open_office(meta)
	var view := await _office()
	if view == null:
		return
	# the welcome-back card would take the first click
	view.play().back()
	view.set_zoom_step(1)
	view.pan_by(pan)
	await _frames(60)
	view.hover(Vector2(-100, -100))
	await _frames(4)
	var plain := await _grab()
	if not view.street.is_empty():
		_fail("a street plate shows before any click")
		return
	var spot := _street_near(view, Vector2(300, 300))
	if spot == Vector2.INF:
		_fail("no street near the middle of the view")
		return
	view.hover(spot)
	view.click(spot)
	await _frames(4)
	if view.street.is_empty():
		_fail("clicking a street shows no name")
		return
	var named := await _grab()
	print("STREET click at %s: %s (%s)" % [spot, view.street["name"], view.street["kind"]])
	view.click(Vector2(560, 590))
	await _frames(2)
	if not view.street.is_empty():
		_fail("the plate stays up after the next click")
		return
	var sheet := Image.create(1208, 600 + LABEL_H, false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	_label(sheet, Vector2i(12, 16), "SIN NOMBRES EN EL MAPA", 5, "SL5")
	_label(sheet, Vector2i(620, 16), "CLIC EN UNA CALLE", 5, "GOLD")
	sheet.blit_rect(plain, Rect2i(0, 0, 600, 600), Vector2i(0, LABEL_H))
	sheet.blit_rect(named, Rect2i(0, 0, 600, 600), Vector2i(608, LABEL_H))
	sheet.save_png("%s/click_street_name.png" % _out)
	print("DONE street_click")
	quit(0)


# a canvas point on open ground (no lot drawn there) near `at` that names a street
func _street_near(view: OfficeView, at: Vector2) -> Vector2:
	var best := Vector2.INF
	var dist := INF
	for dy in range(-150, 151, 6):
		for dx in range(-200, 201, 6):
			var q := at + Vector2(dx, dy)
			if q.distance_to(at) >= dist or view.lot_under(q) >= 0:
				continue
			var hit := StreetNames.nearest(view._block, view.ground_at(q))
			if hit.is_empty() or hit["name"] == "":
				continue
			# on the asphalt itself, not just near it
			var line_at: Vector2 = hit["at"]
			if line_at.distance_to(view.ground_at(q)) > float(hit["road"]["width"]) * 0.4:
				continue
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
	printerr("STREET FAILED: " + why)
	quit(1)
