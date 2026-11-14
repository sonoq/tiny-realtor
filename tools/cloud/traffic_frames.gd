extends SceneTree

# Opens a saved office in the real game (App + OfficeView) and films its traffic, with the clock
# stopped between frames so every run shoots the same moments:
#   junction_NN.png  - frames 2 ticks apart at x2 around the busiest junction near the office,
#                      and junction_sheet.png, a contact sheet of their middles
#   gif/NNN.png      - a longer run of the same frames, for an animated GIF (see --gif)
#   hidden.png       - a car half hidden behind a building at x3, beside the same frame with the
#                      depth test off (the car drawn over everything)
# then times frames with the traffic on and off (max fps lifted) and prints BENCH lines.
# Needs a display (xvfb-run, see screenshot.sh):
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/traffic_frames.gd -- --file=/abs/office.json --out=/abs/dir \
#       [--frames=12] [--gif=60] [--bench=6]

const SHEET_CROP := Vector2i(240, 240)

var _out := "user://traffic"
var _app: App


func _init() -> void:
	var file := ""
	var frames := 12
	var gif := 60
	var bench := 6.0
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--frames="):
			frames = arg.substr(9).to_int()
		elif arg.begins_with("--gif="):
			gif = arg.substr(6).to_int()
		elif arg.begins_with("--bench="):
			bench = arg.substr(8).to_float()
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
	traffic.frozen = true
	print("TRAFFIC %d cars (target %d), %d lanes, %d paths" % [traffic.count, traffic.target,
		traffic.net.lane_count, traffic.net.path_count()])
	# 1. a junction, frame by frame
	view.set_zoom_step(1)
	_centre_on(view, _junction(traffic))
	await _frames(2)
	var sheet := Image.create(SHEET_CROP.x * 4, SHEET_CROP.y * ceili(frames / 4.0), false,
		Image.FORMAT_RGBA8)
	for k in maxi(frames, gif):
		traffic.run(2)
		var img := await _grab()
		if k < frames:
			img.save_png("%s/junction_%02d.png" % [_out, k])
			var at := Vector2i(300, 330) - SHEET_CROP / 2
			sheet.blit_rect(img, Rect2i(at, SHEET_CROP), Vector2i(k % 4, k / 4) * SHEET_CROP)
		if k < gif:
			img.save_png("%s/gif/%03d.png" % [_out, k])
	sheet.save_png(_out + "/junction_sheet.png")
	# 2. a car behind a building
	if not await _hidden(view, traffic):
		return
	# 3. frame times
	await _bench(view, traffic, bench)
	print("DONE traffic frames -> " + ProjectSettings.globalize_path(_out))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Store.office_path(meta["id"])))
	quit(0)


# the junction near the office where the busiest streets meet
func _junction(traffic: Traffic) -> Vector2:
	var net := traffic.net
	var best := Vector2.ZERO
	var score := -1.0
	for n in net.node_pos.size():
		if net.node_deg[n] < 3 or net.node_pos[n].length() > 110.0:
			continue
		var sc := 0.0
		for l in net.out_lanes[n]:
			sc += float(RoadNet.PULL.get(net.kind[l], 1.0))
		sc -= net.node_pos[n].length() / 60.0
		if sc > score:
			score = sc
			best = net.node_pos[n]
	return best


func _centre_on(view: OfficeView, m: Vector2) -> void:
	var z := float(OfficeView.ZOOMS[view._zoom_i])
	var at := view._pan + view._view.project(m) * z
	view.pan_by(Vector2(300, 330) - at)


# runs the clock until a car near the office is between a third and two thirds hidden by
# something well in front of it, then shoots it at x3 with and without the depth test
func _hidden(view: OfficeView, traffic: Traffic) -> bool:
	var depth := view._view.depth_tex.get_image()
	var atlas := CarSprites.atlas.get_image()
	for k in 600:
		traffic.run(3)
		for i in traffic.count:
			if traffic.pos[i].length() > 160.0:
				continue
			var share := _hidden_share(traffic, i, depth, atlas)
			if share < 0.3 or share > 0.7:
				continue
			view.set_zoom_step(2)
			_centre_on(view, traffic.pos[i])
			await _frames(2)
			var on := await _grab()
			var mat := traffic.material as ShaderMaterial
			mat.set_shader_parameter("tol", 1.0e9)
			traffic.queue_redraw()
			var off := await _grab()
			mat.set_shader_parameter("tol", Traffic.HIDE_TOL * BlockView.DEPTH_K)
			traffic.queue_redraw()
			var pair := Image.create(1212, 600, false, Image.FORMAT_RGBA8)
			pair.fill(Pal.c("SL0"))
			pair.blit_rect(on, Rect2i(0, 0, 600, 600), Vector2i.ZERO)
			pair.blit_rect(off, Rect2i(0, 0, 600, 600), Vector2i(612, 0))
			pair.save_png(_out + "/hidden.png")
			print("HIDDEN car %d (%s) %.0f%% hidden after %d ticks" % [i,
				CarSprites.VARIANTS[traffic.kind[i]]["kind"], share * 100.0, traffic.ticks])
			return true
	_fail("no car went behind a building")
	return false


# the share of car i's drawn pixels that something at least 4 m nearer stands in front of
func _hidden_share(traffic: Traffic, i: int, depth: Image, atlas: Image) -> float:
	var n := CarSprites.sprite(traffic.kind[i], traffic.head[i], false)
	var r := CarSprites.rects[n]
	var at := Vector2i(traffic._screen(traffic.pos[i]).round() + CarSprites.offsets[n])
	var mine := BlockView.depth_code(traffic.pos[i].x - traffic.pos[i].y)
	var total := 0
	var hid := 0
	for y in int(r.size.y):
		for x in int(r.size.x):
			if atlas.get_pixel(int(r.position.x) + x, int(r.position.y) + y).a < 0.5:
				continue
			var q := at + Vector2i(x, y)
			if q.x < 0 or q.y < 0 or q.x >= depth.get_width() or q.y >= depth.get_height():
				continue
			total += 1
			var d := depth.get_pixel(q.x, q.y)
			var occ := d.r8 + d.g8 * 256
			if occ > 0 and occ > mine + 4.0 * BlockView.DEPTH_K:
				hid += 1
	return float(hid) / maxf(1.0, total)


# frame times with the traffic hidden and stopped, then running
func _bench(view: OfficeView, traffic: Traffic, seconds: float) -> void:
	view.set_zoom_step(1)
	view.center()
	Engine.max_fps = 0
	var cpu := 0
	var n := 0
	for i in 150:
		var t := Time.get_ticks_usec()
		traffic.step()
		cpu += Time.get_ticks_usec() - t
		n += 1
	print("BENCH step %.3f ms per tick (%d cars), %.2f%% of a core at %d Hz" % [cpu / 1000.0 / n,
		traffic.count, cpu / 1000.0 / n / Traffic.TICK / 10.0, roundi(1.0 / Traffic.TICK)])
	for mode in 2:
		traffic.visible = mode == 1
		traffic.frozen = mode == 0
		await _frames(10)
		var frames := 0
		var proc := 0.0
		var t0 := Time.get_ticks_usec()
		while Time.get_ticks_usec() - t0 < seconds * 1.0e6:
			await process_frame
			frames += 1
			proc += Performance.get_monitor(Performance.TIME_PROCESS)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0 / frames
		print("BENCH traffic %s: %.2f ms per frame (%d frames), process %.3f ms per frame" % [
			"on " if mode == 1 else "off", ms, frames, proc * 1000.0 / frames])
	Engine.max_fps = 60


func _grab() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _fail(why: String) -> void:
	printerr("TRAFFIC FAILED: " + why)
	quit(1)
