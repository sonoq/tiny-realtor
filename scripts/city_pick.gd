class_name CityPick
extends Screen

# The first screen: the shipped list of cities, twelve a page in two columns with < > arrows.
# Clicking a city opens its map (downloading it the first time). Cities where the player already
# has offices show how many on a gold badge; cities whose map is saved say so.

const COLS := 2
const ROWS := 6
const TOP := 112.0
const TILE := Vector2(282, 62)
const GAP := Vector2(12, 6)
const LEFT := 12.0
const PREV := Rect2(12, 508, 64, 56)
const NEXT := Rect2(524, 508, 64, 56)

var _page := 0


func _pages() -> int:
	return ceili(CityDb.all().size() / float(COLS * ROWS))


func _tile(i: int) -> Rect2:
	var col := i % COLS
	var row := i / COLS
	return Rect2(Vector2(LEFT + col * (TILE.x + GAP.x), TOP + row * (TILE.y + GAP.y)), TILE)


func _city_at(at: Vector2) -> Dictionary:
	var cities := CityDb.all()
	for i in COLS * ROWS:
		var n := _page * COLS * ROWS + i
		if n < cities.size() and _tile(i).has_point(at):
			return cities[n]
	return {}


func press(at: Vector2) -> bool:
	return not _city_at(at).is_empty() or PREV.has_point(at) or NEXT.has_point(at)


func click(at: Vector2) -> void:
	if PREV.has_point(at) and _page > 0:
		_page -= 1
	elif NEXT.has_point(at) and _page < _pages() - 1:
		_page += 1
	else:
		var city := _city_at(at)
		if not city.is_empty():
			app.open_city(city["id"])
			return
	queue_redraw()


func wheel(_at: Vector2, steps: int) -> void:
	_page = clampi(_page - steps, 0, _pages() - 1)
	queue_redraw()


func _draw() -> void:
	Ui.backdrop(self)
	var total := Store.offices().size()
	Ui.text(self, Vector2(LEFT + 4, 96), "¿Dónde abres tu próxima oficina?", Ui.SMALL, Ui.MUTED,
		Ui.TEN)
	var cities := CityDb.all()
	for i in COLS * ROWS:
		var n := _page * COLS * ROWS + i
		if n >= cities.size():
			break
		var city: Dictionary = cities[n]
		var r := _tile(i)
		var over := r.has_point(hot)
		Ui.plate(self, r, Ui.SHEET.lightened(0.06) if over else Ui.SHEET,
			Ui.CYAN if over else Ui.RIM_DIM, 13)
		Ui.text(self, r.position + Vector2(14, 30), city["name"], Ui.TEXT, Ui.CREAM)
		Ui.text(self, r.position + Vector2(14, 52), city["country"], Ui.SMALL, Ui.MUTED, Ui.TEN)
		var mine := Store.offices_in(city["id"]).size()
		var cached := FileAccess.file_exists(Store.city_path(city["id"]))
		if mine > 0:
			var badge := Rect2(r.end.x - 46, r.position.y + 15, 32, 32)
			Ui.chip(self, badge, Ui.GOLD, Ui.CREAM)
			Ui.text_in(self, badge, str(mine), Ui.TEXT, Ui.VOID, Ui.BOLD, false)
		elif cached:
			Ui.micro(self, Vector2(r.end.x - 14 - Ui.micro_width("MAPA"), r.end.y - 18), "MAPA",
				Ui.MUTED)
	Ui.arrow(self, PREV, "<", hot, _page == 0)
	Ui.arrow(self, NEXT, ">", hot, _page >= _pages() - 1)
	Ui.text_in(self, Rect2(PREV.end.x, PREV.position.y, NEXT.position.x - PREV.end.x,
		PREV.size.y), "Página %d / %d" % [_page + 1, _pages()], Ui.TEXT, Ui.MUTED)
	Ui.header(self, "Tiny Realtor", false, hot)
	if total > 0:
		var s := "%d oficina%s" % [total, "" if total == 1 else "s"]
		Ui.coin(self, Vector2(588 - Ui.text_width(s, Ui.TEXT) - 22, 34))
		Ui.text_right(self, Vector2(588, 48), s, Ui.TEXT, Ui.GOLD)
	Ui.footer(self, "")
