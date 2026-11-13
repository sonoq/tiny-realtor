extends SceneTree

# Boots the real game (res://main.tscn) and saves viewport PNGs: the opening view, the view panned
# to another corner of the block, and the whole low-res block texture blown up x2. It needs a real
# display (run it under xvfb-run, see tools/cloud/screenshot.sh), because a headless run renders
# nothing a viewport could hand back.
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/capture.gd -- --out=/abs/dir

const DEFAULT_OUT := "user://screenshots"
# low-res pixels to slide the view for the panned shot, as a right-drag would
const PAN := Vector2(120.0, -70.0)

var _out: String = DEFAULT_OUT
var _game: Node2D
var _shots: int = 0


func _init() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)

	_game = load("res://main.tscn").instantiate()
	root.add_child(_game)
	# the block texture renders once on the first frames; give it a few before the first shot
	for _i in 10:
		await process_frame
	var vp: SubViewport = _game._vp
	if vp == null:
		_fail("the block did not load, no SubViewport")
		return
	await _shot("01_block", root, 1)
	_game.pan_to(_game._pan + PAN)
	await _shot("02_block_panned", root, 1)
	await _shot("03_block_whole", vp, 2)

	print("DONE %d shots -> %s" % [_shots, ProjectSettings.globalize_path(_out)])
	quit(0)


# grabs the viewport after the frame has drawn, so a change made just before is in the picture
func _shot(name: String, from: Viewport, zoom: int) -> void:
	await RenderingServer.frame_post_draw
	var img := from.get_texture().get_image()
	if img == null or img.is_empty():
		_fail("empty image for " + name)
		return
	if zoom > 1:
		img.resize(img.get_width() * zoom, img.get_height() * zoom, Image.INTERPOLATE_NEAREST)
	var path := "%s/%s.png" % [_out, name]
	var err := img.save_png(path)
	if err != OK:
		_fail("save_png failed (%d) for %s" % [err, path])
		return
	_shots += 1
	print("shot %-20s %dx%d" % [name, img.get_width(), img.get_height()])


func _fail(why: String) -> void:
	printerr("CAPTURE FAILED: " + why)
	quit(1)
