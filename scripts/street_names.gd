class_name StreetNames
extends RefCounted

# Street names in the office view. Nothing is written on the map: clicking a street, a pavement
# or any open ground shows a plate with the name of the street nearest the click and what kind of
# street it is (OfficeView). `short()` is the form a small widget can show ("Carrer d'Àngel
# Guimerà" -> "ANGEL GUIMERA", "Avinguda del Port" -> "AV. PORT") in the mockup's 3x5 micro font.

# what a street is called in Spanish, by the generic word its name starts with
const _KIND := {"carrer": "Calle", "calle": "Calle", "carreró": "Callejón", "rua": "Calle",
	"rue": "Calle", "ulica": "Calle", "avinguda": "Avenida", "avenida": "Avenida",
	"avenue": "Avenida", "aleja": "Avenida", "plaça": "Plaza", "plaza": "Plaza",
	"passeig": "Paseo", "paseo": "Paseo", "ronda": "Ronda", "travessera": "Travesía",
	"travesía": "Travesía", "camí": "Camino", "camino": "Camino", "gran": "Gran Vía",
	"pont": "Puente", "puente": "Puente", "bulevard": "Bulevar", "bulevar": "Bulevar"}
# a click names the street whose kerb is at most this far (m) beyond its half width
const REACH := 7.0

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


# what kind of street a road is, in Spanish: from its name's generic word, else from its OSM kind
static func kind(road: Dictionary) -> String:
	var low := String(road.get("name", "")).strip_edges().to_lower()
	var first := low.get_slice(" ", 0)
	if _KIND.has(first):
		if first == "gran" and not low.begins_with("gran via") and not low.begins_with("gran vía"):
			return "Calle"
		return _KIND[first]
	match String(road.get("kind", "")):
		"motorway", "trunk":
			return "Autovía"
		"pedestrian", "footway", "living_street":
			return "Calle peatonal"
		"primary", "secondary":
			return "Avenida" if float(road.get("width", 0.0)) >= 18.0 else "Calle"
	return "Calle"


# the road nearest a ground point (m) whose kerb is within REACH of it, {} for none:
# {"road", "at" (the nearest point on its line), "name" (its name, its ref, or "")}
static func nearest(block: Dictionary, p: Vector2) -> Dictionary:
	var best := {}
	var best_d := INF
	for road: Dictionary in block["roads"]:
		var line := AreaBuilder._pts(road["line"])
		var half := float(road["width"]) * 0.5
		for i in range(1, line.size()):
			var q := Geometry2D.get_closest_point_to_segment(p, line[i - 1], line[i])
			var d := q.distance_to(p) - half
			if d < best_d and d <= REACH:
				best_d = d
				var name: String = road["name"] if road["name"] != "" else road.get("ref", "")
				best = {"road": road, "at": q, "name": name}
	return best
