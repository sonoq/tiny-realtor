extends SceneTree

# Before | after shots of a saved office for the cement ground, the planted squares and the trees
# kept off the road. Each run draws the whole office twice, grown (every lot owned and built as
# high as it may go, as variety_sheet does) and early (as baked, the office's lot owned, level 1),
# into whole_<tag>_grown.png / whole_<tag>_early.png, with where ground metres land in them. With
# --pair=<tag> it puts that run's drawings (an older checkout's, say) beside this one's, ANTES |
# AHORA: grown_before_after.png and early_before_after.png (x2 round the office as the game opens
# it) and one x3 close-up per --spot=name:x:y (metres). Uses only BlockView, so it also runs on an
# older checkout. Fails on any pixel off the palette. Needs a display (xvfb-run, see screenshot.sh).
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/cement_sheet.gd -- --out=/abs/dir --file=/abs/office.json \
#       [--tag=new] [--pair=old] [--spot=gran_via_trees:40:-100 ...]

const CROP := Vector2i(300, 300)
const CLOSE := Vector2i(200, 140)
const LABEL_H := 56

var _out := ""


func _init() -> void:
	var file := ""
	var tag := "new"
	var pair := ""
	var spots: Array[Array] = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--tag="):
			tag = arg.substr(6)
		elif arg.begins_with("--pair="):
			pair = arg.substr(7)
		elif arg.begins_with("--spot="):
			var p := arg.substr(7).split(":")
			spots.append([p[0], Vector2(float(p[1]), float(p[2]))])
	DirAccess.make_dir_recursive_absolute(_out)
	var block: Variant = Store.read_json(file)
	if not block is Dictionary:
		printerr("CEMENT FAILED: cannot read " + file)
		quit(1)
		return
	if int(block.get("format_version", 0)) == 2:
		block = BlockBaker.upgrade(block)
	await process_frame
	var bad := 0
	for mode: String in ["grown", "early"]:
		bad += await _whole(block, mode, tag)
	if pair != "":
		_sheet("grown", pair, tag, "grown_before_after", Vector2.ZERO, CROP, 2, true)
		_sheet("early", pair, tag, "early_before_after", Vector2.ZERO, CROP, 2, true)
		for s: Array in spots:
			_sheet("grown", pair, tag, s[0], s[1], CLOSE, 3, false)
	print("CEMENT %s: %d pixels off the palette" % [tag, bad])
	quit(1 if bad > 0 else 0)


# one whole drawing and its metre -> pixel map; the pixels off the palette
func _whole(block: Dictionary, mode: String, tag: String) -> int:
	var area: Dictionary = block.duplicate(true)
	for p: Dictionary in area["plots"]:
		if mode == "grown":
			var t := mini(5, Economy.max_tier(p["zone"], float(p["area_m2"])))
			p["built_tier"] = t
			p["levels"] = BlockBaker.levels_for(p["id"], t)
			p["owned"] = true
		elif p["id"] == area.get("office_plot", ""):
			p["owned"] = true
	var view := BlockView.new()
	view.live = true
	view.active_radius = Rules.active_radius(5 if mode == "grown" else 1)
	view.set_block(area)
	root.add_child(view)
	await view.drawn
	var img := view.texture.get_image()
	img.save_png("%s/whole_%s_%s.png" % [_out, tag, mode])
	var o := view.project(Vector2.ZERO)
	var ex := view.project(Vector2(1, 0)) - o
	var ey := view.project(Vector2(0, 1)) - o
	var map := {"o": [o.x, o.y], "ex": [ex.x, ex.y], "ey": [ey.x, ey.y]}
	var f := FileAccess.open("%s/whole_%s_%s.json" % [_out, tag, mode], FileAccess.WRITE)
	f.store_string(JSON.stringify(map))
	f.close()
	view.queue_free()
	await process_frame
	return _off_palette(img)


# ANTES | AHORA: the same crop of two runs' drawings, scaled; `office` = round the office as the
# game opens it, else centred on ground point `at`
func _sheet(mode: String, before: String, after: String, name: String, at: Vector2,
		size: Vector2i, zoom: int, office: bool) -> void:
	var w := size.x * zoom
	var sheet := Image.create(w * 2 + 8, size.y * zoom + LABEL_H, false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	_label(sheet, Vector2i(12, 16), "ANTES", 5, "SL5")
	_label(sheet, Vector2i(w + 20, 16), "AHORA", 5, "GOLD")
	var k := 0
	for tag: String in [before, after]:
		var img := Image.load_from_file("%s/whole_%s_%s.png" % [_out, tag, mode])
		var map: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
			"%s/whole_%s_%s.json" % [_out, tag, mode]))
		var o := Vector2(map["o"][0], map["o"][1])
		var c := o + Vector2(map["ex"][0], map["ex"][1]) * at.x \
			+ Vector2(map["ey"][0], map["ey"][1]) * at.y
		var corner := Vector2i(c) - size / 2
		if office:
			corner = Vector2i(o) - Vector2i(OfficeView.ANCHOR / 2.0)
		corner = corner.clamp(Vector2i.ZERO, img.get_size() - size)
		var crop := img.get_region(Rect2i(corner, size))
		crop.resize(w, size.y * zoom, Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()),
			Vector2i(k * (w + 8), LABEL_H))
		k += 1
	sheet.save_png("%s/%s.png" % [_out, name])


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
