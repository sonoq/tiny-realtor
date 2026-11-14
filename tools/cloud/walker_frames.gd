extends SceneTree

# Opens a saved office in the real game (App + OfficeView) and films its pavements, with the
# clock stopped between frames so every run shoots the same moments:
#   gif/NNN.png       - frames one tick (0.1 s) apart at x3 around the crossing near the office
#                       where most people cross, for an animated GIF:
#                       ffmpeg -framerate 10 -i gif/%03d.png -vf "split[a][b];[a]palettegen[p];\
#                           [b][p]paletteuse" walkers.gif
#   walkers_sheet.png - a contact sheet of the middle of every sixth of them (0.6 s apart), x2
#   game_x2.png       - the whole window at x2 on the office, as the game opens it
#   sprites.png       - the walkers' sprite atlas, x6
# then prints BENCH lines (walkers' and cars' ms per tick).
# Needs a display (xvfb-run, see screenshot.sh):
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/walker_frames.gd -- --file=/abs/office.json --out=/abs/dir \
#       [--gif=70] [--settle=40]

# the sheet: every SHEET_EVERY-th frame, the middle SHEET_CROP of it shown twice as big
const SHEET_CROP := Vector2i(150, 150)
const SHEET_COLS := 4
const SHEET_EVERY := 6

var _out := "user://walkers"
var _app: App


func _init() -> void:
	var file := ""
	var gif := 70
	var settle := 40
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--gif="):
			gif = arg.substr(6).to_int()
		elif arg.begins_with("--settle="):
			settle = arg.substr(9).to_int()
	DirAccess.make_dir_recursive_absolute(_out + "/gif")
	await process_frame
	var block: Variant = Store.read_json(file)
	if not block is Dictionary:
		_fail("cannot read " + file)
		return
	if int(block.get("format_version", 0)) == 2:
		block = BlockBaker.upgrade(block)
	var meta: Dictionary = block.get("office", {}).duplicate()
	meta["id"] = "film_" + file.get_file().get_basename()
	block["office"] = meta
	Store.write_json(Store.office_path(meta["id"]), block)
	_app = load("res://main.tscn").instantiate()
	root.add_child(_app)
	await _frames(3)
	_app.open_office(meta)
	var view := _app.screen as OfficeView
	if view == null:
		_fail("the office did not open")
		return
	var t0 := Time.get_ticks_msec()
	while not (view.is_drawn() and view._traffic.is_drawing()):
		await process_frame
		if Time.get_ticks_msec() - t0 > 90000:
			_fail("the office or its traffic never drew")
			return
	var traffic: Traffic = view._traffic
	var walkers := traffic.walkers
	traffic.frozen = true
	# no welcome-back card over the shots
	view.game.away = {}
	view.play().queue_redraw()
	# the game's first view, x2 on the office
	view.set_zoom_step(1)
	view.center()
	await _frames(2)
	(await _grab()).save_png(_out + "/game_x2.png")
	# a crossing, frame by frame at x3
	var at := _busiest(view, traffic, settle)
	view.set_zoom_step(2)
	_centre_on(view, at)
	traffic.run(1)
	await _frames(2)
	var rows := ceili(ceili(gif / float(SHEET_EVERY)) / float(SHEET_COLS))
	var tile := SHEET_CROP * 2
	var sheet := Image.create(tile.x * SHEET_COLS + SHEET_COLS - 1,
		tile.y * rows + rows - 1, false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("INK"))
	var crossed := walkers.crossed
	for k in gif:
		traffic.run(1)
		var img := await _grab()
		img.save_png("%s/gif/%03d.png" % [_out, k])
		if k % SHEET_EVERY == 0:
			var f := k / SHEET_EVERY
			var part := img.get_region(Rect2i(Vector2i(300, 330) - SHEET_CROP / 2, SHEET_CROP))
			part.resize(tile.x, tile.y, Image.INTERPOLATE_NEAREST)
			sheet.blit_rect(part, Rect2i(Vector2i.ZERO, tile),
				Vector2i(f % SHEET_COLS, f / SHEET_COLS) * (tile + Vector2i.ONE))
	sheet.save_png(_out + "/walkers_sheet.png")
	print("FILMED %d frames at %s: %d walkers, %d cars, %d crossed meanwhile" % [gif, at,
		walkers.count, traffic.count, walkers.crossed - crossed])
	var atlas := WalkerSprites.image.duplicate() as Image
	var shown := Image.create(atlas.get_width(), atlas.get_height(), false, Image.FORMAT_RGBA8)
	shown.fill(Pal.c("PAVE"))
	for y in atlas.get_height():
		for x in atlas.get_width():
			var c := atlas.get_pixel(x, y)
			if c.a > 0.5:
				shown.set_pixel(x, y, Pal.color(c.r8))
	shown.resize(shown.get_width() * 6, shown.get_height() * 6, Image.INTERPOLATE_NEAREST)
	shown.save_png(_out + "/sprites.png")
	_bench(traffic)
	print("DONE walker frames -> " + ProjectSettings.globalize_path(_out))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Store.office_path(meta["id"])))
	quit(0)


# runs the clock `settle` seconds, then on until someone steps onto a crossing near the office
# (one no building hides, over a street at least 8 m wide) with the most people around, and gives
# that crossing's middle a little towards where the walker is heading
func _busiest(view: OfficeView, traffic: Traffic, settle: int) -> Vector2:
	var w := traffic.walkers
	var n := w.net
	var depth := view._view.depth_tex.get_image()
	traffic.run(settle * 10)
	var best := Vector2.ZERO
	var most := -1
	for k in 600:
		traffic.run(1)
		for i in w.count:
			var c := w.on_cross[i]
			if c < 0 or w.t[i] > 2.5 or n.c_half[c] < 4.0 or n.c_mid[c].length() > 100.0 \
					or not _in_sight(view, depth, n.c_mid[c]):
				continue
			var around := 0
			for j in w.count:
				if w.pos[j].distance_to(n.c_mid[c]) < 35.0:
					around += 1
			if around > most:
				most = around
				best = n.c_mid[c]
		if most >= 4 or (most >= 0 and k > 300):
			print("WALKERS: a crossing at %s, %d people around, after %d s" % [best, most,
				settle + (k + 1) / 10])
			return best
	print("WALKERS: nobody crossed near the office")
	return best


# whether nothing stands in front of ground point m (a building would hide the crossing)
func _in_sight(view: OfficeView, depth: Image, m: Vector2) -> bool:
	var mine := BlockView.depth_code(m.x - m.y)
	var p := Vector2i(view._view.project(m).round())
	for dy in range(-8, 1, 2):
		var q := p + Vector2i(0, dy)
		if q.x < 0 or q.y < 0 or q.x >= depth.get_width() or q.y >= depth.get_height():
			return false
		var d := depth.get_pixel(q.x, q.y)
		var occ := d.r8 + d.g8 * 256
		if occ > 0 and occ > mine + 2.0 * BlockView.DEPTH_K:
			return false
	return true


func _bench(traffic: Traffic) -> void:
	var w := traffic.walkers
	var wu := 0
	var cu := 0
	var n := 300
	for i in n:
		traffic.step()
		wu += w.tick_usec
		cu += traffic.tick_usec
	print("BENCH walkers %.3f ms per tick (%d walkers), cars %.3f ms per tick (%d cars)" % [
		wu / 1000.0 / n, w.count, cu / 1000.0 / n, traffic.count])


func _centre_on(view: OfficeView, m: Vector2) -> void:
	var z := float(OfficeView.ZOOMS[view._zoom_i])
	var at := view._pan + view._view.project(m) * z
	view.pan_by(Vector2(300, 330) - at)


func _grab() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _fail(why: String) -> void:
	printerr("WALKERS FAILED: " + why)
	quit(1)
