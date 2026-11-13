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
const ZOOM_OUT := Rect2(500, 2, 46, 44)
const ZOOM_IN := Rect2(550, 2, 46, 44)
const BOX := Rect2(10, 448, 580, 122)
const CANCEL := Rect2(26, 510, 170, 48)
const OPEN := Rect2(330, 510, 244, 48)
const MARKER_HIT := 20.0
const LABEL_BIG := 14
const LABEL_SMALL := 12
const OK_TONE := Color("#f4f1ea")

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
	if _pending != Vector2.INF:
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
	draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color("#16131d"))


func _draw_over() -> void:
	var z := _zoom()
	var r := Rules.MAX_RADIUS / CityPaint.M_PER_PX * z
	for l: Dictionary in _labels_for(_zoom_i):
		var at: Vector2 = _pan + l["at"]
		if at.y > MAP_TOP + 4 and at.y < MAP_BOTTOM:
			Ui.label(_over, at, l["text"], l["size"], l["color"])
	for o in Store.offices_in(city["id"]):
		var s := _screen(_local(o["lat"], o["lon"]))
		_over.draw_circle(s, r, Color(Ui.GOLD, 0.16))
		_over.draw_arc(s, r, 0.0, TAU, 64, Ui.GOLD, 2.0)
		_marker(s, Ui.GOLD)
		var name: String = o.get("name", "")
		Ui.label(_over, s + Vector2(-Ui.text_width(name, Ui.SMALL) * 0.5, 26), name, Ui.SMALL,
			Ui.GOLD)
	if _pending != Vector2.INF:
		var s := _screen(_pending)
		_over.draw_circle(s, r, Color(OK_TONE, 0.2))
		_over.draw_arc(s, r, 0.0, TAU, 64, OK_TONE, 2.0)
		_marker(s, OK_TONE)
	elif _cursor != Vector2.INF:
		var ll := _latlon(_cursor)
		var bad := Rules.too_close(ll.x, ll.y)
		var tone := Ui.RED if bad else OK_TONE
		var s := _screen(_cursor)
		_over.draw_circle(s, r, Color(tone, 0.14))
		_over.draw_arc(s, r, 0.0, TAU, 64, tone, 2.0)
		_over.draw_line(s - Vector2(6, 0), s + Vector2(6, 0), tone, 2.0)
		_over.draw_line(s - Vector2(0, 6), s + Vector2(0, 6), tone, 2.0)
		if bad:
			var near := Rules.nearest_office(ll.x, ll.y)
			var o: Dictionary = near["office"]
			# the circle the other office keeps clear, so the player sees where they may go
			var os := _screen(_local(o["lat"], o["lon"]))
			_over.draw_arc(os, Rules.MIN_SEPARATION / CityPaint.M_PER_PX * z, 0.0, TAU, 96,
				Color(Ui.RED, 0.8), 1.0)
			var msg := "Muy cerca de otra oficina (%s)" % _km(near["distance"])
			Ui.label(_over, s + Vector2(-Ui.text_width(msg, Ui.SMALL) * 0.5, -r - 8), msg,
				Ui.SMALL, Ui.RED.lightened(0.3))
	if _pending != Vector2.INF:
		_draw_confirm()
	if _note != "":
		var w := Ui.text_width(_note, Ui.FONT_SIZE) + 24
		var box := Rect2(300 - w * 0.5, MAP_TOP + 34, w, 30)
		_over.draw_rect(box, Ui.SHADE)
		Ui.text_in(_over, box, _note, Ui.FONT_SIZE, Ui.RED.lightened(0.35))
	Ui.header(_over, city["name"], true, hot)
	Ui.button(_over, ZOOM_OUT, "-", hot, false, _zoom_i == 0)
	Ui.button(_over, ZOOM_IN, "+", hot, false, _zoom_i == ZOOMS.size() - 1)
	Ui.footer(_over, "zoom x%d" % ZOOMS[_zoom_i])


func _draw_confirm() -> void:
	_over.draw_rect(BOX, Ui.SHADE)
	_over.draw_rect(BOX, Ui.GOLD, false, 2.0)
	var name := place_name(_pending)
	Ui.text(_over, BOX.position + Vector2(16, 28), "¿Abrir una oficina en %s?" % name, 17,
		Ui.INK)
	Ui.text(_over, BOX.position + Vector2(16, 50),
		"Se descarga una sola vez todo lo que hay a %d m a la redonda." % roundi(Rules.MAX_RADIUS),
		Ui.SMALL, Ui.DIM)
	Ui.button(_over, CANCEL, "Cancelar", hot)
	Ui.button(_over, OPEN, "Abrir oficina aquí", hot, true)


# a little gold house on a pin
func _marker(s: Vector2, tone: Color) -> void:
	var base := s.round()
	_over.draw_rect(Rect2(base + Vector2(-7, -8), Vector2(14, 10)), tone)
	_over.draw_colored_polygon(PackedVector2Array([base + Vector2(-10, -8), base + Vector2(0, -17),
		base + Vector2(10, -8)]), tone)
	_over.draw_rect(Rect2(base + Vector2(-2, -4), Vector2(4, 6)), Ui.BAR)
	_over.draw_rect(Rect2(base + Vector2(-7, -8), Vector2(14, 10)), Ui.BAR, false, 1.0)


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
		var size := LABEL_BIG if rank <= 1 else LABEL_SMALL
		var text: String = p["name"]
		var w := Ui.text_width(text, size)
		var at := _paint.to_px(Vector2(p["x"], p["y"])) * z
		var box := Rect2(at.x - w * 0.5 - 4, at.y - size - 2, w + 8, size + 8)
		var free := true
		for q in placed:
			if q.intersects(box):
				free = false
				break
		if free:
			placed.append(box)
			out.append({"at": Vector2(at.x - w * 0.5, at.y).round(), "text": text, "size": size,
				"color": Color.WHITE if rank <= 1 else Color("#ece6d2")})
	_labels[i] = out
	return out


static func _km(m: float) -> String:
	if m < 1000.0:
		return "%d m" % roundi(m)
	return ("%.1f km" % (m / 1000.0)).replace(".", ",")
