class_name OfficeView
extends Screen

# One office's saved area in isometric pixel art. The whole disc is drawn once (UPDATE_ONCE) into
# a SubViewport the size of the drawing and shown through a sprite, so panning only moves the
# sprite. Drag to pan, wheel or - + to zoom (each art pixel 1 or 2 screen pixels). Outside the
# active radius everything is dimmed: downloaded already, usable at a higher level.

const ZOOMS: Array[int] = [1, 2]
const VIEW_TOP := Ui.BAR_H
const VIEW_BOTTOM := Ui.CANVAS.y - Ui.FOOT_H
const ZOOM_OUT := Rect2(500, 2, 46, 44)
const ZOOM_IN := Rect2(550, 2, 46, 44)
const LABEL_SIZE := 11
const STREET_INK := Color("#f6f2e6")

var office: Dictionary = {}

var _view: BlockView
var _vp: SubViewport
var _sprite: Sprite2D
var _over: Node2D
var _zoom_i := 1
var _pan := Vector2.ZERO
var _stats: Dictionary = {}
var _street_spots: Array[Dictionary] = []
# zoom step -> labels that fit without overlapping at that zoom
var _labels := {}


# false when the saved file is missing or unreadable
func setup(meta: Dictionary) -> bool:
	office = meta
	var block: Variant = Store.read_json(Store.office_path(meta["id"]))
	if not block is Dictionary:
		push_error("OfficeView: cannot read " + Store.office_path(meta["id"]))
		return false
	_view = BlockView.new()
	_view.active_radius = float(meta.get("active_radius", Rules.active_radius(1)))
	if not _view.set_block(block):
		return false
	_stats = block.get("stats", {})
	_street_spots = _view.street_labels()
	return true


func _ready() -> void:
	_vp = SubViewport.new()
	_vp.disable_3d = true
	_vp.transparent_bg = true
	var limit := 8192
	_vp.size = Vector2i(_view.size).min(Vector2i(limit, limit))
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vp.add_child(_view)
	add_child(_vp)
	_sprite = Sprite2D.new()
	_sprite.centered = false
	_sprite.texture = _vp.get_texture()
	add_child(_sprite)
	_over = Node2D.new()
	_over.draw.connect(_draw_over)
	add_child(_over)
	_set_zoom(_zoom_i)


func _zoom() -> float:
	return float(ZOOMS[_zoom_i])


# puts ground point (0, 0), the office, in the middle of the view
func center() -> void:
	var mid := Vector2(300, (VIEW_TOP + VIEW_BOTTOM) * 0.5 + 30)
	_pan_to(mid - _view.focus * _zoom())


func set_zoom_step(i: int) -> void:
	_set_zoom(i)


func _set_zoom(i: int) -> void:
	_zoom_i = clampi(i, 0, ZOOMS.size() - 1)
	_sprite.scale = Vector2.ONE * _zoom()
	center()


# also used by tools/cloud/capture.gd to frame its shots
func pan_by(rel: Vector2) -> void:
	_pan_to(_pan + rel)


func _pan_to(at: Vector2) -> void:
	var size := _view.size * _zoom()
	var view := Rect2(0, VIEW_TOP, Ui.CANVAS.x, VIEW_BOTTOM - VIEW_TOP)
	_pan = at.clamp(view.position + view.size * 0.6 - size, view.position + view.size * 0.4)
	_pan = (_pan / _zoom()).round() * _zoom()
	_sprite.position = _pan
	_over.queue_redraw()


func press(at: Vector2) -> bool:
	return Ui.BACK_RECT.has_point(at) or ZOOM_IN.has_point(at) or ZOOM_OUT.has_point(at)


func click(at: Vector2) -> void:
	if Ui.BACK_RECT.has_point(at):
		back()
	elif ZOOM_IN.has_point(at):
		_set_zoom(_zoom_i + 1)
	elif ZOOM_OUT.has_point(at):
		_set_zoom(_zoom_i - 1)


func drag(_at: Vector2, rel: Vector2) -> void:
	pan_by(rel)


func hover(at: Vector2) -> void:
	hot = at
	_over.queue_redraw()


func wheel(_at: Vector2, steps: int) -> void:
	_set_zoom(_zoom_i + steps)


func back() -> bool:
	app.open_city(office["city"])
	return true


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color("#16131d"))


# street names placed greedily, longest stretch first, so none overlap at this zoom
func _labels_for(i: int) -> Array:
	if _labels.has(i):
		return _labels[i]
	var z := float(ZOOMS[i])
	var spots := _street_spots.duplicate()
	spots.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["room"] > b["room"])
	var placed: Array[Rect2] = []
	var out: Array = []
	for s: Dictionary in spots:
		var w := Ui.text_width(s["text"], LABEL_SIZE)
		# a street label must fit along its stretch of street
		if w > float(s["room"]) * z * 0.95:
			continue
		var at: Vector2 = s["at"] * z
		var half := Vector2(cos(s["angle"]), sin(s["angle"])).abs() * w * 0.5 + Vector2(6, 9)
		var box := Rect2(at - half, half * 2.0)
		var free := true
		for q in placed:
			if q.intersects(box):
				free = false
				break
		if free:
			placed.append(box)
			out.append({"at": at, "angle": s["angle"], "text": s["text"], "w": w})
	_labels[i] = out
	return out


func _draw_over() -> void:
	var view := Rect2(0, VIEW_TOP + 24, Ui.CANVAS.x, VIEW_BOTTOM - VIEW_TOP - 24)
	for l: Dictionary in _labels_for(_zoom_i):
		var at: Vector2 = _pan + l["at"]
		if not view.grow(-8).has_point(at):
			continue
		_over.draw_set_transform(at.round(), l["angle"])
		Ui.label(_over, Vector2(-l["w"] * 0.5, 4).round(), l["text"], LABEL_SIZE, STREET_INK)
		_over.draw_set_transform(Vector2.ZERO, 0.0)
	var level: int = office.get("level", 1)
	var info := "Nivel %d · radio activo %d m de %d m · %s parcelas, %s libres" % [level,
		roundi(_view.active_radius), roundi(float(office.get("max_radius", Rules.MAX_RADIUS))),
		Ui.count(int(_stats.get("plots", 0))),
		Ui.count(int(_stats.get("plots", 0)) - int(_stats.get("built", 0)))]
	var bar := Rect2(0, VIEW_TOP + 1, Ui.CANVAS.x, 24)
	_over.draw_rect(bar, Ui.SHADE)
	Ui.text(_over, Vector2(10, VIEW_TOP + 18), info, Ui.SMALL, Ui.INK)
	var city := CityDb.get_city(office["city"])
	Ui.header(_over, "%s · %s" % [office.get("name", "Oficina"), city.get("name", "")], true, hot)
	Ui.button(_over, ZOOM_OUT, "-", hot, false, _zoom_i == 0)
	Ui.button(_over, ZOOM_IN, "+", hot, false, _zoom_i == ZOOMS.size() - 1)
	Ui.footer(_over, "descargado el %s" % String(office.get("created", "")).left(10))
