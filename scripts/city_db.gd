class_name CityDb
extends RefCounted

# The cities the player can pick, shipped with the game (no live geocoding: Nominatim's rules
# forbid autocomplete). `lat`/`lon` is the middle of the city map box, nudged where the famous
# districts sit off the official centre so they fall inside it (e.g. Tokyo between Shinjuku,
# Shibuya and Ginza). Later this becomes the GeoNames list from docs/DESIGN.md.

const _RAW: Array[Dictionary] = [
	{"id": "barcelona", "name": "Barcelona", "country": "España", "lat": 41.3925, "lon": 2.1650},
	{"id": "madrid", "name": "Madrid", "country": "España", "lat": 40.4220, "lon": -3.6960},
	{"id": "valencia", "name": "Valencia", "country": "España", "lat": 39.4700, "lon": -0.3650},
	{"id": "sevilla", "name": "Sevilla", "country": "España", "lat": 37.3880, "lon": -5.9900},
	{"id": "bilbao", "name": "Bilbao", "country": "España", "lat": 43.2620, "lon": -2.9300},
	{"id": "malaga", "name": "Málaga", "country": "España", "lat": 36.7190, "lon": -4.4250},
	{"id": "lisboa", "name": "Lisboa", "country": "Portugal", "lat": 38.7200, "lon": -9.1450},
	{"id": "paris", "name": "París", "country": "Francia", "lat": 48.8600, "lon": 2.3400},
	{"id": "london", "name": "Londres", "country": "Reino Unido", "lat": 51.5100, "lon": -0.1150},
	{"id": "berlin", "name": "Berlín", "country": "Alemania", "lat": 52.5180, "lon": 13.3950},
	{"id": "roma", "name": "Roma", "country": "Italia", "lat": 41.8980, "lon": 12.4800},
	{"id": "amsterdam", "name": "Ámsterdam", "country": "Países Bajos", "lat": 52.3690,
		"lon": 4.8950},
	{"id": "warszawa", "name": "Varsovia", "country": "Polonia", "lat": 52.2320, "lon": 21.0100},
	{"id": "praha", "name": "Praga", "country": "Chequia", "lat": 50.0830, "lon": 14.4250},
	{"id": "wien", "name": "Viena", "country": "Austria", "lat": 48.2050, "lon": 16.3700},
	{"id": "istanbul", "name": "Estambul", "country": "Turquía", "lat": 41.0300, "lon": 28.9800},
	{"id": "newyork", "name": "Nueva York", "country": "EE. UU.", "lat": 40.7500, "lon": -73.9850},
	{"id": "sanfrancisco", "name": "San Francisco", "country": "EE. UU.", "lat": 37.7800,
		"lon": -122.4200},
	{"id": "chicago", "name": "Chicago", "country": "EE. UU.", "lat": 41.8850, "lon": -87.6350},
	{"id": "mexico", "name": "Ciudad de México", "country": "México", "lat": 19.4250,
		"lon": -99.1550},
	{"id": "buenosaires", "name": "Buenos Aires", "country": "Argentina", "lat": -34.6030,
		"lon": -58.4000},
	{"id": "santiago", "name": "Santiago", "country": "Chile", "lat": -33.4300, "lon": -70.6250},
	{"id": "bogota", "name": "Bogotá", "country": "Colombia", "lat": 4.6400, "lon": -74.0700},
	{"id": "lima", "name": "Lima", "country": "Perú", "lat": -12.1050, "lon": -77.0300},
	{"id": "saopaulo", "name": "São Paulo", "country": "Brasil", "lat": -23.5600,
		"lon": -46.6550},
	{"id": "tokyo", "name": "Tokio", "country": "Japón", "lat": 35.6760, "lon": 139.7300},
	{"id": "seoul", "name": "Seúl", "country": "Corea del Sur", "lat": 37.5450, "lon": 126.9900},
	{"id": "singapore", "name": "Singapur", "country": "Singapur", "lat": 1.2950,
		"lon": 103.8500},
	{"id": "sydney", "name": "Sídney", "country": "Australia", "lat": -33.8750, "lon": 151.2100},
	{"id": "dubai", "name": "Dubái", "country": "Emiratos Árabes", "lat": 25.2000,
		"lon": 55.2700},
]

static var _by_id: Dictionary = {}


static func all() -> Array[Dictionary]:
	return _RAW


static func get_city(id: String) -> Dictionary:
	if _by_id.is_empty():
		for c in _RAW:
			_by_id[c["id"]] = c
	return _by_id.get(id, {})
