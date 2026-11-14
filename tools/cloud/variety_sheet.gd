extends SceneTree

# A saved office grown two ways, for judging how varied a grown district looks: every lot owned
# and built as high as it may go (grown_<tag>.png, x2 round the office as the game opens it, and
# grown_far_<tag>.png, x1), and the same capped at bloque (bloque_<tag>.png, x2). With --pair it
# also writes bloque_vs_max.png (bloque | max, labelled). Fails on any pixel off the palette.
# Needs a display (xvfb-run, see screenshot.sh).
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/variety_sheet.gd -- --out=/abs/dir --file=/abs/office.json \
#       [--tag=new] [--pair] [--pan=x,y]

const CROP := Vector2i(300, 300)
const FAR := Vector2i(600, 600)
const LABEL_H := 56

var _out := "user://variety"


func _init() -> void:
	var file := ""
	var tag := "new"
	var pair := false
	var pan := Vector2i.ZERO
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--tag="):
			tag = arg.substr(6)
		elif arg == "--pair":
			pair = true
		elif arg.begins_with("--pan="):
			var p := arg.substr(6).split(",")
			pan = Vector2i(int(p[0]), int(p[1]))
	DirAccess.make_dir_recursive_absolute(_out)
	var block: Variant = Store.read_json(file)
	if not block is Dictionary:
		printerr("VARIETY FAILED: cannot read " + file)
		quit(1)
		return
	if int(block.get("format_version", 0)) == 2:
		block = BlockBaker.upgrade(block)
	await process_frame
	var bad := 0
	var shots := await _grown(block, 5, pan)
	shots[0].save_png("%s/grown_%s.png" % [_out, tag])
	shots[1].save_png("%s/grown_far_%s.png" % [_out, tag])
	bad += _off_palette(shots[0]) + _off_palette(shots[1])
	var low := await _grown(block, 3, pan)
	low[0].save_png("%s/bloque_%s.png" % [_out, tag])
	low[1].save_png("%s/bloque_far_%s.png" % [_out, tag])
	bad += _off_palette(low[0])
	if pair:
		var sheet := Image.create(CROP.x * 4 + 8, CROP.y * 2 + LABEL_H, false, Image.FORMAT_RGBA8)
		sheet.fill(Pal.c("SL0"))
		_label(sheet, Vector2i(12, 16), "TODO A BLOQUE DE PISOS", 5, "SL5")
		_label(sheet, Vector2i(CROP.x * 2 + 20, 16), "TODO AL MAXIMO", 5, "GOLD")
		sheet.blit_rect(low[0], Rect2i(Vector2i.ZERO, CROP * 2), Vector2i(0, LABEL_H))
		sheet.blit_rect(shots[0], Rect2i(Vector2i.ZERO, CROP * 2),
			Vector2i(CROP.x * 2 + 8, LABEL_H))
		sheet.save_png("%s/bloque_vs_max.png" % _out)
	print("VARIETY %s: %d pixels off the palette" % [tag, bad])
	quit(1 if bad > 0 else 0)


# every lot (the office's free one too) owned and built to its max tier, at most `cap`; [x2 crop
# round the office where the game puts it, x1 crop]
func _grown(block: Dictionary, cap: int, pan: Vector2i) -> Array[Image]:
	var area: Dictionary = block.duplicate(true)
	for p: Dictionary in area["plots"]:
		var t := mini(cap, Economy.max_tier(p["zone"], float(p["area_m2"])))
		p["built_tier"] = t
		p["levels"] = BlockBaker.levels_for(p["id"], t)
		p["owned"] = true
	var view := BlockView.new()
	view.live = true
	view.active_radius = Rules.active_radius(5)
	view.set_block(area)
	root.add_child(view)
	await view.drawn
	var img := view.texture.get_image()
	var at := Vector2i(view.focus) - Vector2i(OfficeView.ANCHOR / 2.0) + pan
	at = at.clamp(Vector2i.ZERO, img.get_size() - CROP)
	var crop := img.get_region(Rect2i(at, CROP))
	crop.resize(CROP.x * 2, CROP.y * 2, Image.INTERPOLATE_NEAREST)
	var fat := Vector2i(view.focus) - FAR / 2 + pan
	fat = fat.clamp(Vector2i.ZERO, img.get_size() - FAR)
	var far := img.get_region(Rect2i(fat, FAR))
	view.queue_free()
	return [crop, far]


func _label(img: Image, at: Vector2i, text: String, px: int, colour: String) -> void:
	var dots := {}
	Sprites.micro(dots, 0, 0, text, Pal.i(colour))
	for q: Vector2i in dots:
		img.fill_rect(Rect2i(at + q * px, Vector2i(px, px)), Pal.color(dots[q]))


func _off_palette(img: Image) -> int:
	var ok := {}
	for k in Pal.NAMES.size():
		ok[Pal.color(k).to_rgba32() | 0xFF] = true
	var data := img.get_data()
	var n := 0
	for i in range(0, data.size(), 4):
		if data[i + 3] == 0:
			continue
		var c := (data[i] << 24) | (data[i + 1] << 16) | (data[i + 2] << 8) | 0xFF
		if not ok.has(c):
			n += 1
	return n
