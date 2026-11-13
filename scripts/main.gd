extends Node2D

# Root of main.tscn. For now it only proves the data -> isometric pipeline: it draws the sample
# block once into a low-res SubViewport and shows it x2 with nearest filtering. Right-drag pans,
# left-drag moves the borderless window, Esc quits. No gameplay yet.

const DATA := "res://data/sample_block.json"
# every art pixel becomes a PIXEL x PIXEL block on screen, which is what keeps the look crisp
const PIXEL := 2
const CANVAS := Vector2(600, 600)
const BAR_H := 26.0
const FONT_SIZE := 13
const BAR := Color("#201c28")
const GOLD := Color("#ffd84a")
const INK := Color("#dcdce6")
const DIM := Color("#9a98a8")
# OSM's licence (ODbL) asks for this line to be visible wherever its data is shown
const CREDIT := "© OpenStreetMap contributors"

var _view: BlockView
var _vp: SubViewport
var _sprite: Sprite2D
var _hud: Node2D
# low-res pixels: where the drawing's top-left corner sits on the half-size canvas
var _pan := Vector2.ZERO
var _panning := false
var _dragging := false
var _grab := Vector2i.ZERO


func _ready() -> void:
	_view = BlockView.new()
	if not _view.load_block(DATA):
		return
	# drawn once (UPDATE_ONCE) into a texture the size of the whole block, so panning only moves
	# a sprite and never re-runs the thousands of draw calls
	_vp = SubViewport.new()
	_vp.disable_3d = true
	_vp.transparent_bg = true
	_vp.size = Vector2i(_view.size)
	_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	_vp.add_child(_view)
	add_child(_vp)
	_sprite = Sprite2D.new()
	_sprite.centered = false
	_sprite.texture = _vp.get_texture()
	_sprite.scale = Vector2(PIXEL, PIXEL)
	add_child(_sprite)
	_hud = Node2D.new()
	_hud.draw.connect(_draw_hud)
	add_child(_hud)
	pan_to(CANVAS / PIXEL * 0.5 - _view.focus)


# also used by tools/cloud/capture.gd to frame its shots
func pan_to(at: Vector2) -> void:
	# keep at least a quarter of the canvas covered by the block, so it cannot be lost off-screen
	var low := CANVAS / PIXEL
	_pan = at.clamp(low * 0.25 - _view.size, low * 0.75)
	_sprite.position = _pan.round() * PIXEL


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().quit()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_RIGHT:
			_panning = button.pressed
		elif button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
			# screen coordinates, because the window moves under the pointer while dragging
			_grab = DisplayServer.mouse_get_position() - DisplayServer.window_get_position()
	elif event is InputEventMouseMotion and _view != null:
		var motion := event as InputEventMouseMotion
		if _panning:
			pan_to(_pan + motion.relative / PIXEL)
		elif _dragging:
			DisplayServer.window_set_position(DisplayServer.mouse_get_position() - _grab)


func _draw_hud() -> void:
	var font := ThemeDB.fallback_font
	_hud.draw_rect(Rect2(0, 0, CANVAS.x, BAR_H), BAR)
	_hud.draw_line(Vector2(0, BAR_H), Vector2(CANVAS.x, BAR_H), GOLD)
	_hud.draw_string(font, Vector2(10, 18), "Tiny Realtor", HORIZONTAL_ALIGNMENT_LEFT, -1,
		FONT_SIZE, GOLD)
	_hud.draw_string(font, Vector2(0, 18), "Eixample (muestra)", HORIZONTAL_ALIGNMENT_RIGHT,
		CANVAS.x - 10, FONT_SIZE, INK)
	# the sample block is hand-made, but the credit's place on screen is reserved from day one
	_hud.draw_rect(Rect2(0, CANVAS.y - 20, CANVAS.x, 20), Color(BAR, 0.85))
	_hud.draw_string(font, Vector2(8, CANVAS.y - 6), "datos de muestra · mapas reales: " + CREDIT,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, DIM)
