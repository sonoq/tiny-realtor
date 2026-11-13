extends SceneTree

# Boots the real game (res://main.tscn) and drives the whole map flow like a player, saving a PNG
# at each step: the city list, Barcelona's map, the office cursor, the confirm box, the download,
# the office view; a second office in Tokyo and a third in Warsaw; and the red "too close"
# cursor; then the busy-server screen. It needs a real display (run it under xvfb-run, see tools/cloud/screenshot.sh), because
# a headless run renders nothing a viewport could hand back.
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
	print("DONE %d shots -> %s" % [_shots, ProjectSettings.globalize_path(_out)])
	for o in Store.offices():
		print("STATS %s %s" % [o["id"], JSON.stringify(o.get("stats", {}))])
	quit(0)


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
func _shot(name: String) -> void:
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
