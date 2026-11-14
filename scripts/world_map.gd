class_name WorldMap
extends Screen

# The first screen: the world in pixel art (World: Natural Earth's coastlines baked into one
# picture per zoom step, assets/world/), every shipped city a small dot, the player's offices as
# gold pins (the office view's pin) with their count. Drag to pan, wheel or - + to zoom in whole
# steps (x1 the whole world, x16 a region). Markers closer than a hit box are grouped: a group of
# a few cities opens a small list, a big one zooms in on itself. A city opens its map (downloaded
# the first time); a city with offices, or a group, opens the list, whose office rows open the
# office directly. The list button opens the plain city list. The zoom and the view are kept for
# the session, and coming back from a city centres on it. Esc closes the list, else quits.

const MAP_TOP := Ui.BAR_H
const MAP_BOTTOM := Ui.CANVAS.y - Ui.FOOT_H
const ZOOM_IN := Rect2(536, 88, 52, 52)
const ZOOM_OUT := Rect2(536, 146, 52, 52)
const LIST_BTN := Rect2(536, 212, 52, 52)
const MONEY_AT := Vector2(588, 40)
const STEP_MAX := World.STEPS - 1
# a marker's hit box (canvas px, at least Ui.MIN_HIT) round its point, a little above it where
# the pin stands; groups keep their points HIT apart on one axis at least, so boxes never overlap
const HIT := 48.0
const HIT_OFF := Vector2(-24, -32)
# a group of more cities than this zooms in on itself instead of listing them
const LIST_MAX := 4
# the list: a panel at the bottom, ROWS rows a page
const ROWS := 5
const ROW_H := 52.0
const BOX_W := 576.0
const PIN: Array[String] = [
	"...lgggm...",
	"..lgggggm..",
	".lgggHgggm.",
	"lgggHHHgggm",
	"lggHHHHHggm",
	"lgggHHHgggm",
	"lgggHgHgggm",
	".ggggggggm.",
	"..ggggggm..",
	"...ggggm...",
	"....ggm....",
	".....m.....",
]
const DOT: Array[String] = [".11.", "1111", "1111", ".11."]

# kept for the session: the zoom step and the map point in the middle of the view (0..1)
static var _level := 0
static var _mid := Vector2(0.5, 0.42)

var _sprite: Sprite2D
var _over: Node2D
var _pan := Vector2.ZERO
# the cities (CityDb order, those with offices first) with their offices: {city, offices, u}
var _places: Array[Dictionary] = []
var _groups := {}
var _hot_group := -1
# the open list: rows [{kind: "city" | "office", city, office?}], or empty
var _rows: Array[Dictionary] = []
var _list_title := ""
var _single := false
var _page := 0
var _cash := ""


func _ready() -> void:
	_collect()
	_sprite = Sprite2D.new()
	_sprite.centered = false
	add_child(_sprite)
	_over = Node2D.new()
	_over.draw.connect(_draw_over)
	add_child(_over)
	_set_level(_level, _view_mid())


func _process(_delta: float) -> void:
	if app == null:
		return
	var cash := Economy.money(app.game.money())
	if cash != _cash:
		_cash = cash
		_over.queue_redraw()


func _collect() -> void:
	_places.clear()
	var with: Array[Dictionary] = []
	var without: Array[Dictionary] = []
	for city in CityDb.all():
		var mine := Store.offices_in(city["id"])
		var p := {"city": city, "offices": mine, "u": World.unit(city["lat"], city["lon"])}
		if mine.is_empty():
			without.append(p)
		else:
			with.append(p)
	with.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["offices"] as Array).size() > (b["offices"] as Array).size())
	_places.append_array(with)
	_places.append_array(without)
	_groups.clear()


# --- coordinates -------------------------------------------------------------------------------

static func _view() -> Rect2:
	return Rect2(0, MAP_TOP, Ui.CANVAS.x, MAP_BOTTOM - MAP_TOP)


static func _view_mid() -> Vector2:
	return _view().get_center()


func _size() -> Vector2:
	return World.screen_size(_level)


func _screen(u: Vector2) -> Vector2:
	return _pan + u * _size()


func _unit_at(at: Vector2) -> Vector2:
	return (at - _pan) / _size()


# the groups at a zoom step: [{at (map px at that step), members: [place index]}]
func _groups_at(level: int) -> Array:
	if not _groups.has(level):
		var pts := PackedVector2Array()
		for p in _places:
			pts.append((p["u"] as Vector2) * World.screen_size(level))
		_groups[level] = World.clusters(pts, HIT)
	return _groups[level]


func _hit(g: Dictionary) -> Rect2:
	return Rect2(_pan + (g["at"] as Vector2) + HIT_OFF, Vector2(HIT, HIT))


func _group_at(at: Vector2) -> int:
	if at.y < MAP_TOP or at.y > MAP_BOTTOM or _on_buttons(at) or not _rows.is_empty():
		return -1
	var best := -1
	var best_d := INF
	var groups := _groups_at(_level)
	for k in groups.size():
		var r := _hit(groups[k])
		if r.has_point(at) and r.get_center().distance_to(at) < best_d:
			best_d = r.get_center().distance_to(at)
			best = k
	return best


func _on_buttons(at: Vector2) -> bool:
	return ZOOM_IN.has_point(at) or ZOOM_OUT.has_point(at) or LIST_BTN.has_point(at)


# --- driving it (also used by tools/cloud/capture.gd) -------------------------------------------

func set_level(i: int) -> void:
	_set_level(i, _view_mid())


func level() -> int:
	return _level


func center_on(lat: float, lon: float) -> void:
	_pan_to(_view_mid() - World.unit(lat, lon) * _size())


# coming back from a city: centred on it, close enough to tell its neighbours apart
func focus(city_id: String) -> void:
	var city := CityDb.get_city(city_id)
	if city.is_empty():
		return
	_set_level(maxi(_level, 2), _view_mid())
	center_on(city["lat"], city["lon"])


# where the pointer must be to point at a city's marker (its group's), or INF when off screen
func spot_of(city_id: String) -> Vector2:
	var groups := _groups_at(_level)
	for g: Dictionary in groups:
		for m: int in g["members"]:
			if _places[m]["city"]["id"] == city_id:
				var at := _pan + (g["at"] as Vector2) + Vector2(0, -8)
				return at if _view().has_point(at) else Vector2.INF
	return Vector2.INF


func list_open() -> bool:
	return not _rows.is_empty()


func list_rows() -> Array[Dictionary]:
	return _rows


# turns the list to the page that shows row n
func show_row(n: int) -> void:
	_page = clampi(n / ROWS, 0, maxi(0, _pages() - 1))
	_over.queue_redraw()


# the canvas rect of one row of the open list (its index in list_rows), or an empty rect
func row_rect(n: int) -> Rect2:
	if n < _page * ROWS or n >= mini(_rows.size(), (_page + 1) * ROWS):
		return Rect2()
	var box := _box()
	return Rect2(box.position.x + 14, box.position.y + 62 + (n - _page * ROWS) * ROW_H,
		box.size.x - 28, ROW_H - 6)


# --- input -------------------------------------------------------------------------------------

func press(at: Vector2) -> bool:
	if not _rows.is_empty():
		return true
	return _on_buttons(at) or _group_at(at) >= 0


func click(at: Vector2) -> void:
	if not _rows.is_empty():
		_click_list(at)
		return
	if ZOOM_IN.has_point(at):
		_set_level(_level + 1, _view_mid())
		return
	if ZOOM_OUT.has_point(at):
		_set_level(_level - 1, _view_mid())
		return
	if LIST_BTN.has_point(at):
		app.show_cities()
		return
	var k := _group_at(at)
	if k < 0:
		return
	var g: Dictionary = _groups_at(_level)[k]
	var members: Array = g["members"]
	if members.size() == 1 and (_places[members[0]]["offices"] as Array).is_empty():
		app.open_city(_places[members[0]]["city"]["id"])
		return
	if members.size() > LIST_MAX and _level < STEP_MAX:
		_zoom_to(members)
		return
	_open_list(members)


func drag(_at: Vector2, rel: Vector2) -> void:
	if _rows.is_empty():
		_pan_to(_pan + rel)


func hover(at: Vector2) -> void:
	hot = at
	_hot_group = _group_at(at)
	_over.queue_redraw()


func wheel(at: Vector2, steps: int) -> void:
	if _rows.is_empty():
		_set_level(_level + steps, at if _view().has_point(at) else _view_mid())


func back() -> bool:
	if not _rows.is_empty():
		_rows.clear()
		hover(hot)
		return true
	return false


func _set_level(i: int, around: Vector2) -> void:
	i = clampi(i, 0, STEP_MAX)
	var u := _mid if _sprite.texture == null else _unit_at(around)
	if _sprite.texture == null:
		around = _view_mid()
	_show_step(i)
	_pan_to(around - u * _size())


func _show_step(i: int) -> void:
	_level = i
	var tex := World.texture_level(i)
	_sprite.texture = load(World.PATH % tex) as Texture2D
	_sprite.scale = World.screen_size(i) / Vector2(World.art_size(tex))


# the map covers the view where it is bigger than the view, and sits in its middle where not
func _pan_to(at: Vector2) -> void:
	var view := _view()
	var size := _size()
	var p := at
	for axis in 2:
		if size[axis] <= view.size[axis]:
			p[axis] = view.position[axis] + (view.size[axis] - size[axis]) * 0.5
		else:
			p[axis] = clampf(p[axis], view.end[axis] - size[axis], view.position[axis])
	_pan = (p / World.ART_PX).round() * World.ART_PX
	_sprite.position = _pan
	_mid = _unit_at(_view_mid())
	_hot_group = _group_at(hot)
	_over.queue_redraw()


# zooms in, around the group, to the first step that splits it (or the last)
func _zoom_to(members: Array) -> void:
	var mid := Vector2.ZERO
	for m: int in members:
		mid += _places[m]["u"]
	mid /= members.size()
	var target := STEP_MAX
	for l in range(_level + 1, World.STEPS):
		var split := 0
		for g: Dictionary in _groups_at(l):
			for m: int in g["members"]:
				if members.has(m):
					split += 1
					break
		if split > 1:
			target = l
			break
	_show_step(target)
	_pan_to(_view_mid() - mid * _size())


func _open_list(members: Array) -> void:
	_rows.clear()
	_page = 0
	for m: int in members:
		var p: Dictionary = _places[m]
		_rows.append({"kind": "city", "city": p["city"]})
		for o: Dictionary in p["offices"]:
			_rows.append({"kind": "office", "city": p["city"], "office": o})
	var first: Dictionary = _places[members[0]]["city"]
	_single = members.size() == 1
	_list_title = "%s, %s" % [first["name"], first["country"]] if _single \
		else "%d ciudades" % members.size()
	_hot_group = -1
	_over.queue_redraw()


func _pages() -> int:
	return ceili(_rows.size() / float(ROWS))


func _box() -> Rect2:
	var shown := mini(ROWS, _rows.size())
	var h := 62.0 + shown * ROW_H + (60.0 if _pages() > 1 else 6.0) + 10.0
	return Rect2(12, MAP_BOTTOM - 8 - h, BOX_W, h)


func _pager(next: bool) -> Rect2:
	var box := _box()
	return Rect2(box.end.x - 14 - 64 if next else box.position.x + 14, box.end.y - 66, 64, 52)


func _close_rect() -> Rect2:
	var box := _box()
	return Rect2(box.end.x - 14 - 48, box.position.y + 8, 48, 48)


func _click_list(at: Vector2) -> void:
	var box := _box()
	if not box.has_point(at) or _close_rect().has_point(at):
		back()
		return
	if _pages() > 1:
		if _pager(false).has_point(at) and _page > 0:
			_page -= 1
		elif _pager(true).has_point(at) and _page < _pages() - 1:
			_page += 1
	for n in _rows.size():
		if row_rect(n).has_point(at):
			var row := _rows[n]
			if row["kind"] == "office":
				app.open_office(row["office"])
			else:
				app.open_city(row["city"]["id"])
			return
	_over.queue_redraw()


# --- drawing -----------------------------------------------------------------------------------

func _draw() -> void:
	Ui.backdrop(self)


func _draw_over() -> void:
	var groups := _groups_at(_level)
	_draw_labels(groups)
	for k in groups.size():
		_draw_group(groups[k], k == _hot_group)
	if _hot_group >= 0 and _hot_group < groups.size():
		_draw_tip(groups[_hot_group])
	if not _rows.is_empty():
		_draw_list()
	elif Store.offices().is_empty() and _hot_group < 0:
		_draw_hint("Elige una ciudad para tu primera oficina")
	_draw_hud()


# a line at the bottom of the map for a player who has no office yet
func _draw_hint(line: String) -> void:
	var w := Ui.text_width(line, Ui.TEXT, Ui.NARROW) + 28
	var box := Rect2(roundf(300 - w * 0.5), MAP_BOTTOM - 48, roundf(w), 36)
	Ui.chip(_over, box, Ui.VOID, Ui.GOLD_M)
	Ui.text_in(_over, box, line, Ui.TEXT, Ui.CREAM, Ui.NARROW)


func _draw_hud() -> void:
	var cash := Economy.money(app.game.money()) if app != null else ""
	var w := Ui.text_width(cash, Ui.TEXT)
	Ui.coin(_over, MONEY_AT + Vector2(-w - 22, -14))
	Ui.text_right(_over, MONEY_AT, cash, Ui.TEXT, Ui.GOLD)
	if app != null and app.game.income() > 0.0:
		Ui.text_right(_over, MONEY_AT + Vector2(0, 24), "+%s/min" % Economy.money(
			app.game.income()), Ui.SMALL, Ui.MINT)
	Ui.header(_over, "Tiny Realtor", false, hot, MONEY_AT.x - w - 40)
	Ui.arrow(_over, ZOOM_IN, "+", hot, _level == STEP_MAX)
	Ui.arrow(_over, ZOOM_OUT, "-", hot, _level == 0)
	_draw_list_button()
	Ui.footer(_over, "NATURAL EARTH  ZOOM X%d" % (1 << _level))


# a steel square with three pixel lines: the plain list of cities
func _draw_list_button() -> void:
	var over := LIST_BTN.has_point(hot) and _rows.is_empty()
	Ui.plate(_over, LIST_BTN, Ui.STEEL.lightened(Ui.HOT_LIFT) if over else Ui.STEEL,
		Ui.CYAN if over else Ui.RIM_DIM, 15)
	var at := (LIST_BTN.get_center() - Vector2(12, 10)).round()
	for j in 3:
		var y := at.y + j * 8
		_over.draw_rect(Rect2(at.x, y, 4, 4), Ui.CREAM)
		_over.draw_rect(Rect2(at.x + 8, y, 16, 4), Ui.CREAM)


func _draw_group(g: Dictionary, lit: bool) -> void:
	var at: Vector2 = _pan + (g["at"] as Vector2)
	if not _view().grow(24).has_point(at):
		return
	var members: Array = g["members"]
	var offices := 0
	for m: int in members:
		offices += (_places[m]["offices"] as Array).size()
	if members.size() > 1:
		# a group: how many cities; a pin on top when the player has offices among them
		_disc(at, str(members.size()), lit)
		if offices > 0:
			pin(_over, at + Vector2(0, -12), lit)
	elif offices > 0:
		_pin_with_count(at, offices, lit)
	else:
		_sprite_rows(DOT, (at / 2.0).round() * 2.0 - Vector2(4, 4),
			{"1": Ui.CYAN if lit else Ui.CREAM})


func _pin_with_count(tip: Vector2, count: int, lit: bool) -> void:
	pin(_over, tip, lit)
	if count > 0:
		var s := str(count)
		var w := maxf(22.0, Ui.text_width(s, Ui.SMALL, Ui.TEN) + 10.0)
		var r := Rect2((tip + Vector2(6, -32)).round(), Vector2(w, 22))
		Ui.chip(_over, r, Ui.VOID, Ui.GOLD)
		Ui.text_in(_over, r, s, Ui.SMALL, Ui.GOLD, Ui.TEN, false)


# a round steel counter: a group of cities
func _disc(at: Vector2, label: String, lit: bool) -> void:
	var r := 13.0
	var c := (at / 2.0).round() * 2.0
	for y in range(-7, 7):
		for x in range(-7, 7):
			var d := Vector2(x + 0.5, y + 0.5).length() * 2.0
			if d > r + 2.0:
				continue
			var tone := Ui.VOID
			if d <= r - 2.0:
				tone = Ui.STEEL.lightened(Ui.HOT_LIFT) if lit else Ui.STEEL
			elif d <= r:
				tone = Ui.CYAN if lit else Ui.CREAM
			_over.draw_rect(Rect2(c + Vector2(x, y) * 2.0, Vector2(2, 2)), tone)
	Ui.text_in(_over, Rect2(c - Vector2(14, 14), Vector2(28, 28)), label, Ui.SMALL, Ui.CREAM,
		Ui.TEN, false)


# the office's gold map pin (Sprites' office marker) standing on its tip, ink-rimmed, at 2x;
# cyan-rimmed when pointed at
static func pin(c: CanvasItem, tip: Vector2, lit: bool = false) -> void:
	var at := (tip / 2.0).round() * 2.0 - Vector2(10, 22)
	var tone := {"l": Ui.CYAN if lit else Ui.CREAM, "g": Ui.GOLD, "m": Ui.GOLD_M, "H": Ui.SL1}
	_rows_on(c, PIN, at, tone)


func _sprite_rows(rows: Array[String], at: Vector2, tone: Dictionary) -> void:
	_rows_on(_over, rows, at, tone)


# pixel rows at 2x, with a one-art-pixel ink rim round everything drawn
static func _rows_on(c: CanvasItem, rows: Array[String], at: Vector2, tone: Dictionary) -> void:
	for j in rows.size():
		for i in rows[j].length():
			if tone.has(rows[j][i]):
				c.draw_rect(Rect2(at + Vector2(i - 1, j - 1) * 2.0, Vector2(6, 6)), Ui.VOID)
	for j in rows.size():
		for i in rows[j].length():
			if tone.has(rows[j][i]):
				c.draw_rect(Rect2(at + Vector2(i, j) * 2.0, Vector2(2, 2)), tone[rows[j][i]])


# names under the markers where they fit: offices' cities always (gold), the others from x4
func _draw_labels(groups: Array) -> void:
	var placed: Array[Rect2] = [Rect2(ZOOM_IN.position, LIST_BTN.end - ZOOM_IN.position).grow(6)]
	for g: Dictionary in groups:
		placed.append(Rect2(_pan + (g["at"] as Vector2) + Vector2(-12, -26), Vector2(24, 30)))
	for pass_i in 2:
		for g: Dictionary in groups:
			var members: Array = g["members"]
			if members.size() != 1:
				continue
			var p: Dictionary = _places[members[0]]
			var mine := not (p["offices"] as Array).is_empty()
			if (pass_i == 0) != mine or (not mine and _level < 2):
				continue
			var name: String = p["city"]["name"]
			var w := Ui.text_width(name, Ui.SMALL, Ui.TEN)
			var at: Vector2 = _pan + (g["at"] as Vector2) + Vector2(-w * 0.5, 22)
			var box := Rect2(at.x - 4, at.y - 16, w + 8, 22)
			if box.position.y < MAP_TOP or box.end.y > MAP_BOTTOM:
				continue
			var free := true
			for q in placed:
				if q.intersects(box):
					free = false
					break
			if not free:
				continue
			placed.append(box)
			Ui.text(_over, at.round(), name, Ui.SMALL, Ui.GOLD if mine else Ui.MUTED.lightened(0.3),
				Ui.TEN, false)


# the name(s) of what the pointer is on, in a chip above it
func _draw_tip(g: Dictionary) -> void:
	var members: Array = g["members"]
	var line := ""
	if members.size() == 1:
		var p: Dictionary = _places[members[0]]
		var n := (p["offices"] as Array).size()
		line = "%s, %s" % [p["city"]["name"], p["city"]["country"]]
		if n > 0:
			line += " · %d oficina%s" % [n, "" if n == 1 else "s"]
	else:
		var names: Array[String] = []
		for m: int in members:
			names.append(_places[m]["city"]["name"])
		line = ", ".join(names) if names.size() <= 3 else "%s y %d más" % [", ".join(
			names.slice(0, 2)), names.size() - 2]
	var w := Ui.text_width(line, Ui.TEXT, Ui.NARROW) + 24
	var at: Vector2 = _pan + (g["at"] as Vector2)
	var box := Rect2(clampf(at.x - w * 0.5, 8, Ui.CANVAS.x - 8 - w), at.y - 82, w, 36)
	if box.position.y < MAP_TOP + 4:
		box.position.y = at.y + 30
	box.position = box.position.round()
	Ui.chip(_over, box, Ui.VOID, Ui.CYAN)
	Ui.text_in(_over, box, line, Ui.TEXT, Ui.CREAM, Ui.NARROW)


func _draw_list() -> void:
	_over.draw_rect(Rect2(Vector2(0, MAP_TOP), Vector2(Ui.CANVAS.x, MAP_BOTTOM - MAP_TOP)),
		Ui.SHADE)
	var box := _box()
	Ui.panel(_over, box, Ui.GOLD)
	Ui.text(_over, box.position + Vector2(20, 42), _list_title, Ui.TEXT, Ui.CREAM, Ui.NARROW)
	var x := _close_rect()
	var over_x := x.has_point(hot)
	Ui.plate(_over, x, Ui.STEEL.lightened(Ui.HOT_LIFT) if over_x else Ui.STEEL,
		Ui.CYAN if over_x else Ui.RIM_DIM, 15)
	for k in 6:
		for q: Vector2 in [Vector2(k, k), Vector2(5 - k, k)]:
			_over.draw_rect(Rect2(x.get_center() - Vector2(9, 9) + q * 3.0, Vector2(3, 3)),
				Ui.CREAM)
	for n in range(_page * ROWS, mini(_rows.size(), (_page + 1) * ROWS)):
		_draw_row(_rows[n], row_rect(n))
	if _pages() > 1:
		Ui.arrow(_over, _pager(false), "<", hot, _page == 0)
		Ui.arrow(_over, _pager(true), ">", hot, _page >= _pages() - 1)
		var p0 := _pager(false)
		Ui.text_in(_over, Rect2(p0.end.x, p0.position.y, _pager(true).position.x - p0.end.x,
			p0.size.y), "%d / %d" % [_page + 1, _pages()], Ui.TEXT, Ui.MUTED)


func _draw_row(row: Dictionary, r: Rect2) -> void:
	var over := r.has_point(hot)
	var city: Dictionary = row["city"]
	if row["kind"] == "city":
		Ui.plate(_over, r, Ui.SHEET.lightened(0.06) if over else Ui.SHEET,
			Ui.CYAN if over else Ui.RIM_DIM, 13)
		# one city's list: its title names it, the row is the way to its map
		var name: String = "Mapa de la ciudad" if _single else city["name"]
		Ui.text(_over, r.position + Vector2(16, 32), name, Ui.TEXT, Ui.CREAM)
		if not _single:
			Ui.text(_over, r.position + Vector2(28 + Ui.text_width(name, Ui.TEXT), 32),
				city["country"], Ui.SMALL, Ui.MUTED, Ui.TEN)
		var hint := "VER MAPA" if FileAccess.file_exists(Store.city_path(city["id"])) \
			else "DESCARGAR MAPA"
		Ui.micro(_over, Vector2(r.end.x - 16 - Ui.micro_width(hint), r.get_center().y - 5), hint,
			Ui.CYAN if over else Ui.MUTED)
		return
	var o: Dictionary = row["office"]
	var id: String = o["id"]
	var inner := Rect2(r.position + Vector2(28, 0), r.size - Vector2(28, 0))
	Ui.plate(_over, inner, Ui.GOLD_D.lightened(0.08) if over else Ui.GOLD_D,
		Ui.CYAN if over else Ui.GOLD_M, 13)
	pin(_over, inner.position + Vector2(24, 36), over)
	Ui.text(_over, inner.position + Vector2(44, 32), o.get("name", city["name"]), Ui.TEXT,
		Ui.GOLD, Ui.NARROW)
	if app != null and app.game.has_office(id):
		var right := "Nv %d · +%s/min" % [app.game.level(id), Economy.money(app.game.income(id))]
		Ui.text_right(_over, Vector2(inner.end.x - 16, inner.position.y + 31), right, Ui.SMALL,
			Ui.MINT, Ui.TEN)
