class_name Screen
extends Node2D

# Base for every full-window screen. App owns the input and hands each screen plain calls with
# canvas positions: press (button down), click (released without moving), drag (moved while held,
# either button), hover, wheel. A screen redraws itself; `hot` is the pointer, for hover tints.

var app: App
var hot := Vector2(-100, -100)


# true when the press landed on something of the screen's own (a button), so App does not start
# a window drag from the header there
func press(_at: Vector2) -> bool:
	return false


func click(_at: Vector2) -> void:
	pass


func drag(_at: Vector2, _rel: Vector2) -> void:
	pass


func hover(at: Vector2) -> void:
	hot = at
	queue_redraw()


func wheel(_at: Vector2, _steps: int) -> void:
	pass


# Esc or the back button; App quits when the first screen says there is nowhere to go back to
func back() -> bool:
	return false
