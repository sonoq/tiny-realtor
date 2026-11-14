extends SceneTree

# The skyline variants side by side, for Oscar to pick one (AreaBuilder.SKYLINE_STYLE): for each
# Skyline layout (A, B, C, D) a row with the same two lots near the office built as torres, as
# rascacielos and as the works toward rascacielos (x2, outlined in gold), and the same fully grown area (every lot built as high
# as it may go, as the game grows it) at x2 around the office. Saves skyline_options.png and,
# per variant, grown_<letter>.png; fails on any pixel off the palette. Needs a display
# (xvfb-run, see screenshot.sh).
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/skyline_sheet.gd -- --out=/abs/dir --file=/abs/office.json \
#       [--only=0,2]

const CELL := Vector2i(200, 200)
const GROWN := Vector2i(300, 300)
const LABEL_H := 56
const GAP := 8

var _out := "user://skyline"


func _init() -> void:
	var file := ""
	var only: Array[int] = []
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--only="):
			for k in arg.substr(7).split(","):
				only.append(int(k))
	DirAccess.make_dir_recursive_absolute(_out)
	var block: Variant = Store.read_json(file)
	if not block is Dictionary:
		printerr("SKYLINE FAILED: cannot read " + file)
		quit(1)
		return
	if int(block.get("format_version", 0)) == 2:
		block = BlockBaker.upgrade(block)
	await process_frame
	var styles: Array[int] = [0, 1, 2, 3]
	if not only.is_empty():
		styles = only
	var picks := _picks(block)
	if picks.size() < 2:
		printerr("SKYLINE FAILED: no lots for the tier cells")
		quit(1)
		return
	var row_w := CELL.x * 2 * 3 + GROWN.x * 2 + GAP * 3
	var row_h := LABEL_H + GROWN.y * 2
	var sheet := Image.create(row_w, (row_h + GAP) * styles.size(), false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	var bad := 0
	for r in styles.size():
		var style := styles[r]
		AreaBuilder.skyline = style
		var y := r * (row_h + GAP)
		_label(sheet, Vector2i(12, y + 12), Skyline.NAMES[style], 6, "GOLD")
		for k in 3:
			_label(sheet, Vector2i(k * (CELL.x * 2 + GAP) + 8, y + LABEL_H + CELL.y * 2 + 12),
				["TORRES", "RASCACIELOS", "OBRAS: RASCACIELOS"][k], 3, "SL5")
		# the two lots, as torres and as rascacielos
		var tiers := await _tiers(block, picks)
		for k in 3:
			sheet.blit_rect(tiers[k], Rect2i(Vector2i.ZERO, CELL * 2),
				Vector2i(k * (CELL.x * 2 + GAP), y + LABEL_H))
		var grown := await _grown(block)
		grown.save_png("%s/grown_%s.png" % [_out, Skyline.NAMES[style].left(1).to_lower()])
		sheet.blit_rect(grown, Rect2i(Vector2i.ZERO, GROWN * 2),
			Vector2i(CELL.x * 6 + GAP * 3, y + LABEL_H))
		bad += _off_palette(grown)
		for t in tiers:
			bad += _off_palette(t)
	sheet.save_png("%s/skyline_options.png" % _out)
	print("SKYLINE %d variants, %d pixels off the palette" % [styles.size(), bad])
	AreaBuilder.skyline = AreaBuilder.SKYLINE_STYLE
	quit(1 if bad > 0 else 0)


# two big lots near the office, one wider than the other, the same for every variant
func _picks(block: Dictionary) -> Array[int]:
	var lots: Array = block["plots"]
	var order: Array[int] = []
	for i in lots.size():
		var a := float(lots[i]["area_m2"])
		if lots[i]["id"] != block["office_plot"] and a >= 3200.0 and a <= 7500.0 \
				and lots[i]["zone"] != "industrial":
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return _mid(lots[a]).length() < _mid(lots[b]).length())
	var out: Array[int] = []
	for i in order:
		if out.is_empty() or _mid(lots[i]).distance_to(_mid(lots[out[0]])) > 110.0:
			out.append(i)
		if out.size() >= 2:
			break
	return out


func _mid(lot: Dictionary) -> Vector2:
	return Iso.centroid(AreaBuilder._pts(lot["poly"]))


# [torres, rascacielos, works toward rascacielos] cells: both lots at one tier, the first one's crop beside the
# second's (each CELL, x2)
func _tiers(block: Dictionary, picks: Array[int]) -> Array[Image]:
	var out: Array[Image] = []
	# 6 = works toward rascacielos on a bloque
	for tier in [4, 5, 6]:
		var area: Dictionary = block.duplicate(true)
		for i in picks:
			var p: Dictionary = area["plots"][i]
			p["built_tier"] = mini(tier, 5) if tier < 6 else 3
			p["levels"] = BlockBaker.levels_for(p["id"], p["built_tier"])
			if tier == 6:
				p["works"] = 5
		var view := BlockView.new()
		view.active_radius = 0.0
		view.set_block(area)
		root.add_child(view)
		await view.drawn
		var img := view.texture.get_image()
		var cell := Image.create(CELL.x * 2, CELL.y * 2, false, Image.FORMAT_RGBA8)
		for k in picks.size():
			var box: Rect2 = view.lots[picks[k]]["box"]
			var at := Vector2i(box.get_center()) - Vector2i(CELL.x / 4, CELL.y / 2) \
				+ Vector2i(0, -10)
			at = at.clamp(Vector2i.ZERO, img.get_size() - Vector2i(CELL.x / 2, CELL.y))
			var crop := img.get_region(Rect2i(at, Vector2i(CELL.x / 2, CELL.y)))
			var rings := view.outline(picks[k])
			for r: Rect2 in rings[0]:
				for x in range(int(r.position.x), int(r.end.x)):
					var q := Vector2i(x, int(r.position.y)) - at
					if Rect2i(Vector2i.ZERO, crop.get_size()).has_point(q):
						crop.set_pixelv(q, Pal.c("GOLD"))
			crop.resize(CELL.x, CELL.y * 2, Image.INTERPOLATE_NEAREST)
			cell.blit_rect(crop, Rect2i(Vector2i.ZERO, crop.get_size()), Vector2i(k * CELL.x, 0))
		out.append(cell)
		view.queue_free()
	return out


# the area fully grown, as the capture grows it: every lot built to its max tier, all owned
func _grown(block: Dictionary) -> Image:
	var area: Dictionary = block.duplicate(true)
	for p: Dictionary in area["plots"]:
		if p["id"] == area["office_plot"]:
			continue
		var t := Economy.max_tier(p["zone"], float(p["area_m2"]))
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
	# the office where the game puts it (OfficeView.ANCHOR at x2)
	var at := Vector2i(view.focus) - Vector2i(OfficeView.ANCHOR / 2.0)
	var crop := img.get_region(Rect2i(at, GROWN))
	crop.resize(GROWN.x * 2, GROWN.y * 2, Image.INTERPOLATE_NEAREST)
	view.queue_free()
	return crop


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
