class_name Economy
extends RefCounted

# Every number of the game in one place (docs/GAMEPLAY.md explains the why), plus what a lot is
# worth: its rent and price multipliers from real data (size, parks, avenues, water, rails,
# zone) and the highest tier it can take. tools/econ_sim.gd plays these tables and prints how
# long each milestone takes; tune here, then re-run it.

const TIER_NAMES: Array[String] = ["Solar", "Casas", "Urbanización", "Bloque de pisos", "Torres",
	"Rascacielos"]
# cost of building tier t from tier t - 1, for a lot of area factor 1 ($)
const BUILD_COST: Array[float] = [0.0, 15e3, 150e3, 2e6, 40e6, 800e6]
# seconds the works take
const BUILD_TIME: Array[float] = [0.0, 20.0, 120.0, 600.0, 2700.0, 10800.0]
# rent per minute of a finished tier, area factor 1 ($)
const RENT: Array[float] = [0.0, 10e3, 35e3, 120e3, 400e3, 1.4e6]
# an empty lot (solar) of area factor 1 ($)
const LAND := 20e3
# a lot that is already built costs its land, plus what building it would cost, plus this much
# for skipping the works and the cranes
const PREBUILT_MARKUP := 1.25
# the neighbourhood gets dearer as you buy it: every lot you own in an office puts this much on
# the price of the rest (plusvalía)
const PLUSVALIA := 0.04
# and every works finished in an office makes the next ones there dearer (busier builders)
const WORKS_INFLATION := 0.01
# lot area (m2) that has factor 1; the factor grows slower than the area, within these bounds
const AREA_UNIT := 4000.0
const AREA_EXP := 0.75
const AREA_MIN := 0.35
const AREA_MAX := 1.6
# what the price feels of a lot's location bonus, against what its rent gets
const PRICE_OF_MODS := 0.5

# per office level (level 1 first): what reaching the next level costs, the office's own income
# per minute (its commissions: the office is a business, not a building, and earns on its
# neighbourhood), how many works can run at once, and the offline earnings cap (hours)
const LEVEL_COST: Array[float] = [60e3, 15e6, 8e9, 250e9]
const OFFICE_INCOME: Array[float] = [2e3, 12e3, 60e3, 300e3, 1.5e6]
const CRANES: Array[int] = [1, 2, 2, 3, 3]
const OFFLINE_HOURS: Array[float] = [12.0, 14.0, 16.0, 20.0, 24.0]
const START_MONEY := 35e3
# the lot where the office is placed is the player's from the start, free, as an ordinary lot
# at this tier (a solar: the first build is on it)
const OFFICE_LOT_TIER := 0
# a later office: what it costs, and the level some office must have reached first
const OFFICE_COST: Array[float] = [0.0, 3e9, 300e9, 10e12]
const OFFICE_NEEDS_LEVEL := 3

# the bank (docs/GAMEPLAY.md "Banco"): three kinds of loan, one of each at a time. A loan can
# never choke you: its interest is added to the debt (never taken from your cash), all the
# interest together is cut to INTEREST_CAP of your rent at that moment (so it can never pass your
# income, even if the rent drops), a loan only grows to GROWTH_CAP times what was lent, and a new
# loan is refused when the interest of all of them would pass AFFORD of your rent. Each loan pays
# its fee up front, so borrowing and repaying at once only loses money. Interest runs offline too,
# but only for the hours that also earn rent. AUTOPAY sends a share of every rent to the debt.
# LOANS: name, fee, interest per hour, most you may borrow in minutes of rent, and the share of
# your lots' worth it may reach (0 = no limit)
const LOANS: Array[Dictionary] = [
	{"id": "quick", "name": "Rápido", "fee": 0.01, "rate_h": 0.03, "minutes": 30.0, "assets": 0.0},
	{"id": "normal", "name": "Normal", "fee": 0.03, "rate_h": 0.012, "minutes": 180.0,
		"assets": 0.0},
	{"id": "mortgage", "name": "Hipoteca", "fee": 0.05, "rate_h": 0.0035, "minutes": 900.0,
		"assets": 0.5},
]
const AFFORD := 0.06
const INTEREST_CAP := 0.08
const GROWTH_CAP := 1.5
const AUTOPAY: Array[float] = [0.0, 0.10, 0.25, 0.50]
const LOAN_MIN := 1000.0

# managers: one per office, from level MANAGER_LEVEL (the first one comes free with it); a pool
# of POOL_SIZE candidates per office, a new pool every POOL_HOURS, or now for REFRESH_MINUTES of
# rent (doubling each time within the same pool's hours)
const MANAGER_LEVEL := 2
const POOL_SIZE := 3
const POOL_HOURS := 6.0
const REFRESH_MINUTES := 10.0
const RARITY_NAMES: Array[String] = ["Común", "Rara", "Épica", "Legendaria"]
# hire price: minutes of your whole rent by rarity, never under a floor by office level times
# the rarity's factor (so a manager is never a bargain kept forever)
const HIRE_MINUTES: Array[float] = [30.0, 90.0, 300.0, 900.0]
const HIRE_BASE: Array[float] = [40e3, 300e3, 6e6, 150e6, 3e9]
const HIRE_RARITY: Array[float] = [1.0, 3.0, 10.0, 40.0]
# the office's builder ("piloto automático"), from this level: when a crane is free it starts the
# best-paying next tier on one of your lots, spending at most AUTO_SHARE of the cash, also offline
const AUTO_LEVEL := 3
const AUTO_SHARE := 0.5
# chance of each rarity in a fresh pool, by office level
const POOL_ODDS: Array = [[1.0, 0.0, 0.0, 0.0], [0.70, 0.25, 0.05, 0.0],
	[0.55, 0.32, 0.11, 0.02], [0.42, 0.35, 0.18, 0.05], [0.30, 0.35, 0.25, 0.10]]
# traits by rarity (common, rare, epic, legendary); a common has one, a rare one stronger, an
# epic two, a legendary two plus one of the special ones
const TRAITS := {
	"rent": {"name": "Alquiler", "fmt": "+%d%% alquiler", "v": [0.10, 0.20, 0.30, 0.45]},
	"cost": {"name": "Obras baratas", "fmt": "-%d%% coste de obra", "v": [0.10, 0.15, 0.25, 0.35]},
	"time": {"name": "Obras rápidas", "fmt": "-%d%% tiempo de obra", "v": [0.15, 0.25, 0.40, 0.50]},
	"land": {"name": "Regateo", "fmt": "-%d%% precio de compra", "v": [0.10, 0.15, 0.25, 0.35]},
	"offline": {"name": "Vigilante", "fmt": "+%d h sin conexión", "v": [2.0, 4.0, 8.0, 12.0]},
	"interest": {"name": "Banquero", "fmt": "-%d%% interés, más préstamo",
		"v": [0.15, 0.25, 0.40, 0.60]},
	"crane": {"name": "Capataz", "fmt": "+%d grúa", "v": [1.0, 1.0, 1.0, 1.0]},
	"deals": {"name": "Ofertas", "fmt": "+%d%% eventos", "v": [0.15, 0.25, 0.40, 0.60]},
	"handy": {"name": "Mañoso", "fmt": "+%d%% encargos", "v": [0.15, 0.25, 0.40, 0.60]},
}
const COMMON_TRAITS: Array[String] = ["rent", "cost", "time", "land", "offline", "interest",
	"deals", "handy"]
const SPECIAL_TRAITS: Array[String] = ["crane"]
const FIRST_NAMES: Array[String] = ["Lola", "Paco", "Marisa", "Toni", "Carmen", "Julián", "Rosa",
	"Nacho", "Pilar", "Quique", "Maite", "Andrés", "Inés", "Rafa", "Elena", "Jordi", "Nuria",
	"Héctor", "Amparo", "Vicente", "Sofía", "Óscar", "Lucía", "Mateo", "Aitana", "Bruno"]
const LAST_NAMES: Array[String] = ["Martín", "Ferrer", "Soler", "Navarro", "Iglesias", "Ruiz",
	"Vidal", "Castro", "Ortega", "Gil", "Romero", "Peris", "Llopis", "Torres", "Molina", "Blasco",
	"Serrano", "Campos", "Marín", "Bosch"]

# events (docs/GAMEPLAY.md "Eventos"): short offers and tenant jobs that only turn up while you
# are looking at the game, so playing actively speeds you up without an idle player losing
# anything. Every reward is minutes of your income at that moment (so it stays worth it all
# game), and all of them together take at most EVENT_HOUR_CAP minutes an hour (a bucket that
# fills back at that pace, also while away): an active player goes about twice the idle pace,
# never ten times. Times are seconds of active play (window focused or the pointer moving).
# active seconds between one event ending and the next one, and how long an event waits for you
const EVENT_WAIT: Array[float] = [60.0, 180.0]
const EVENT_LIFE: Array[float] = [60.0, 120.0]
# nothing makes sense right now (nothing to buy, no rent yet): look again this much later
const EVENT_RETRY := 30.0
const EVENT_HOUR_CAP := 20.0
# a new game's bucket: the first minutes grow fastest, so they start with little in it
const EVENT_START := 2.0
# how often each kind is picked among the ones that make sense now
const EVENT_WEIGHT := {"sale": 3.0, "express": 2.0, "vip": 2.0, "buyer": 1.0, "job": 4.0}
# "Solar en oferta": a lot for sale in the radius at a discount for the event's life; worth at
# least SALE_MIN and at most SALE_MAX minutes of income, on a lot whose full price is within
# SALE_REACH minutes of income of your cash (it saves money on what you would buy soon anyway;
# a bargain far beyond your means would skip the game ahead)
const SALE_CUTS: Array[float] = [0.3, 0.4, 0.5]
const SALE_MIN := 0.5
const SALE_MAX := 6.0
const SALE_REACH := 2.0
# "Obra exprés": accepted, the next works you start in that office within EXPRESS_WINDOW s take
# EXPRESS_CUT less time (at most EXPRESS_MAX_S saved); offered when some works of at least
# EXPRESS_MIN_S can be started now
const EXPRESS_CUT := 0.5
const EXPRESS_WINDOW := 120.0
const EXPRESS_MAX_S := 1800.0
const EXPRESS_MIN_S := 60.0
# "Inquilino VIP": one of your buildings pays VIP_X its rent for VIP_S, shortened so the extra
# is at most VIP_MAX minutes of income (and no offer under VIP_MIN_S)
const VIP_X := 2.0
const VIP_S := 600.0
const VIP_MIN_S := 120.0
const VIP_MAX := 4.0
# "Comprador con prisa": cash now, between these minutes of income
const BUYER_MIN: Array[float] = [2.0, 4.0]
# tenant jobs (the minigames): JOB_MIN minutes of income for a perfect job, a partial one pays in
# proportion, and even a failed one pays JOB_FAIL of it; JOB_S seconds to play
const JOB_MIN := 4.0
const JOB_FAIL := 0.15
const JOB_S := 15.0
const JOB_GAMES: Array[String] = ["plunge", "wires", "bulbs"]

# location bonuses from the real map: [name on the card, share of extra rent]
const MOD_PARK := ["Parque cerca", 0.20]
const MOD_AVENUE := ["Avenida", 0.15]
const MOD_WATER := ["Vistas al agua", 0.25]
const MOD_SHOPS := ["Zona comercial", 0.15]
const MOD_RAIL := ["Junto a las vías", -0.15]
const AVENUES := ["motorway", "trunk", "primary", "secondary"]
# metres beyond the lot's half size within which a park, water or a rail line counts as next door
const PARK_REACH := 30.0
const WATER_REACH := 60.0
const RAIL_REACH := 15.0


static func max_level() -> int:
	return OFFICE_INCOME.size()


static func level_cost(level: int) -> float:
	return LEVEL_COST[level - 1] if level < max_level() else INF


static func office_income(level: int) -> float:
	return OFFICE_INCOME[clampi(level, 1, max_level()) - 1]


static func cranes(level: int) -> int:
	return CRANES[clampi(level, 1, max_level()) - 1]


static func offline_hours(level: int) -> float:
	return OFFLINE_HOURS[clampi(level, 1, max_level()) - 1]


static func area_factor(area_m2: float) -> float:
	return clampf(pow(maxf(area_m2, 1.0) / AREA_UNIT, AREA_EXP), AREA_MIN, AREA_MAX)


# --- lots ------------------------------------------------------------------------------------------

# one entry per plot of a baked area (same order): {"id", "zone", "area", "a" (area factor),
# "mods" ([name, share] pairs), "rent_k", "price_k" (multipliers), "max_tier", "base_tier"}
static func lot_infos(block: Dictionary) -> Array[Dictionary]:
	var avenues := {}
	for r: Dictionary in block.get("roads", []):
		if r["kind"] in AVENUES and r.get("name", "") != "":
			avenues[r["name"]] = true
	var greens: Array = []
	for g: Dictionary in block.get("greens", []):
		if g["kind"] in ["sand", "beach"]:
			continue
		var poly := _pts(g["poly"])
		greens.append([poly, Geo.bounds(poly)])
	var waters: Array = []
	for w: Dictionary in block.get("water", []):
		var poly := _pts(w["poly"])
		waters.append([poly, Geo.bounds(poly)])
	var rails: Array = []
	for r: Dictionary in block.get("rails", []):
		if r["kind"] != "tram":
			var line := _pts(r["line"])
			rails.append([line, Geo.bounds(line)])
	var out: Array[Dictionary] = []
	for p: Dictionary in block["plots"]:
		var poly := _pts(p["poly"])
		var area := float(p.get("area_m2", absf(Geo.area(poly))))
		var c := Iso.centroid(poly)
		var half := sqrt(area) * 0.5
		var mods: Array = []
		if _near(c, half + PARK_REACH, greens, true):
			mods.append(MOD_PARK)
		var on_avenue := false
		for s: String in p.get("streets", []):
			on_avenue = on_avenue or avenues.has(s)
		if on_avenue:
			mods.append(MOD_AVENUE)
		if _near(c, half + WATER_REACH, waters, true):
			mods.append(MOD_WATER)
		if p["zone"] == "commercial":
			mods.append(MOD_SHOPS)
		if _near(c, half + RAIL_REACH, rails, false):
			mods.append(MOD_RAIL)
		var sum := 0.0
		for m: Array in mods:
			sum += float(m[1])
		var a := area_factor(area)
		out.append({"id": p["id"], "zone": p["zone"], "area": area, "a": a, "mods": mods,
			"rent_k": a * (1.0 + sum), "price_k": a * (1.0 + sum * PRICE_OF_MODS),
			"max_tier": max_tier(p["zone"], area), "base_tier": int(p.get("built_tier", 0)),
			"dist": c.length()})
	return out


# industrial zones stop at sheds until rezoning exists; towers and skyscrapers need room
static func max_tier(zone: String, area: float) -> int:
	if zone == "industrial":
		return 2
	if area < 1500.0:
		return 3
	if area < 3000.0:
		return 4
	return 5


static func rent(tier: int, info: Dictionary) -> float:
	return RENT[clampi(tier, 0, 5)] * float(info["rent_k"])


static func land_price(info: Dictionary) -> float:
	return LAND * float(info["price_k"])


static func build_cost(tier: int, info: Dictionary) -> float:
	return BUILD_COST[clampi(tier, 0, 5)] * float(info["price_k"])


# what a lot costs as it stands: its land, and its buildings at a markup for skipping the works
static func buy_price(info: Dictionary, tier: int) -> float:
	var p := land_price(info)
	for t in range(1, tier + 1):
		p += build_cost(t, info) * PREBUILT_MARKUP
	return p


# what a lot is worth to the bank: its land and what its buildings cost to put up
static func worth(info_k: float, tier: int) -> float:
	var p := LAND * info_k
	for t in range(1, tier + 1):
		p += BUILD_COST[t] * info_k
	return p


static func loan_def(id: String) -> Dictionary:
	for l in LOANS:
		if l["id"] == id:
			return l
	return {}


# --- managers --------------------------------------------------------------------------------------

static func hire_cost(level: int, rarity: int, income: float) -> float:
	var r := clampi(rarity, 0, 3)
	return maxf(HIRE_BASE[clampi(level, 1, max_level()) - 1] * HIRE_RARITY[r],
		HIRE_MINUTES[r] * income)


static func refresh_cost(level: int, income: float, times: int) -> float:
	return maxf(HIRE_BASE[clampi(level, 1, max_level()) - 1] * 0.5,
		REFRESH_MINUTES * income) * pow(2.0, times)


# a manager made from a seed and the office level: name, face seed, rarity, traits
static func make_manager(seed: int, level: int, first: bool = false) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var odds: Array = POOL_ODDS[clampi(level, 1, max_level()) - 1]
	var roll := rng.randf()
	var rarity := 0
	var acc := 0.0
	for k in odds.size():
		acc += float(odds[k])
		if roll < acc:
			rarity = k
			break
	if first:
		rarity = 0
	var picks: Array[String] = []
	var pool := COMMON_TRAITS.duplicate()
	if first:
		pool = ["rent"]
	var n := 2 if rarity >= 2 else 1
	for _i in n:
		var t: String = pool[rng.randi() % pool.size()]
		pool.erase(t)
		picks.append(t)
	if rarity == 3:
		picks.append(SPECIAL_TRAITS[rng.randi() % SPECIAL_TRAITS.size()])
	var traits: Array = []
	for t in picks:
		traits.append({"k": t, "v": float(TRAITS[t]["v"][rarity])})
	var name := "%s %s" % [FIRST_NAMES[rng.randi() % FIRST_NAMES.size()],
		LAST_NAMES[rng.randi() % LAST_NAMES.size()]]
	return {"name": name, "face": rng.randi() & 0xFFFFFF, "rarity": rarity, "traits": traits,
		"level": level}


# a manager's bonus of one kind (0 when none, or no manager)
static func trait_of(manager: Variant, kind: String) -> float:
	if not manager is Dictionary:
		return 0.0
	var sum := 0.0
	for t: Dictionary in manager.get("traits", []):
		if t["k"] == kind:
			sum += float(t["v"])
	return sum


static func trait_text(t: Dictionary) -> String:
	var def: Dictionary = TRAITS[t["k"]]
	var v := float(t["v"])
	var fmt: String = def["fmt"]
	if not "%" in fmt:
		return fmt
	if fmt.contains("%%"):
		return fmt % roundi(v * 100.0)
	return fmt % roundi(v)


# --- text ------------------------------------------------------------------------------------------

# "$12.345", "$123,4K", "$1,23M", "$45,6MM", "$7,1B" (Spanish decimal comma; MM = mil
# millones, B = billón, a million millions, as Spanish counts)
static func money(amount: float) -> String:
	var neg := amount < 0.0
	var a := absf(amount)
	var s := ""
	if a < 100000.0:
		s = "$" + _dots(floori(a))
	else:
		var units: Array[String] = ["K", "M", "MM", "B", "MB"]
		var k := 0
		a /= 1000.0
		while a >= 1000.0 and k < units.size() - 1:
			a /= 1000.0
			k += 1
		var txt := "%.2f" % a if a < 10.0 else ("%.1f" % a if a < 100.0 else "%d" % floori(a))
		s = "$" + txt.replace(".", ",") + units[k]
	return ("-" if neg else "") + s


# "45 s", "12 min", "3 h 20 min", "2 d 4 h" (one style everywhere: no "m:ss")
static func duration(seconds: float) -> String:
	var s := maxi(0, ceili(seconds))
	if s < 60:
		return "%d s" % s
	if s < 3600:
		return "%d min" % ceili(s / 60.0)
	if s < 86400:
		var h := s / 3600
		var m := (s % 3600) / 60
		return "%d h %d min" % [h, m] if m > 0 else "%d h" % h
	return "%d d %d h" % [s / 86400, (s % 86400) / 3600]


static func _dots(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "." + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


static func _near(c: Vector2, reach: float, shapes: Array, filled: bool) -> bool:
	for sh: Array in shapes:
		var box: Rect2 = sh[1]
		if not box.grow(reach).has_point(c):
			continue
		var pts: PackedVector2Array = sh[0]
		if filled and pts.size() >= 3 and Geometry2D.is_point_in_polygon(c, pts):
			return true
		var n := pts.size()
		var last := n if filled else n - 1
		for i in last:
			var q := Geometry2D.get_closest_point_to_segment(c, pts[i], pts[(i + 1) % n])
			if q.distance_to(c) <= reach:
				return true
	return false


static func _pts(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for q: Array in raw:
		out.append(Vector2(q[0], q[1]))
	return out
