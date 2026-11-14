class_name CityMap
extends Screen

# A city's map, top-down: main roads, sea, rivers, big parks and neighbourhood names, downloaded
# once. Drag to pan, wheel or the - + buttons to zoom (three steps). The pointer carries the
# circle a new office would download; it turns red where it would be closer than
# Rules.MIN_SEPARATION to another office. Click to pick a spot, then confirm to place the office.
# Existing offices show as gold markers with their circle; clicking one opens it.

const ZOOMS: Array[int] = [1, 2, 4]
const MAP_TOP := Ui.BAR_H
const MAP_BOTTOM := Ui.CANVAS.y - Ui.FOOT_H
const ZOOM_OUT := Rect2(476, 14, 52, 52)
const ZOOM_IN := Rect2(536, 14, 52, 52)
const BOX := Rect2(12, 404, 576, 164)
const CANCEL := Rect2(28, 494, 196, 56)
const OPEN := Rect2(236, 494, 336, 56)
const MARKER_HIT := 24.0
const OK_TONE := Ui.CREAM
const HOUSE: Array[String] = [".....11.....", "....1111....", "...111111...", "..11111111..",
	".1111111111.", "111111111111", ".1111111111.", ".111111..11.", ".111111..11.",
	".111111..11.", ".111111..11."]

var city: Dictionary = {}

var _data: Dictionary = {}
var _paint: CityPaint
var _vp: SubViewport
var _sprite: Sprite2D
var _over: Node2D
var _zoom_i := 0
var _pan := Vector2.ZERO
var _labels := {}
var _cursor := Vector2.INF
var _pending := Vector2.INF
var _note := ""
var _note_t := 0.0
var _k := Vector2.ONE


func setup(the_city: Dictionary, data: Dictionary) -> void:
	city = the_city
	_data = data
	_k = Geo.scale_at(city["lat"])


func _ready() -> void:
	_paint = CityPaint.new()
	_paint.set_city(_data)
	_vp = SubViewport.new()
	_vp.disable_3d = true
	_vp.size = Vector2i(_paint.size)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vp.add_child(_paint)
	add_child(_vp)
	_sprite = Sprite2D.new()
	_sprite.centered = false
	_sprite.texture = _vp.get_texture()
	add_child(_sprite)
	_over = Node2D.new()
	_over.draw.connect(_draw_over)
	add_child(_over)
	_set_zoom(0, Vector2(300, (MAP_TOP + MAP_BOTTOM) * 0.5))
	center_on(city["lat"], city["lon"])


func _process(delta: float) -> void:
	if _note_t > 0.0:
		_note_t -= delta
		if _note_t <= 0.0:
			_note = ""
			_over.queue_redraw()


# --- coordinates -------------------------------------------------------------------------------

func _zoom() -> float:
	return float(ZOOMS[_zoom_i])


func _screen(m: Vector2) -> Vector2:
	return _pan + _paint.to_px(m) * _zoom()


func _metres(at: Vector2) -> Vector2:
	return _paint.to_m((at - _pan) / _zoom())


func _latlon(m: Vector2) -> Vector2:
	return Geo.to_latlon(m, city["lat"], city["lon"], _k)


func _local(lat: float, lon: float) -> Vector2:
	return Geo.to_local(lat, lon, city["lat"], city["lon"], _k)


func _on_map(at: Vector2) -> bool:
	if at.y < MAP_TOP or at.y > MAP_BOTTOM:
		return false
	if _pending != Vector2.INF and BOX.has_point(at):
		return false
	var m := _metres(at)
	var half: float = _data["half_m"]
	return absf(m.x) <= half and absf(m.y) <= half


# --- driving it (also used by tools/cloud/capture.gd) -------------------------------------------

func center_on(lat: float, lon: float) -> void:
	var mid := Vector2(300, (MAP_TOP + MAP_BOTTOM) * 0.5)
	_pan_to(mid - _paint.to_px(_local(lat, lon)) * _zoom())


func set_zoom_step(i: int) -> void:
	_set_zoom(i, Vector2(300, (MAP_TOP + MAP_BOTTOM) * 0.5))


func hover_latlon(lat: float, lon: float) -> void:
	hover(_screen(_local(lat, lon)))


func pick_latlon(lat: float, lon: float) -> void:
	click(_screen(_local(lat, lon)))


func confirm() -> void:
	if _pending != Vector2.INF and app.game.can_open_office() == "":
		var ll := _latlon(_pending)
		app.place_office(city["id"], ll.x, ll.y, place_name(_pending))


# the name of the nearest neighbourhood within 1.5 km, else the city's
func place_name(m: Vector2) -> String:
	var best: String = city["name"]
	var best_d := 1500.0
	for p: Dictionary in _data["places"]:
		var d := m.distance_to(Vector2(p["x"], p["y"]))
		if d < best_d:
			best_d = d
			best = p["name"]
	return best


# --- input -------------------------------------------------------------------------------------

func press(at: Vector2) -> bool:
	return Ui.BACK_RECT.has_point(at) or ZOOM_IN.has_point(at) or ZOOM_OUT.has_point(at) \
		or (_pending != Vector2.INF and BOX.has_point(at))


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		back()
		return
	if ZOOM_IN.has_point(at):
		_set_zoom(_zoom_i + 1, Vector2(300, (MAP_TOP + MAP_BOTTOM) * 0.5))
		return
	if ZOOM_OUT.has_point(at):
		_set_zoom(_zoom_i - 1, Vector2(300, (MAP_TOP + MAP_BOTTOM) * 0.5))
		return
	if _pending != Vector2.INF and BOX.has_point(at):
		if CANCEL.has_point(at):
			_pending = Vector2.INF
		elif OPEN.has_point(at):
			confirm()
			return
		_over.queue_redraw()
		return
	if not _on_map(at):
		return
	for o in Store.offices_in(city["id"]):
		if _screen(_local(o["lat"], o["lon"])).distance_to(at) < MARKER_HIT:
			app.open_office(o)
			return
	var m := _metres(at)
	var ll := _latlon(m)
	if Rules.too_close(ll.x, ll.y):
		_say("Demasiado cerca de otra oficina: deja al menos %s." % _km(Rules.MIN_SEPARATION))
		_pending = Vector2.INF
	else:
		_pending = m
	_over.queue_redraw()


func drag(_at: Vector2, rel: Vector2) -> void:
	_pan_to(_pan + rel)


func hover(at: Vector2) -> void:
	hot = at
	_cursor = _metres(at) if _on_map(at) else Vector2.INF
	_over.queue_redraw()


func wheel(at: Vector2, steps: int) -> void:
	_set_zoom(_zoom_i + steps, at)


func back() -> bool:
	app.show_cities()
	return true


func _set_zoom(i: int, around: Vector2) -> void:
	i = clampi(i, 0, ZOOMS.size() - 1)
	var before := _zoom()
	_zoom_i = i
	_sprite.scale = Vector2.ONE * _zoom()
	_pan_to(around - (around - _pan) * (_zoom() / before))


# keeps at least a third of the map area covered, so the map cannot be lost off-screen
func _pan_to(at: Vector2) -> void:
	var size := _paint.size * _zoom()
	var view := Rect2(0, MAP_TOP, Ui.CANVAS.x, MAP_BOTTOM - MAP_TOP)
	var lo := view.position + view.size * 0.66 - size
	var hi := view.position + view.size * 0.34
	_pan = at.clamp(lo, hi).round()
	_sprite.position = _pan
	if _cursor != Vector2.INF:
		_cursor = _metres(hot) if _on_map(hot) else Vector2.INF
	_over.queue_redraw()


func _say(text: String) -> void:
	_note = text
	_note_t = 3.0
	_over.queue_redraw()


# --- drawing -----------------------------------------------------------------------------------

func _draw() -> void:
	Ui.backdrop(self)


func _draw_over() -> void:
	var z := _zoom()
	var r := Rules.MAX_RADIUS / CityPaint.M_PER_PX * z
	for l: Dictionary in _labels_for(_zoom_i):
		var at: Vector2 = _pan + l["at"]
		if at.y > MAP_TOP + 4 and at.y < MAP_BOTTOM:
			Ui.text(_over, at, l["text"], l["size"], l["color"], l["kind"], false)
	for o in Store.offices_in(city["id"]):
		var s := _screen(_local(o["lat"], o["lon"]))
		_ring(s, r, Ui.GOLD, true)
		_marker(s, Ui.GOLD, Ui.GOLD_M)
		var name: String = o.get("name", "")
		Ui.text(_over, s + Vector2(-Ui.text_width(name, Ui.TEXT, Ui.NARROW) * 0.5, 34), name,
			Ui.TEXT, Ui.GOLD, Ui.NARROW)
	if _pending != Vector2.INF:
		var s := _screen(_pending)
		_ring(s, r, OK_TONE, false)
		_marker(s, OK_TONE, Ui.MUTED)
	elif _cursor != Vector2.INF:
		var ll := _latlon(_cursor)
		var bad := Rules.too_close(ll.x, ll.y)
		var tone := Ui.BLOOD if bad else OK_TONE
		var s := (_screen(_cursor) / 2.0).round() * 2.0
		_ring(s, r, tone, false)
		for pass_i in 2:
			for k in range(-8, 10, 2):
				for q: Vector2 in [s + Vector2(k, 0), s + Vector2(0, k)]:
					if pass_i == 0:
						_over.draw_rect(Rect2(q - Vector2(2, 2), Vector2(6, 6)), Ui.VOID)
					else:
						_over.draw_rect(Rect2(q, Vector2(2, 2)), tone)
		if bad:
			var near := Rules.nearest_office(ll.x, ll.y)
			var o: Dictionary = near["office"]
			# the circle the other office keeps clear, so the player sees where they may go
			var os := _screen(_local(o["lat"], o["lon"]))
			_ring(os, Rules.MIN_SEPARATION / CityPaint.M_PER_PX * z, Ui.BLOOD, true)
			var msg := "Muy cerca de otra oficina (%s)" % _km(near["distance"])
			Ui.text(_over, s + Vector2(-Ui.text_width(msg, Ui.TEXT, Ui.NARROW) * 0.5, -r - 10),
				msg, Ui.TEXT, Ui.BLOOD, Ui.NARROW)
	if _pending != Vector2.INF:
		_draw_confirm()
	if _note != "":
		var w := Ui.text_width(_note, Ui.TEXT, Ui.NARROW) + 28
		var box := Rect2(roundf(300 - w * 0.5), MAP_TOP + 10, roundf(w), 36)
		Ui.chip(_over, box, Ui.VOID, Ui.BLOOD)
		Ui.text_in(_over, box, _note, Ui.TEXT, Ui.BLOOD, Ui.NARROW)
	Ui.header(_over, city["name"], true, hot)
	Ui.arrow(_over, ZOOM_OUT, "-", hot, _zoom_i == 0)
	Ui.arrow(_over, ZOOM_IN, "+", hot, _zoom_i == ZOOMS.size() - 1)
	Ui.footer(_over, "zoom x%d" % ZOOMS[_zoom_i])


func _draw_confirm() -> void:
	Ui.panel(_over, BOX, Ui.GOLD)
	var name := place_name(_pending)
	Ui.text(_over, BOX.position + Vector2(20, 42), "¿Abrir una oficina en %s?" % name, Ui.TEXT,
		Ui.CREAM, Ui.NARROW)
	var why := app.game.can_open_office()
	var cost := app.game.next_office_cost()
	var line := "Se descarga una vez lo que hay a %d m" % roundi(Rules.MAX_RADIUS)
	if why != "":
		line = why
	elif cost > 0.0:
		line = "Cuesta %s · se descarga lo que hay a %d m" % [Economy.money(cost),
			roundi(Rules.MAX_RADIUS)]
	Ui.text(_over, BOX.position + Vector2(20, 72), line, Ui.SMALL,
		Ui.BLOOD if why != "" else Ui.MUTED, Ui.TEN)
	Ui.button(_over, CANCEL, "Cancelar", hot)
	Ui.button(_over, OPEN, "Abrir oficina", hot, why == "", why != "")


# a pixel circle on the 2x grid; dashed for offices, solid for the cursor
func _ring(at: Vector2, r: float, tone: Color, dashed: bool) -> void:
	var steps := maxi(24, ceili(TAU * r / 2.0))
	var seen := {}
	for k in steps:
		if dashed and (k / 4) % 3 == 2:
			continue
		var a := TAU * k / steps
		var q := ((at + Vector2(cos(a), sin(a)) * r) / 2.0).round() * 2.0
		if seen.has(q):
			continue
		seen[q] = true
		_over.draw_rect(Rect2(q - Vector2(1, 1), Vector2(4, 4)), Ui.VOID)
	for q: Vector2 in seen:
		_over.draw_rect(Rect2(q, Vector2(2, 2)), tone)


# the mockup's little house icon on the spot, outlined in ink
func _marker(s: Vector2, tone: Color, dark: Color) -> void:
	var at := ((s - Vector2(12, 24)) / 2.0).round() * 2.0
	for j in HOUSE.size():
		for i in HOUSE[j].length():
			if HOUSE[j][i] == "1":
				_over.draw_rect(Rect2(at + Vector2(i, j) * 2.0 - Vector2(2, 2), Vector2(6, 6)),
					Ui.VOID)
	for j in HOUSE.size():
		for i in HOUSE[j].length():
			if HOUSE[j][i] == "1":
				_over.draw_rect(Rect2(at + Vector2(i, j) * 2.0, Vector2(2, 2)),
					dark if j >= 6 and i >= 6 else tone)


# neighbourhood names placed greedily by importance so none overlap; worked out once per zoom,
# in map pixels at that zoom, so panning only shifts them
func _labels_for(i: int) -> Array:
	if _labels.has(i):
		return _labels[i]
	var z := float(ZOOMS[i])
	var placed: Array[Rect2] = []
	var out: Array = []
	for p: Dictionary in _data["places"]:
		var rank: int = p["rank"]
		if i == 0 and rank > 2:
			continue
		var big := rank <= 1
		var size := Ui.TEXT if big else Ui.SMALL
		var kind := Ui.NARROW if big else Ui.TEN
		var text: String = p["name"]
		var w := Ui.text_width(text, size, kind)
		var at := _paint.to_px(Vector2(p["x"], p["y"])) * z
		var box := Rect2(at.x - w * 0.5 - 6, at.y - size - 4, w + 12, size + 12)
		var free := true
		for q in placed:
			if q.intersects(box):
				free = false
				break
		if free:
			placed.append(box)
			out.append({"at": Vector2(at.x - w * 0.5, at.y).round(), "text": text, "size": size,
				"kind": kind, "color": Ui.CREAM if big else Ui.MUTED.lightened(0.3)})
	_labels[i] = out
	return out


static func _km(m: float) -> String:
	if m < 1000.0:
		return "%d m" % roundi(m)
	return ("%.1f km" % (m / 1000.0)).replace(".", ",")
