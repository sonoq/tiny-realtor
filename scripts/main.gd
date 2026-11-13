class_name App
extends Node2D

# Root of main.tscn. Owns the screens (city list -> city map -> office view, with a loading screen
# between), all input, and the download jobs: an Overpass fetch, then parsing and baking on a
# worker thread so the window keeps moving, then the save under user:// (see Store).
# Left-drag on the header bar moves the borderless window; on a map, drag pans. Esc goes back,
# and quits from the city list.

# pointer travel (canvas px) before a press counts as a drag rather than a click
const SLOP := 6.0

var screen: Screen

var _net: Overpass
var _job: Dictionary = {}
var _thread: Thread
var _held := false
var _moved := false
var _press_at := Vector2.ZERO
var _window_drag := false
var _grab := Vector2i.ZERO


func _ready() -> void:
	Overpass.read_flags()
	if Overpass.fixture_mode:
		print("App: fixture mode, made-up test data (DATOS DE PRUEBA), no network")
	_net = Overpass.new()
	_net.status.connect(_on_status)
	_net.progress.connect(_on_progress)
	_net.finished.connect(_on_downloaded)
	_net.failed.connect(_on_failed)
	add_child(_net)
	show_cities()


func screen_name() -> String:
	return "" if screen == null else String(screen.get_script().get_global_name())


# --- navigation --------------------------------------------------------------------------------

func _show(next: Screen) -> void:
	if screen != null:
		screen.queue_free()
	screen = next
	screen.app = self
	add_child(screen)
	screen.hover(get_viewport().get_mouse_position())


func show_cities() -> void:
	_show(CityPick.new())


func open_city(city_id: String) -> void:
	var city := CityDb.get_city(city_id)
	if city.is_empty():
		return
	var data: Variant = Store.read_json(Store.city_path(city_id))
	if data is Dictionary and data.get("format") == CityBaker.FORMAT:
		var map := CityMap.new()
		map.setup(city, data)
		_show(map)
		return
	_start_job({"kind": "city", "city": city_id, "title": "Mapa de %s" % city["name"],
		"query": CityBaker.query(city["lat"], city["lon"]),
		"fake": Fixture.city.bind(city)})


func place_office(city_id: String, lat: float, lon: float, place: String) -> void:
	if Rules.too_close(lat, lon):
		return
	_start_job({"kind": "office", "city": city_id, "lat": lat, "lon": lon, "name": place,
		"title": "Nueva oficina en %s" % place,
		"query": BlockBaker.query(lat, lon, Rules.MAX_RADIUS),
		"fake": Fixture.area.bind(lat, lon, Rules.MAX_RADIUS)})


func open_office(meta: Dictionary) -> void:
	var view := OfficeView.new()
	if view.setup(meta):
		_show(view)
	else:
		view.free()


# --- jobs --------------------------------------------------------------------------------------

func _start_job(job: Dictionary) -> void:
	_job = job
	var loading := Loading.new()
	loading.title = job["title"]
	loading.status = "Conectando…"
	_show(loading)
	_net.fetch(job["query"], job["fake"])


func retry_job() -> void:
	if _job.is_empty():
		return
	var loading := screen as Loading
	if loading != null:
		loading.error = ""
		loading.bytes = 0
		loading.status = "Conectando…"
	_net.fetch(_job["query"], _job["fake"])


# leaving the loading screen: drop the download (a bake already running finishes unseen)
func cancel_job() -> void:
	var job := _job
	_job = {}
	_net.cancel()
	if job.get("kind") == "office":
		open_city(job["city"])
	else:
		show_cities()


func _on_status(text: String) -> void:
	var loading := screen as Loading
	if loading != null:
		loading.status = text


func _on_progress(bytes: int) -> void:
	var loading := screen as Loading
	if loading != null:
		loading.bytes = bytes


func _on_failed(reason: String) -> void:
	var loading := screen as Loading
	if loading != null:
		loading.error = reason
	print("App: download failed: " + reason)


func _on_downloaded(body: PackedByteArray, info: Dictionary) -> void:
	if _job.is_empty():
		return
	_job["download"] = info
	_on_status("Preparando el mapa (%s)…" % Ui.size_text(body.size()))
	_on_progress(body.size())
	_thread = Thread.new()
	_thread.start(_bake.bind(_job.duplicate(), body))


# runs on the worker thread: parse and bake, nothing that touches the scene
static func _bake(job: Dictionary, body: PackedByteArray) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var raw: Variant = JSON.parse_string(body.get_string_from_utf8())
	var parse_ms := Time.get_ticks_msec() - t0
	if not raw is Dictionary:
		return {"error": "La respuesta del servidor no se pudo leer."}
	var city := CityDb.get_city(job["city"])
	var data: Dictionary
	if job["kind"] == "city":
		data = CityBaker.bake(raw, city["lat"], city["lon"])
	else:
		data = BlockBaker.bake(raw, job["lat"], job["lon"], Rules.MAX_RADIUS)
	data["stats"]["parse_ms"] = parse_ms
	return {"data": data}


func _process(_delta: float) -> void:
	if _thread != null and not _thread.is_alive():
		var result: Dictionary = _thread.wait_to_finish()
		_thread = null
		if not _job.is_empty():
			_bake_done(result)


func _bake_done(result: Dictionary) -> void:
	var job := _job
	_job = {}
	if result.has("error"):
		_on_failed(result["error"])
		_job = job
		return
	var data: Dictionary = result["data"]
	var info: Dictionary = job["download"]
	var source := "fixture" if info.get("fixture", false) else "osm"
	var stamp := Time.get_datetime_string_from_system(true)
	data["fetched"] = stamp
	data["data_source"] = source
	if job["kind"] == "city":
		var size := Store.write_json(Store.city_path(job["city"]), data)
		print("CITY %s: download %d B in %d ms (%s), parse %d ms, bake %d ms, %d roads, " % [
			job["city"], info["bytes"], info["ms"], info.get("mirror", "?"),
			data["stats"]["parse_ms"], data["stats"]["bake_ms"], data["stats"]["roads"]] \
			+ "%d places, saved %d B" % [data["stats"]["places"], size])
		open_city(job["city"])
		return
	var id := "%s_%d" % [job["city"], int(Time.get_unix_time_from_system() * 1000.0) % 100000000]
	var meta := {
		"id": id, "city": job["city"], "name": job["name"], "lat": job["lat"],
		"lon": job["lon"], "level": 1, "max_radius": Rules.MAX_RADIUS,
		"active_radius": Rules.active_radius(1), "created": stamp, "source": source,
	}
	data["office"] = meta
	var size := Store.write_json(Store.office_path(id), data)
	var st: Dictionary = data["stats"]
	meta["stats"] = {"download_bytes": info["bytes"], "download_ms": info["ms"],
		"mirror": info.get("mirror", ""), "parse_ms": st["parse_ms"], "bake_ms": st["bake_ms"],
		"roads": st["roads"], "blocks": st["blocks"], "plots": st["plots"], "built": st["built"],
		"file_bytes": size}
	Store.add_office(meta)
	print("OFFICE %s (%s): download %d B in %d ms (%s), parse %d ms, bake %d ms, " % [id,
		job["name"], info["bytes"], info["ms"], info.get("mirror", "?"), st["parse_ms"],
		st["bake_ms"]] + "%d roads, %d blocks, %d plots (%d built), saved %d B" % [
		st["roads"], st["blocks"], st["plots"], st["built"], size])
	open_office(meta)


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()


# --- input -------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if screen == null:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not screen.back():
			get_tree().quit()
	elif event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_WHEEL_UP and b.pressed:
			screen.wheel(b.position, 1)
		elif b.button_index == MOUSE_BUTTON_WHEEL_DOWN and b.pressed:
			screen.wheel(b.position, -1)
		elif b.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if b.pressed:
				_held = true
				_moved = false
				_press_at = b.position
				var own := screen.press(b.position)
				# the header bar is the window's handle, except over the screen's buttons
				_window_drag = b.button_index == MOUSE_BUTTON_LEFT and not own \
					and b.position.y < Ui.BAR_H
				_grab = DisplayServer.mouse_get_position() - DisplayServer.window_get_position()
			elif _held:
				_held = false
				if not _moved and not _window_drag and b.button_index == MOUSE_BUTTON_LEFT:
					screen.click(b.position)
				_window_drag = false
	elif event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		if _held and _window_drag:
			DisplayServer.window_set_position(DisplayServer.mouse_get_position() - _grab)
			return
		if _held:
			if not _moved and m.position.distance_to(_press_at) > SLOP:
				_moved = true
				screen.drag(m.position, m.position - _press_at)
			elif _moved:
				screen.drag(m.position, m.relative)
		screen.hover(m.position)
