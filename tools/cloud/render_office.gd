extends SceneTree

# Renders saved office areas with BlockView alone, without the rest of the game, and saves for
# each: the whole drawing (<id>_full.png, one art pixel per pixel) and a 600x600 crop around the
# office at the game's default zoom (<id>_x2.png). For looking at the art quickly; needs a display
# (xvfb-run, see screenshot.sh).
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/render_office.gd -- --out=/abs/dir [--file=/abs/office.json ...]
# With no --file it renders every office the game has saved.

var _out := "user://renders"


func _init() -> void:
	var files: Array[String] = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			files.append(arg.substr(7))
	if files.is_empty():
		for o: Dictionary in Store.offices():
			files.append(ProjectSettings.globalize_path(Store.office_path(o["id"])))
	DirAccess.make_dir_recursive_absolute(_out)
	await process_frame
	for f in files:
		var block: Variant = Store.read_json(f)
		if not block is Dictionary:
			printerr("RENDER FAILED: cannot read " + f)
			quit(1)
			return
		var view := BlockView.new()
		var meta: Dictionary = block.get("office", {})
		view.active_radius = float(meta.get("active_radius", Rules.active_radius(1)))
		if not view.set_block(block):
			printerr("RENDER FAILED: bad block " + f)
			quit(1)
			return
		root.add_child(view)
		await view.drawn
		var img := view.texture.get_image()
		var id := f.get_file().get_basename()
		img.save_png("%s/%s_full.png" % [_out, id])
		var half := Vector2i(150, 150)
		var at := Vector2i(view.focus) - half + Vector2i(0, -20)
		var crop := img.get_region(Rect2i(at, half * 2))
		crop.resize(600, 600, Image.INTERPOLATE_NEAREST)
		crop.save_png("%s/%s_x2.png" % [_out, id])
		print("RENDER %s %dx%d build %d ms draw %d ms" % [id, img.get_width(), img.get_height(),
			view.build_ms, view.draw_ms])
		view.queue_free()
	quit(0)
