extends SceneTree

# Renders saved office areas with BlockView alone, without the rest of the game, and saves for
# each: the whole drawing (<id>_full.png, one art pixel per pixel) and a 600x600 crop around the
# office at the game's default zoom (<id>_x2.png). It fails when any pixel is off the palette.
# A saved v2 area is re-parcelled into lots first (BlockBaker.upgrade), in memory only.
# With --tiers it also makes <id>_tiers.png: lots near the office rebuilt at each tier (solar,
# casas, urbanizacion, bloque, torres, rascacielos, then industrial sheds and the office's own
# lot), each cropped at x2 with its lot outlined in gold and its name under it; those tiers are
# set for the sheet, the area's real ones are in <id>_full.png.
# With --redraw it checks the game's one-lot redraws: four lots near the office are bought,
# rebuilt and put into works one by one through BlockView.redraw_lot, and the result must match
# a fresh full drawing of the same area (<id>_redraw.png: before | after, at x2); it prints how
# long each redraw kept the main thread busy.
# For looking at the art quickly; needs a display (xvfb-run, see screenshot.sh).
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/render_office.gd -- --out=/abs/dir [--file=/abs/office.json ...] \
#       [--tiers]
# With no --file it renders every office the game has saved.

const SHEET_CELL := Vector2i(300, 230)
const SHEET_NAMES: Array[String] = ["0 SOLAR", "1 CASAS", "2 URBANIZACION", "3 BLOQUE",
	"4 TORRES", "5 RASCACIELOS", "NAVES INDUSTRIAL", "TU OFICINA"]

var _out := "user://renders"
# pixels a lot redraw may differ from a fresh drawing (painter's order of a few overlapping
# objects can tie differently when only some of them are sorted)
const REDRAW_SLACK := 400


func _init() -> void:
	var files: Array[String] = []
	var tiers := false
	var redraw := false
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			files.append(arg.substr(7))
		elif arg == "--tiers":
			tiers = true
		elif arg == "--redraw":
			redraw = true
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
		if int(block.get("format_version", 0)) == 2:
			block = BlockBaker.upgrade(block)
			print("RENDER %s: v2 re-parcelled into %d lots" % [f.get_file(), block["plots"].size()])
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
		var off := _off_palette(img)
		print("RENDER %s %dx%d build %d ms draw %d ms, %d pixels off the palette" % [id,
			img.get_width(), img.get_height(), view.build_ms, view.draw_ms, off])
		if off > 0:
			printerr("RENDER FAILED: %s has %d pixels off the palette" % [id, off])
			quit(1)
			return
		view.queue_free()
		if tiers and not await _tiers(block, id):
			quit(1)
			return
		if redraw and not await _redraw(block, id):
			quit(1)
			return
	quit(0)


# the tiers sheet: eight lots near the office, each built as one tier, side by side
func _tiers(block: Dictionary, id: String) -> bool:
	var area: Dictionary = block.duplicate(true)
	var lots: Array = area["plots"]
	var picks: Array[int] = []
	var order: Array[int] = []
	for i in lots.size():
		order.append(i)
	var mid := func(i: int) -> Vector2:
		var poly := AreaBuilder._pts(lots[i]["poly"])
		return Iso.centroid(poly)
	order.sort_custom(func(a: int, b: int) -> bool:
		return (mid.call(a) as Vector2).length() < (mid.call(b) as Vector2).length())
	for i in order:
		if picks.size() >= 7:
			break
		var a := float(lots[i]["area_m2"])
		if lots[i]["id"] == area["office_plot"] or a < 2500.0 or a > 7500.0:
			continue
		var far := true
		for j in picks:
			far = far and (mid.call(i) as Vector2).distance_to(mid.call(j)) > 95.0
		if far:
			picks.append(i)
	if picks.size() < 7:
		printerr("RENDER FAILED: not enough lots for the tiers sheet")
		return false
	for k in picks.size():
		var lot: Dictionary = lots[picks[k]]
		var tier := k if k < 6 else 1
		lot["built_tier"] = tier
		lot["zone"] = "industrial" if k == 6 else "residential"
		var lv: Vector2i = BlockBaker.TIER_LEVELS[tier]
		lot["levels"] = (lv.x + lv.y) / 2
	for i in lots.size():
		if lots[i]["id"] == area["office_plot"]:
			picks.append(i)
	var view := BlockView.new()
	view.active_radius = 0.0
	view.set_block(area)
	root.add_child(view)
	await view.drawn
	var img := view.texture.get_image()
	var cell := SHEET_CELL * 2
	var sheet := Image.create(cell.x * 4, (cell.y + 40) * 2, false, Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	for k in picks.size():
		var box: Rect2 = view.lots[picks[k]]["box"]
		var at := Vector2i(box.get_center()) - SHEET_CELL / 2
		at = at.clamp(Vector2i.ZERO, img.get_size() - SHEET_CELL)
		var crop := img.get_region(Rect2i(at, SHEET_CELL))
		var rings := view.outline(picks[k])
		for ring in 2:
			for r: Rect2 in rings[ring]:
				for x in range(int(r.position.x), int(r.end.x)):
					var q := Vector2i(x, int(r.position.y)) - at
					if Rect2i(Vector2i.ZERO, SHEET_CELL).has_point(q):
						crop.set_pixelv(q, Pal.c("GOLD") if ring == 0 else Pal.c("INK"))
		crop.resize(cell.x, cell.y, Image.INTERPOLATE_NEAREST)
		var origin := Vector2i(k % 4 * cell.x, k / 4 * (cell.y + 40))
		sheet.blit_rect(crop, Rect2i(Vector2i.ZERO, cell), origin)
		_label(sheet, origin + Vector2i(12, cell.y + 10), SHEET_NAMES[k])
	sheet.save_png("%s/%s_tiers.png" % [_out, id])
	var off := _off_palette(sheet)
	print("RENDER %s tiers sheet, %d pixels off the palette" % [id, off])
	view.queue_free()
	return off == 0


# the game's lot redraws against a fresh drawing of the same changes
func _redraw(block: Dictionary, id: String) -> bool:
	var area: Dictionary = block.duplicate(true)
	var lots: Array = area["plots"]
	var order: Array[int] = []
	for i in lots.size():
		var c := Iso.centroid(AreaBuilder._pts(lots[i]["poly"]))
		if lots[i]["id"] != area["office_plot"] and c.length() < 140.0:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return Iso.centroid(AreaBuilder._pts(lots[a]["poly"])).length() \
			< Iso.centroid(AreaBuilder._pts(lots[b]["poly"])).length())
	if order.size() < 4:
		printerr("RENDER FAILED: not enough lots near the office to redraw")
		return false
	var view := BlockView.new()
	view.live = true
	view.active_radius = Rules.active_radius(1)
	view.set_block(area)
	root.add_child(view)
	await view.drawn
	var before := view.texture.get_image()
	# bought as it stands; two tiers up; works toward torres; works on the next tier
	var changes: Array = [[order[0], -1, false], [order[1], 2, false], [order[2], 4, true],
		[order[3], 1, true]]
	for ch: Array in changes:
		var plot: Dictionary = lots[ch[0]]
		plot["owned"] = true
		var t := int(plot["built_tier"])
		if ch[2]:
			plot["works"] = mini(5, t + int(ch[1])) if int(ch[1]) < 4 else maxi(t + 1, 4)
		elif int(ch[1]) > 0:
			plot["built_tier"] = mini(5, t + int(ch[1]))
			plot["levels"] = BlockBaker.levels_for(plot["id"], int(plot["built_tier"]))
		view.redraw_lot(ch[0])
		await view.redrawn
		print("RENDER %s redraw lot %s: %dx%d px, main thread %d ms, on screen after %d ms" % [
			id, plot["id"], view.redraw_px.x, view.redraw_px.y, view.redraw_ms,
			view.redraw_wall_ms])
	var after := view.texture.get_image()
	var fresh_view := BlockView.new()
	fresh_view.live = true
	fresh_view.active_radius = Rules.active_radius(1)
	fresh_view.set_block(area)
	root.add_child(fresh_view)
	await fresh_view.drawn
	var fresh := fresh_view.texture.get_image()
	var diff := 0
	var a := after.get_data()
	var b := fresh.get_data()
	for i in range(0, a.size(), 4):
		if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2] or a[i + 3] != b[i + 3]:
			diff += 1
	var half := Vector2i(150, 150)
	var at := Vector2i(view.focus) - half + Vector2i(0, -20)
	var sheet := Image.create(1200, 600, false, Image.FORMAT_RGBA8)
	for k in 2:
		var crop := (before if k == 0 else after).get_region(Rect2i(at, half * 2))
		crop.resize(600, 600, Image.INTERPOLATE_NEAREST)
		sheet.blit_rect(crop, Rect2i(0, 0, 600, 600), Vector2i(k * 600, 0))
	sheet.save_png("%s/%s_redraw.png" % [_out, id])
	# Traffic's depth and shadow images must follow the redraws too
	var depth_diff := _diff(view.depth_tex.get_image(), fresh_view.depth_tex.get_image())
	var shade_diff := _diff(view.shade_tex.get_image(), fresh_view.shade_tex.get_image())
	print("RENDER %s redraws vs a fresh drawing: %d pixels differ, %d off the palette; depth %d, shadow %d differ" % [
		id, diff, _off_palette(after), depth_diff, shade_diff])
	if depth_diff > REDRAW_SLACK or shade_diff > REDRAW_SLACK:
		printerr("RENDER FAILED: the depth or shadow image did not follow the lot redraws")
		return false
	view.queue_free()
	fresh_view.queue_free()
	return diff <= REDRAW_SLACK and _off_palette(after) == 0


func _diff(a_img: Image, b_img: Image) -> int:
	var a := a_img.get_data()
	var b := b_img.get_data()
	var n := 0
	for i in range(0, mini(a.size(), b.size()), 4):
		if a[i] != b[i] or a[i + 1] != b[i + 1] or a[i + 2] != b[i + 2] or a[i + 3] != b[i + 3]:
			n += 1
	return n


# micro-font text into an image, each font pixel 4x4
func _label(img: Image, at: Vector2i, text: String) -> void:
	var px := {}
	Sprites.micro(px, 0, 0, text, Pal.i("CREAM"))
	for q: Vector2i in px:
		img.fill_rect(Rect2i(at + q * 4, Vector2i(4, 4)), Pal.color(px[q]))


# opaque pixels whose colour is not one of Pal's: the drawing must never blend
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
