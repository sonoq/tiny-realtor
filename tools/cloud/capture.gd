extends SceneTree

# Boots the real game (res://main.tscn) and drives the whole map flow like a player, saving a PNG
# at each step: the city list, Barcelona's map, the office cursor, the confirm box, the download,
# the office view, pointing at a lot and selecting another (its card); a second office in Tokyo
# and a third in Warsaw; and the red "too close" cursor; then the busy-server screen, and the first
# office again close up on its moving traffic. In the first office it also plays the game: the
# money HUD, the office's pin pointed at, a lot's buy card, buying (with its undo toast), works
# with a crane in progress, the office tab (opened from the pin and from the level line) and a
# level-up in it, the bank and a loan sheet, the office tab's manager page, the welcome-back
# summary, a fully grown area and the 200 px window. It needs a real display (run it under
# xvfb-run, see tools/cloud/screenshot.sh), because a headless run renders nothing a viewport
# could hand back.
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/capture.gd -- --out=/abs/dir [--fixture] [--fresh] \
#       [--spot=city:lat:lon ...] [--raw-cache=/abs/dir]
# --spot (repeatable) replaces the default places; a Barcelona spot also gets the cursor, confirm,
# loading, zoomed-out and too-close shots.
#
# Offices from earlier runs are always wiped first (they would make the new ones "too close");
# --fresh also wipes the cached city maps, so every download is measured from scratch.

const DEFAULT_OUT := "user://screenshots"
# seconds to wait for a download + bake before giving up
const PATIENCE := 1500.0
const SPOTS := [
	{"city": "barcelona", "lat": 41.3925, "lon": 2.1640, "tag": "barcelona"},
	{"city": "tokyo", "lat": 35.6595, "lon": 139.7005, "tag": "tokyo"},
	{"city": "warszawa", "lat": 52.2297, "lon": 21.0122, "tag": "warszawa"},
]

var _out: String = DEFAULT_OUT
var _app: App
var _shots: int = 0
var _spots: Array = SPOTS.duplicate()


func _init() -> void:
	var fresh := false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg == "--fresh":
			fresh = true
		elif arg.begins_with("--spot="):
			var p := arg.substr(7).split(":")
			if _spots == SPOTS:
				_spots = []
			_spots.append({"city": p[0], "lat": float(p[1]), "lon": float(p[2]), "tag": p[0]})
	DirAccess.make_dir_recursive_absolute(_out)
	_wipe(Store.OFFICES)
	for save in ["user://save.json", "user://save_fixture.json"]:
		for ext in ["", ".tmp", ".bak"]:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(save + ext))
	if fresh:
		_wipe(Store.CITIES)
	Store.reload()
	_app = load("res://main.tscn").instantiate()
	root.add_child(_app)
	await _frames(5)
	await _shot("01_cities")

	var n := 2
	for spot: Dictionary in _spots:
		_app.open_city(spot["city"])
		if not await _wait_for("CityMap"):
			return
		var map := _app.screen as CityMap
		await _frames(3)
		if spot["tag"] == "barcelona":
			await _shot("%02d_city_%s" % [n, spot["tag"]])
			n += 1
			map.set_zoom_step(1)
			map.center_on(spot["lat"], spot["lon"])
			map.hover_latlon(spot["lat"], spot["lon"])
			await _shot("%02d_city_cursor" % n)
			n += 1
		else:
			map.set_zoom_step(1)
			map.center_on(spot["lat"], spot["lon"])
		# later offices need an office at level 3 and money: the capture just has them
		if spot != _spots[0]:
			_rich(3)
		map.pick_latlon(spot["lat"], spot["lon"])
		if spot["tag"] == "barcelona":
			await _shot("%02d_confirm" % n)
			n += 1
		else:
			await _shot("%02d_city_%s" % [n, spot["tag"]])
			n += 1
		map.confirm()
		if spot["tag"] == "barcelona":
			await _frames(4)
			await _shot("%02d_loading" % n)
			n += 1
		if not await _wait_for("OfficeView"):
			return
		var view := _app.screen as OfficeView
		if not await _wait_drawn(view):
			return
		await _frames(2)
		await _shot("%02d_office_%s" % [n, spot["tag"]])
		n += 1
		if spot == _spots[0]:
			n = await _lots(view, spot["tag"], n)
			n = await _game(view, spot["tag"], n)
			view = _app.screen as OfficeView
		if spot["tag"] == "barcelona":
			view.set_zoom_step(2)
			await _frames(2)
			await _shot("%02d_office_%s_close" % [n, spot["tag"]])
			n += 1
			view.set_zoom_step(0)
			await _frames(2)
			await _shot("%02d_office_%s_far" % [n, spot["tag"]])
			n += 1
			# the red cursor: back on the city map, 700 m from the new office
			view.back()
			await _wait_for("CityMap")
			map = _app.screen as CityMap
			map.set_zoom_step(1)
			map.center_on(spot["lat"], spot["lon"])
			map.hover_latlon(spot["lat"] + 0.0045, spot["lon"] + 0.0045)
			await _shot("%02d_too_close" % n)
			n += 1
	# what the player sees when every map server is busy
	var busy := Loading.new()
	busy.title = "Nueva oficina en Eixample"
	busy.error = Overpass.BUSY
	_app._show(busy)
	await _frames(3)
	await _shot("%02d_server_busy" % n)
	n += 1
	if not await _traffic(n):
		return
	print("DONE %d shots -> %s" % [_shots, ProjectSettings.globalize_path(_out)])
	for o in Store.offices():
		print("STATS %s %s" % [o["id"], JSON.stringify(o.get("stats", {}))])
	quit(0)


# points at a lot near the office, then clicks another one and shoots its card; Esc (back) must
# close the card before it leaves the office
func _lots(view: OfficeView, tag: String, n: int) -> int:
	var spots: Array[Vector2] = []
	for lot in view.lots_by_distance():
		var at := view.screen_of_lot(lot)
		if at.x > 60 and at.x < 540 and at.y > OfficeView.MAP_TOP + 40 \
				and at.y < OfficeView.MAP_BOTTOM - 30 and view.lot_under(at) == lot:
			spots.append(at)
		if spots.size() >= 3:
			break
	if spots.size() < 3:
		_fail("no lots to point at near the office")
		return n
	view.hover(spots[1])
	await _shot("%02d_office_%s_hover" % [n, tag])
	n += 1
	view.click(spots[2])
	view.hover(spots[2])
	await _shot("%02d_office_%s_lot" % [n, tag])
	n += 1
	if not view.back() or view.is_card_open():
		_fail("Esc did not close the lot card")
	view.hover(Vector2(-100, -100))
	return n


# plays the first office: buy, build, level up, the bank, the manager, coming back, grown
func _game(view: OfficeView, tag: String, n: int) -> int:
	var g := _app.game
	var id: String = view.office["id"]
	var play := view.play()
	view.set_zoom_step(1)
	await _frames(2)
	await _shot("%02d_game_%s_hud" % [n, tag])
	n += 1
	# the office has no building: its pin answers the pointer and opens the office tab
	var pin := view.mark_on_screen() + Vector2(0, 8)
	view.hover(pin)
	if not view.on_mark(pin):
		_fail("the office's pin does not answer the pointer")
		return n
	await _shot("%02d_game_%s_pin" % [n, tag])
	n += 1
	view.click(pin)
	if play.panel_kind() != "office":
		_fail("clicking the office's pin did not open the office tab")
		return n
	view.hover(Vector2(300, 200))
	await _shot("%02d_game_%s_office_tab" % [n, tag])
	n += 1
	view.back()
	if play.panel_kind() != "":
		_fail("Esc did not close the office tab")
		return n
	# the nearest solar inside the radius: its card, buy it, then build on it
	var solar := -1
	for lot in view.lots_by_distance():
		var info: Dictionary = play.infos[lot]
		if int(info["base_tier"]) == 0 and float(info["dist"]) <= g.radius(id) \
				and not g.owns(id, info["id"]):
			solar = lot
			break
	if solar < 0:
		_fail("no solar to buy near the office")
		return n
	view.focus_lot(solar)
	view.select(solar)
	view.hover(Vector2(300, 200))
	await _shot("%02d_game_%s_buy_card" % [n, tag])
	n += 1
	view.click(OfficePlay.MAIN_BTN.get_center())
	if not g.owns(id, play.infos[solar]["id"]):
		_fail("the buy button did not buy the lot")
		return n
	await _redrawn(view)
	await _shot("%02d_game_%s_bought" % [n, tag])
	n += 1
	# rich enough to build up to Bloque in one go: the side button
	g.state["money"] = 5e6
	view.select(solar)
	await _frames(2)
	await _shot("%02d_game_%s_build_card" % [n, tag])
	n += 1
	view.click(OfficePlay.SIDE_BTN.get_center())
	if not g.lot(id, play.infos[solar]["id"]).has("end"):
		_fail("the build button did not start works")
		return n
	await _redrawn(view)
	view.select(-1)
	view.focus_lot(solar)
	view.pan_by(Vector2(0, 60))
	view.hover(view.screen_of_lot(solar))
	await _wait_s(1.0)
	await _shot("%02d_game_%s_works" % [n, tag])
	n += 1
	print("REDRAW lot %dx%d px: main thread %d ms, on screen after %d ms" % [
		view._view.redraw_px.x, view._view.redraw_px.y, view._view.redraw_ms,
		view._view.redraw_wall_ms])
	# the office tab from the level line, and a level-up in it (the whole area is drawn again
	# with the new radius)
	g.state["money"] = Economy.level_cost(1) + 1000.0
	view.click(OfficePlay.LEVEL_ZONE.get_center())
	if play.panel_kind() != "office":
		_fail("the level line did not open the office tab")
		return n
	view.hover(OfficePanel.LEVEL_BTN.get_center())
	await _frames(2)
	await _shot("%02d_game_%s_office_level" % [n, tag])
	n += 1
	view.click(OfficePanel.LEVEL_BTN.get_center())
	if g.level(id) != 2:
		_fail("the office tab's level-up button did not level up")
		return n
	view.back()
	var t0 := Time.get_ticks_msec()
	while view._next_view != null and Time.get_ticks_msec() - t0 < 60000:
		await process_frame
	print("RELEVEL radius %d m redrawn in %d ms" % [roundi(g.radius(id)), Time.get_ticks_msec()
		- t0])
	view.select(-1)
	await _frames(3)
	await _shot("%02d_game_%s_level2" % [n, tag])
	n += 1
	# the bank, and a loan's sheet before signing
	play.open_panel("bank")
	await _frames(2)
	await _shot("%02d_game_%s_bank" % [n, tag])
	n += 1
	play.click(BankPanel.new(g)._row_btn(1).get_center())
	await _frames(2)
	await _shot("%02d_game_%s_loan" % [n, tag])
	n += 1
	play.click(BankPanel.new(g)._sign_btn().get_center())
	play.back()
	await _frames(2)
	# the office tab after the level-up, then its manager page, with a few candidates
	play.open_panel("office")
	await _frames(2)
	await _shot("%02d_game_%s_office_tab2" % [n, tag])
	n += 1
	play.click(OfficePanel.TABS[OfficePanel.PAGE_TEAM].get_center())
	await _frames(2)
	await _shot("%02d_game_%s_manager" % [n, tag])
	n += 1
	play.back()
	# coming back after five hours away
	g.state["seen"] = float(g.state["seen"]) - 5.0 * 3600.0
	g.advance(g.now())
	await _frames(2)
	await _shot("%02d_game_%s_away" % [n, tag])
	n += 1
	# the card ignores taps for a moment after it shows (the click that focuses the window)
	await _wait_s(OfficePlay.AWAY_GRACE_S + 0.2)
	play.click(OfficePlay.AWAY_OK.get_center())
	if not g.away.is_empty():
		_fail("the welcome-back card did not close")
		return n
	# a fully grown area: level 5, every lot owned and built as high as it may go
	_rich(5)
	for lot in play.infos.size():
		var info: Dictionary = play.infos[lot]
		if not g.owns(id, info["id"]):
			g.buy(id, info)
		var l := g.lot(id, info["id"])
		if not l.is_empty():
			l["t"] = int(l["mx"])
			l.erase("to")
			l.erase("end")
	g.save()
	_app.open_office(view.office)
	view = _app.screen as OfficeView
	if not await _wait_drawn(view):
		return n
	view.set_zoom_step(0)
	await _frames(3)
	await _shot("%02d_game_%s_grown_far" % [n, tag])
	n += 1
	view.set_zoom_step(1)
	await _frames(3)
	await _shot("%02d_game_%s_grown" % [n, tag])
	n += 1
	# the 200 px window: the same canvas, a third of the size
	var win := get_root()
	var size := win.size
	win.size = Vector2i(200, 200)
	await _frames(4)
	await _shot("%02d_game_%s_200px" % [n, tag])
	n += 1
	win.size = size
	await _frames(2)
	return n


# a rich player with an office at `level`, for shots that need it
func _rich(level: int) -> void:
	var g := _app.game
	g.state["money"] = 1e15
	for id: String in g.offices():
		g.state["offices"][id]["level"] = maxi(level, g.level(id))
		break


func _redrawn(view: OfficeView) -> void:
	var t0 := Time.get_ticks_msec()
	await process_frame
	while view._view.busy and Time.get_ticks_msec() - t0 < 20000:
		await process_frame
	await _frames(2)


func _wait_s(s: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < s * 1000.0:
		await process_frame


# the first office again, close up (x3) on the car moving nearest the office
func _traffic(n: int) -> bool:
	_app.open_office(Store.offices()[0])
	if not await _wait_for("OfficeView"):
		return false
	var view := _app.screen as OfficeView
	if not await _wait_drawn(view):
		return false
	var traffic: Traffic = view._traffic
	while not traffic.is_drawing():
		await process_frame
	if traffic.count == 0:
		_fail("no traffic in the office")
		return false
	await _frames(20)
	var best := 0
	for i in traffic.count:
		if traffic.v[i] > 1.0 and traffic.pos[i].length() < traffic.pos[best].length():
			best = i
	view.set_zoom_step(2)
	var at := view._pan + view._view.project(traffic.pos[best]) * 3.0
	view.pan_by(Vector2(300, 330) - at)
	await _frames(2)
	await _shot("%02d_office_traffic" % n)
	print("TRAFFIC %d cars, %d lanes" % [traffic.count, traffic.net.lane_count])
	return true


# waits until the app shows a screen of this class; false (and quits) on a failure or timeout
func _wait_for(cls: String) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < PATIENCE * 1000.0:
		await process_frame
		var s := _app.screen
		if s != null and s.get_script().get_global_name() == cls:
			return true
		if s is Loading and (s as Loading).error != "":
			await _shot("99_failed")
			_fail("download failed: " + (s as Loading).error)
			return false
	_fail("timed out waiting for " + cls)
	return false


# the office view draws its area a frame or two after it opens
func _wait_drawn(view: OfficeView) -> bool:
	var t0 := Time.get_ticks_msec()
	while not view.is_drawn():
		await process_frame
		if Time.get_ticks_msec() - t0 > 60000:
			_fail("the office view never finished drawing")
			return false
	return true


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


# grabs the window after the frame has drawn, so a change made just before is in the picture
# (the game layer refreshes ten times a second: wait for it)
func _shot(name: String) -> void:
	await _wait_s(0.15)
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img == null or img.is_empty():
		_fail("empty image for " + name)
		return
	var path := "%s/%s.png" % [_out, name]
	var err := img.save_png(path)
	if err != OK:
		_fail("save_png failed (%d) for %s" % [err, path])
		return
	_shots += 1
	print("shot %-24s %dx%d" % [name, img.get_width(), img.get_height()])


func _wipe(dir: String) -> void:
	var abs_dir := ProjectSettings.globalize_path(dir)
	if not DirAccess.dir_exists_absolute(abs_dir):
		return
	for f in DirAccess.get_files_at(abs_dir):
		DirAccess.remove_absolute(abs_dir.path_join(f))


func _fail(why: String) -> void:
	printerr("CAPTURE FAILED: " + why)
	quit(1)
