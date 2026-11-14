class_name App
extends Node2D

# Root of main.tscn. Owns the screens (world map -> city map -> office view, with a loading
# screen between; the plain city list hangs off the world map), all input, and the download
# jobs: an Overpass fetch, then parsing and baking on a worker thread so the window keeps moving,
# then the save under user:// (see Store). Left-drag on the header bar moves the borderless
# window; on a map, drag pans. Esc goes back (office -> its city's map -> the world map, centred
# on that city), and quits from the world map. It also keeps the player's Game: loaded at start
# (the time away is paid then), advanced a few times a second whatever the screen, saved every
# SAVE_EVERY seconds, after every change and on quit; the game opens straight into the last
# office seen.

# pointer travel (canvas px) before a press counts as a drag rather than a click
const SLOP := 6.0
const TICK := 0.25
const SAVE_EVERY := 30.0

# when the window last got the focus (engine ms): the click that brings it up is not a purchase
static var focus_ms := -100000

var screen: Screen
var game: Game

var _net: Overpass
var _job: Dictionary = {}
var _thread: Thread
var _held := false
var _moved := false
var _press_at := Vector2.ZERO
var _window_drag := false
var _grab := Vector2i.ZERO
var _tick := 0.0
var _save_t := 0.0


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
	game = Game.new(Game.save_path())
	game.load_or_new()
	if not game.away.is_empty():
		print("App: away %d s, paid %d s, +%s" % [int(game.away["seconds"]),
			int(game.away["paid_s"]), Economy.money(float(game.away["money"]))])
	get_tree().set_auto_accept_quit(false)
	# an office whose area file is gone cannot be played or seen: the game forgets it
	var kept := {}
	for o in Store.offices():
		kept[o["id"]] = true
	for id: String in game.offices().keys():
		if not kept.has(id):
			game.offices().erase(id)
	var last: String = game.state.get("last_office", "")
	for o in Store.offices():
		if o["id"] == last:
			open_office(o)
			return
	show_world()


# --- navigation --------------------------------------------------------------------------------

func _show(next: Screen) -> void:
	if screen != null:
		screen.queue_free()
	screen = next
	screen.app = self
	add_child(screen)
	screen.hover(get_viewport().get_mouse_position())


# the world map; `focus` (a city id) centres it on the city the player comes back from
func show_world(focus: String = "") -> void:
	var world := WorldMap.new()
	_show(world)
	if focus != "":
		world.focus(focus)
		world.hover(get_viewport().get_mouse_position())


func show_cities() -> void:
	_show(CityPick.new())


func open_city(city_id: String) -> void:
	var city := CityDb.get_city(city_id)
	if city.is_empty():
		return
	var data: Variant = Store.read_json(Store.city_path(city_id))
	# a city map made of test data is never shown as the real one, nor the other way round
	if data is Dictionary and data.get("format") == CityBaker.FORMAT \
			and (data.get("data_source") == "fixture") == Overpass.fixture_mode:
		var map := CityMap.new()
		map.setup(city, data)
		_show(map)
		return
	_start_job({"kind": "city", "city": city_id, "title": "Mapa de %s" % city["name"],
		"query": CityBaker.query(city["lat"], city["lon"]),
		"fake": Fixture.city.bind(city)})


func place_office(city_id: String, lat: float, lon: float, place: String) -> void:
	if Rules.too_close(lat, lon) or game.can_open_office() != "" or not _job.is_empty():
		return
	# paid when placed (the first is free), given back if the download is abandoned
	var paid := game.pay_office()
	game.save()
	_start_job({"kind": "office", "city": city_id, "lat": lat, "lon": lon, "name": place,
		"paid": paid,
		"title": "Nueva oficina en %s" % place,
		"query": BlockBaker.query(lat, lon, Rules.MAX_RADIUS),
		"fake": Fixture.area.bind(lat, lon, Rules.MAX_RADIUS)})


func open_office(meta: Dictionary) -> void:
	var view := OfficeView.new()
	view.game = game
	if view.setup(meta):
		game.save()
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
		if float(job.get("paid", 0.0)) > 0.0:
			game.state["money"] = game.money() + float(job["paid"])
			game.save()
		open_city(job["city"])
	else:
		show_world(job.get("city", ""))


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


func _process(delta: float) -> void:
	_tick += delta
	_save_t += delta
	if _tick >= TICK:
		_tick = 0.0
		_advance()
	if _save_t >= SAVE_EVERY:
		_save_t = 0.0
		game.save()
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
	game.add_office(id, data.get("office_plot", ""))
	game.save()
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


func tick_game() -> void:
	_advance()


# pays the time since the last tick and tells the office on screen what finished or started
func _advance() -> void:
	var done := game.advance(game.now())
	var view := screen as OfficeView
	for d in done:
		if view != null and view.office.get("id") == d["office"]:
			view.on_built(d["lot"], int(d["tier"]))
	for s: Dictionary in game.auto_started:
		if view != null and view.office.get("id") == s["office"]:
			view.on_started(s["lot"])
	game.auto_started.clear()
	if not done.is_empty():
		game.save()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if game != null:
			game.advance(game.now())
			game.save()
		get_tree().quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN or what == NOTIFICATION_WM_WINDOW_FOCUS_IN:
		focus_ms = Time.get_ticks_msec()
	elif what == NOTIFICATION_WM_MOUSE_EXIT and screen != null:
		# a widget left alone: no hover tints, no pops
		screen.hover(Vector2(-100, -100))


func _exit_tree() -> void:
	if game != null:
		game.save()
	if _thread != null:
		_thread.wait_to_finish()


# --- input -------------------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if screen == null:
		return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not screen.back():
			game.save()
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
