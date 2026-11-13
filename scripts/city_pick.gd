class_name CityPick
extends Screen

# The first screen: the shipped list of cities, twelve a page in two columns with < > arrows.
# Clicking a city opens its map (downloading it the first time). Cities where the player already
# has offices show how many.

const COLS := 2
const ROWS := 6
const TOP := 84.0
const TILE := Vector2(282, 62)
const GAP := Vector2(12, 7)
const LEFT := 12.0
const PREV := Rect2(12, 526, 64, 48)
const NEXT := Rect2(524, 526, 64, 48)

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
	_page = clampi(_page + steps, 0, _pages() - 1)
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Ui.CANVAS), Color("#16131d"))
	var total := Store.offices().size()
	Ui.text(self, Vector2(LEFT, 72), "¿Dónde abres tu próxima oficina?", Ui.FONT_SIZE, Ui.INK)
	if total > 0:
		var s := "%d oficina%s" % [total, "" if total == 1 else "s"]
		Ui.text(self, Vector2(588 - Ui.text_width(s, Ui.SMALL), 72), s, Ui.SMALL, Ui.GOLD)
	var cities := CityDb.all()
	for i in COLS * ROWS:
		var n := _page * COLS * ROWS + i
		if n >= cities.size():
			break
		var city: Dictionary = cities[n]
		var r := _tile(i)
		var over := r.has_point(hot)
		draw_rect(r, Ui.PANEL_HI if over else Ui.PANEL)
		draw_rect(r, Ui.GOLD if over else Ui.EDGE, false, 2.0)
		Ui.text(self, r.position + Vector2(14, 28), city["name"], 18, Ui.INK)
		Ui.text(self, r.position + Vector2(14, 49), city["country"], Ui.SMALL, Ui.DIM)
		var mine := Store.offices_in(city["id"]).size()
		var cached := FileAccess.file_exists(Store.city_path(city["id"]))
		if mine > 0:
			var badge := Rect2(r.end.x - 44, r.position.y + 14, 32, 32)
			draw_rect(badge, Ui.GOLD)
			Ui.text_in(self, badge, str(mine), Ui.FONT_SIZE, Ui.BAR)
		elif cached:
			Ui.text(self, Vector2(r.end.x - 12 - Ui.text_width("mapa", Ui.SMALL), r.end.y - 13),
				"mapa", Ui.SMALL, Ui.DIM)
	Ui.button(self, PREV, "<", hot, false, _page == 0)
	Ui.button(self, NEXT, ">", hot, false, _page >= _pages() - 1)
	Ui.text_in(self, Rect2(PREV.end.x, PREV.position.y, NEXT.position.x - PREV.end.x, 48),
		"Página %d de %d" % [_page + 1, _pages()], Ui.FONT_SIZE, Ui.DIM)
	Ui.header(self, "Tiny Realtor · Elige ciudad", false, hot)
	Ui.footer(self, "")
