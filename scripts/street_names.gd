class_name StreetNames
extends RefCounted

# Street names in the office view: the short form a small widget can show ("Carrer d'Àngel
# Guimerà" -> "ANGEL GUIMERA", "Avinguda del Port" -> "AV. PORT"), in the mockup's 3x5 micro
# font, and where they go. Four looks (Oscar picks one; OfficeView.LABEL_STYLE):
#   MICRO    A: the micro font along the street, sheared to its slope, cream on an ink rim, over
#               the drawing; each name once, the ones nearest the middle of the view first
#   PAINTED  B: painted on the asphalt like road markings, in the drawing itself (AreaBuilder):
#               cars drive over them, trees keep off them, a building in front may hide one;
#               the street under the pointer also gets a plate (as D)
#   PLATES   C: small street-name plates (a dark chip, no shear) on a few streets near the middle,
#               and one on the street under the pointer
#   HOVER    D: no names on the map; a plate with the name of the street under the pointer

enum { MICRO, PAINTED, PLATES, HOVER }
const NAMES: Array[String] = ["A MICRO", "B PINTADO", "C PLACAS", "D AL PASAR"]

# painted names: only on asphalt this wide (m), kept this far from a junction's middle (m) beyond
# the crossing street's half width, the same name at most twice and this far apart (m)
const PAINT_MIN_WIDTH := 8.0
const PAINT_CLEAR := 4.0
const PAINT_EVERY := 120.0
const PAINT_REPEAT := 3
# the colour of painted names: a worn marking, lighter than the asphalt, dimmer than the dashes
const PAINT_INK := "SL5"
# a street steeper than this on screen gets no painted name (it would shear into a staircase)
const SLOPE_MAX := 0.75

const _PREFIX := {"carrer": "", "calle": "", "carreró": "", "rua": "", "rue": "",
	"avinguda": "AV.", "avenida": "AV.", "avenue": "AV.", "plaça": "PL.", "plaza": "PL.",
	"passeig": "PG.", "paseo": "PG.", "ronda": "RDA.", "travessera": "TRAV.", "travesía": "TRAV.",
	"ulica": "UL.", "aleja": "AL."}
const _LINK: Array[String] = ["de les ", "de los ", "de las ", "de la ", "de l'", "de l’", "dels ",
	"del ", "de ", "d'", "d’"]
const _ACCENT := {"À": "A", "Á": "A", "Â": "A", "Ã": "A", "Ä": "A", "Å": "A", "Ç": "C", "È": "E",
	"É": "E", "Ê": "E", "Ë": "E", "Ì": "I", "Í": "I", "Î": "I", "Ï": "I", "Ñ": "N", "Ò": "O",
	"Ó": "O", "Ô": "O", "Õ": "O", "Ö": "O", "Ù": "U", "Ú": "U", "Û": "U", "Ü": "U", "Ý": "Y",
	"·": ".", "ª": "A", "º": "O"}


# the name as the micro font can draw it, its generic word shortened or dropped
static func short(name: String) -> String:
	var s := name.strip_edges()
	var low := s.to_lower()
	for word: String in _PREFIX:
		if low.begins_with(word + " "):
			var rest := s.substr(word.length() + 1)
			for link in _LINK:
				if rest.to_lower().begins_with(link):
					rest = rest.substr(link.length())
					break
			s = (_PREFIX[word] + " " + rest).strip_edges()
			break
	return plain(s)


# capitals the micro font has: accents dropped, anything else it cannot draw left out
static func plain(s: String) -> String:
	var out := ""
	for ch in Ui.caps(s):
		var c: String = _ACCENT.get(ch, ch)
		if Sprites.MICRO.has(c):
			out += c
	return out.strip_edges()


# every named street's nearly straight runs (bends under 12 degrees ignored), longest first:
# [name, a, b, road]
static func runs(block: Dictionary) -> Array:
	var out: Array = []
	for road: Dictionary in block["roads"]:
		var name: String = road["name"] if road["name"] != "" else road.get("ref", "")
		if name == "" or road["kind"] in ["motorway", "trunk"] and road["name"] == "":
			continue
		for seg: Array in straight_runs(AreaBuilder._pts(road["line"])):
			out.append([name, seg[0], seg[1], road])
	out.sort_custom(func(p: Array, q: Array) -> bool:
		return (p[1] as Vector2).distance_to(p[2]) > (q[1] as Vector2).distance_to(q[2]))
	return out


# a polyline cut into nearly straight runs, so a street mapped as many short pieces still offers
# its long stretches for a name
static func straight_runs(line: PackedVector2Array) -> Array:
	var out: Array = []
	if line.size() < 2:
		return out
	var start := line[0]
	var dir := (line[1] - line[0]).normalized()
	for i in range(1, line.size()):
		var d := (line[i] - line[i - 1]).normalized()
		if d.dot(dir) < cos(deg_to_rad(12.0)):
			out.append([start, line[i - 1]])
			start = line[i - 1]
			dir = d
	out.append([start, line[line.size() - 1]])
	return out


# the painted names: [{"text", "seg": [a, b] metres it covers, "box": drawing rect, "ops": ground
# ops}], placed on straight asphalt between junctions (`junctions`: [at, half width of the
# widest street there]); from the streets alone, so they never move when a lot changes
static func painted(block: Dictionary, iso: Iso, radius: float, junctions: Array) -> Array:
	var out: Array = []
	var count := {}
	var o := iso.p(0.0, 0.0)
	for run: Array in runs(block):
		var road: Dictionary = run[3]
		if float(road["width"]) < PAINT_MIN_WIDTH or road["kind"] in ["pedestrian", "footway",
				"steps", "path", "cycleway"]:
			continue
		var name: String = run[0]
		if int(count.get(name, 0)) >= PAINT_REPEAT:
			continue
		var a: Vector2 = run[1]
		var b: Vector2 = run[2]
		var d := (b - a).normalized()
		var sd := iso.p(d.x, d.y) - o
		if sd.x < 0.0:
			var t := a
			a = b
			b = t
			d = -d
			sd = -sd
		if sd.x < 1e-3 or absf(sd.y / sd.x) > SLOPE_MAX:
			continue
		var text := short(name)
		if text.length() < 2:
			continue
		var w := Sprites.micro_w(text)
		var half := w * 0.5 / sd.x + 1.0
		var slope := sd.y / sd.x
		var length := a.distance_to(b)
		if length < half * 2.0 + PAINT_CLEAR * 2.0:
			continue
		# the free spot nearest the run's middle
		var best := Vector2.INF
		var best_d := INF
		var t := half
		while t <= length - half:
			var c := a + d * t
			var off := absf(t - length * 0.5)
			t += 3.0
			if off >= best_d or c.length() > radius - 12.0 - half:
				continue
			if _blocked(c, d, half, float(road["width"]), name, junctions, out):
				continue
			best = c
			best_d = off
		if best == Vector2.INF:
			continue
		count[name] = int(count.get(name, 0)) + 1
		out.append({"text": text, "name": name, "seg": [best - d * half, best + d * half],
			"ops": _paint(text, iso.pv(best).round(), slope),
			"box": _box(iso.pv(best).round(), w, slope)})
	return out


# the drawing rect a painted name covers
static func _box(at: Vector2, w: int, slope: float) -> Rect2:
	var lift := absf(w * 0.5 * slope)
	return Rect2(at.x - floori(w * 0.5), at.y - 2.0 - lift, w, 5.0 + lift * 2.0 + 1.0)


static func _blocked(c: Vector2, d: Vector2, half: float, width: float, name: String,
		junctions: Array, placed: Array) -> bool:
	var a := c - d * half
	var b := c + d * half
	for j: Array in junctions:
		var at: Vector2 = j[0]
		var q := Geometry2D.get_closest_point_to_segment(at, a, b)
		if q.distance_to(at) < float(j[1]) + PAINT_CLEAR:
			return true
	for p: Dictionary in placed:
		var pa: Vector2 = p["seg"][0]
		var pb: Vector2 = p["seg"][1]
		var gap := Geometry2D.get_closest_points_between_segments(a, b, pa, pb)
		var apart := (gap[0] as Vector2).distance_to(gap[1])
		if apart < width + 6.0 or p["name"] == name and apart < PAINT_EVERY:
			return true
	return false


# the text's pixels as ground ops: one column of a letter at a time, each column lowered by the
# street's slope so the letters keep their vertical strokes and lean along the street
static func _paint(text: String, at: Vector2, slope: float) -> Array:
	var px := {}
	var w := Sprites.micro_w(text)
	Sprites.micro(px, 0, 0, text, Pal.i(PAINT_INK))
	var cols := {}
	for q: Vector2i in px:
		if not cols.has(q.x):
			cols[q.x] = []
		cols[q.x].append(q.y)
	var ops: Array = []
	for x: int in cols:
		var ys: Array = cols[x]
		ys.sort()
		var dx := x - floori(w * 0.5)
		var lift := roundf(dx * slope)
		var y0: int = ys[0]
		var prev: int = ys[0]
		for k in range(1, ys.size() + 1):
			if k < ys.size() and int(ys[k]) == prev + 1:
				prev = ys[k]
				continue
			ops.append([Painter.OP_RECT, Rect2(at + Vector2(dx, y0 - 2 + lift),
				Vector2(1, prev - y0 + 1)), Pal.i(PAINT_INK)])
			if k < ys.size():
				y0 = ys[k]
				prev = ys[k]
	return ops
