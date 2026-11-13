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

var office: Dictionary = {}

var _view: BlockView
var _vp: SubViewport
var _sprite: Sprite2D
var _over: Node2D
var _zoom_i := 1
var _pan := Vector2.ZERO
var _stats: Dictionary = {}


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


func _draw_over() -> void:
	var level: int = office.get("level", 1)
	var info := "Nivel %d · radio activo %d m de %d m · %s edificios" % [level,
		roundi(_view.active_radius), roundi(float(office.get("max_radius", Rules.MAX_RADIUS))),
		Ui.count(int(_stats.get("buildings", 0)))]
	var bar := Rect2(0, VIEW_TOP + 1, Ui.CANVAS.x, 24)
	_over.draw_rect(bar, Ui.SHADE)
	Ui.text(_over, Vector2(10, VIEW_TOP + 18), info, Ui.SMALL, Ui.INK)
	var city := CityDb.get_city(office["city"])
	Ui.header(_over, "%s · %s" % [office.get("name", "Oficina"), city.get("name", "")], true, hot)
	Ui.button(_over, ZOOM_OUT, "-", hot, false, _zoom_i == 0)
	Ui.button(_over, ZOOM_IN, "+", hot, false, _zoom_i == ZOOMS.size() - 1)
	Ui.footer(_over, "descargado el %s" % String(office.get("created", "")).left(10))
