extends SceneTree

# The top tiers' variety: up to 16 lots near the office built as high as they may go (torres or
# rascacielos), each picking its own archetype and materials as the game does (Skyline.MIX),
# lots with an archetype not shown yet first; each cell x2, the lot outlined in gold, labelled
# with its archetype and tier, into top_tiers_gallery.png. Then works_vs_built.png: four of them
# as building sites next to the finished building, to see the scaffolding grow into it. Fails on
# any pixel off the palette. Needs a display (xvfb-run, see screenshot.sh).
#
#   godot --path . --rendering-driver opengl3 --audio-driver Dummy \
#       --script res://tools/cloud/skyline_sheet.gd -- --out=/abs/dir --file=/abs/office.json \
#       [--n=16]

const CELL := Vector2i(170, 150)
const COLS := 4
const LABEL_H := 30
const GAP := 6

var _out := "user://skyline"


func _init() -> void:
	var file := ""
	var want := 16
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.substr(6)
		elif arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--n="):
			want = int(arg.substr(4))
	DirAccess.make_dir_recursive_absolute(_out)
	var block: Variant = Store.read_json(file)
	if not block is Dictionary:
		printerr("SKYLINE FAILED: cannot read " + file)
		quit(1)
		return
	if int(block.get("format_version", 0)) == 2:
		block = BlockBaker.upgrade(block)
	await process_frame
	var picks := _picks(block, want)
	if picks.size() < 4:
		printerr("SKYLINE FAILED: not enough lots for the gallery")
		quit(1)
		return
	var bad := 0
	# the gallery: every picked lot at its max tier, the rest as the file has them
	var area: Dictionary = block.duplicate(true)
	for pk: Array in picks:
		var p: Dictionary = area["plots"][pk[0]]
		p["built_tier"] = pk[1]
		p["levels"] = BlockBaker.levels_for(p["id"], pk[1])
	var view := await _draw(area)
	var img := view.texture.get_image()
	bad += _off_palette(img)
	var rows := ceili(picks.size() / float(COLS))
	var cw := CELL.x * 2
	var ch := CELL.y * 2 + LABEL_H
	var sheet := Image.create(COLS * (cw + GAP) - GAP, rows * (ch + GAP) - GAP, false,
		Image.FORMAT_RGBA8)
	sheet.fill(Pal.c("SL0"))
	for k in picks.size():
		var i: int = picks[k][0]
		var at := Vector2i(k % COLS * (cw + GAP), k / COLS * (ch + GAP))
		sheet.blit_rect(_cell(view, img, i), Rect2i(Vector2i.ZERO, CELL * 2),
			at + Vector2i(0, LABEL_H))
		var text := "%s  %s" % [Skyline.NAMES[picks[k][2]], "RASCACIELOS" if picks[k][1] == 5
			else "TORRES"]
		_label(sheet, at + Vector2i(6, 8), text, 3, "GOLD" if picks[k][1] == 5 else "SL5")
		print("SKYLINE lot %s: %s, tier %d, %.0f m2" % [area["plots"][i]["id"],
			Skyline.NAMES[picks[k][2]], picks[k][1], float(area["plots"][i]["area_m2"])])
	sheet.save_png("%s/top_tiers_gallery.png" % _out)
	view.queue_free()
	# works toward the same tier on four of them, next to the finished building
	var four := picks.slice(0, 4)
	var site: Dictionary = block.duplicate(true)
	for pk: Array in four:
		var p: Dictionary = site["plots"][pk[0]]
		p["built_tier"] = 3
		p["levels"] = BlockBaker.levels_for(p["id"], 3)
		p["works"] = pk[1]
	var wv := await _draw(site)
	var wimg := wv.texture.get_image()
	bad += _off_palette(wimg)
	var pair := Image.create(2 * (cw + GAP) - GAP, 4 * (ch + GAP) - GAP, false, Image.FORMAT_RGBA8)
	pair.fill(Pal.c("SL0"))
	var built := await _draw(area)
	var bimg := built.texture.get_image()
	for k in 4:
		var i: int = four[k][0]
		var y := k * (ch + GAP)
		pair.blit_rect(_cell(wv, wimg, i), Rect2i(Vector2i.ZERO, CELL * 2),
			Vector2i(0, y + LABEL_H))
		pair.blit_rect(_cell(built, bimg, i), Rect2i(Vector2i.ZERO, CELL * 2),
			Vector2i(cw + GAP, y + LABEL_H))
		_label(pair, Vector2i(6, y + 8), "OBRAS", 3, "SL5")
		_label(pair, Vector2i(cw + GAP + 6, y + 8), Skyline.NAMES[four[k][2]], 3, "GOLD")
	pair.save_png("%s/works_vs_built.png" % _out)
	wv.queue_free()
	built.queue_free()
	print("SKYLINE %d lots, %d pixels off the palette" % [picks.size(), bad])
	quit(1 if bad > 0 else 0)


# lots near the office that may go to torres or rascacielos: [index, tier, archetype], one of
# each archetype first (nearest first), then the nearest others
func _picks(block: Dictionary, want: int) -> Array:
	var lots: Array = block["plots"]
	var order: Array[int] = []
	for i in lots.size():
		var t := Economy.max_tier(lots[i]["zone"], float(lots[i]["area_m2"]))
		if t >= 4 and _mid(lots[i]).length() < float(block["radius_m"]) - 60.0:
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return _mid(lots[a]).length() < _mid(lots[b]).length())
	var out: Array = []
	var seen := {}
	var rest: Array = []
	for i in order:
		var p: Dictionary = lots[i]
		var t := Economy.max_tier(p["zone"], float(p["area_m2"]))
		var poly := AreaBuilder._pts(p["poly"])
		var plan := Skyline.plan(t, poly, BlockBaker.levels_for(p["id"], t), p["id"],
			PackedInt32Array(p.get("fronts", [])), p.get("corner", false))
		var kind: int = plan["kind"]
		if seen.has(kind):
			rest.append([i, t, kind])
			continue
		seen[kind] = true
		out.append([i, t, kind])
		if out.size() >= want:
			return out
	for r: Array in rest:
		if out.size() >= want:
			break
		out.append(r)
	return out


func _mid(lot: Dictionary) -> Vector2:
	return Iso.centroid(AreaBuilder._pts(lot["poly"]))


func _draw(area: Dictionary) -> BlockView:
	var view := BlockView.new()
	view.active_radius = 0.0
	view.set_block(area)
	root.add_child(view)
	await view.drawn
	return view


# one lot's cell: its box's middle, x2, outlined in gold
func _cell(view: BlockView, img: Image, i: int) -> Image:
	var box: Rect2 = view.lots[i]["box"]
	var at := Vector2i(box.get_center()) - CELL / 2 + Vector2i(0, 6)
	at = at.clamp(Vector2i.ZERO, img.get_size() - CELL)
	var crop := img.get_region(Rect2i(at, CELL))
	for r: Rect2 in view.outline(i)[0]:
		for x in range(int(r.position.x), int(r.end.x)):
			var q := Vector2i(x, int(r.position.y)) - at
			if Rect2i(Vector2i.ZERO, CELL).has_point(q):
				crop.set_pixelv(q, Pal.c("GOLD"))
	crop.resize(CELL.x * 2, CELL.y * 2, Image.INTERPOLATE_NEAREST)
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
