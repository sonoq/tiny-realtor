class_name Game
extends RefCounted

# The player's game: money, the bank, and per office its level, lots, works and manager; the
# rules that change them (buy, build, level up, borrow, repay, hire) and the clock that pays the
# rent. Plain data, no nodes: App keeps one, the tools make their own with a fake clock (`clock`).
# Saved as JSON under user:// through Store (temp file + rename), see docs/GAMEPLAY.md "Partida".
#
# Time: `advance(now)` pays everything between the last time seen and now, piecewise: works that
# finish in between start paying from their end time. A gap longer than AWAY_GAP (the game was
# closed, or the computer slept) is "away": rent and interest only run for the offline cap's
# hours of it, works finish anyway, and `away` keeps a summary for the welcome-back card. A clock
# that went backwards pays nothing until it is past the last time seen again.

const FORMAT := "tiny-realtor-save"
const VERSION := 1
const AWAY_GAP := 120.0
# money and debt move in steps no longer than this while a loan runs (interest, autopay)
const BANK_STEP := 60.0
# with an office's builder on, time away is looked at this often for cranes to fill
const AUTO_STEP := 300.0

var path := ""
var state: Dictionary = {}
# seconds since the epoch; tools swap it for a fake clock
var clock: Callable = func() -> float: return Time.get_unix_time_from_system()
# seconds of a timer that never goes back (the engine's), for when the wall clock does
var mono: Callable = func() -> float: return Time.get_ticks_msec() / 1000.0
var _last_now := -1.0
var _last_mono := 0.0
# the last away summary, {} once shown: seconds, paid_s (seconds that earned), money, built,
# interest, repaid
var away: Dictionary = {}
# one-line news for the screen (a free manager arrived...), taken by whoever shows them
var news: Array[String] = []
# works the office's builder started on its own since the screen last looked: {"office", "lot"}
var auto_started: Array[Dictionary] = []


func _init(save_path: String = "") -> void:
	path = save_path


# the wall clock, except when it goes back: then the game keeps its own time from the last
# reading, so play goes on and nothing is paid twice (offline credit only past `seen`)
func now() -> float:
	var w := float(clock.call())
	var m := float(mono.call())
	var t := w
	if _last_now >= 0.0 and w < _last_now - 1.0:
		t = _last_now + maxf(0.0, m - _last_mono)
	elif _last_now >= 0.0:
		t = maxf(w, _last_now)
	_last_now = t
	_last_mono = m
	return t


static func save_path() -> String:
	return "user://save_fixture.json" if Overpass.fixture_mode else "user://save.json"


# --- save ----------------------------------------------------------------------------------------

func fresh(t: float) -> void:
	state = {"format": FORMAT, "version": VERSION, "money": Economy.START_MONEY, "seen": t,
		"created": t, "last_office": "", "autopay": 0.10, "loans": {}, "offices": {},
		"stats": {"earned": 0.0, "interest": 0.0, "fees": 0.0, "repaid": 0.0, "built": 0,
			"bought": 0}}


# reads the save, or the temp file of an interrupted write, or the last good backup; when a
# save exists but none of them can be read, it is kept aside (save.corrupt-<time>.json) before a
# new game starts, so nothing is ever overwritten blind. Then it pays the time away
func load_or_new() -> Array[Dictionary]:
	var t := now()
	if path != "":
		for p in [path, path + ".tmp", path + ".bak"]:
			var data: Variant = Store.read_json(p)
			if data is Dictionary and data.get("format") == FORMAT \
					and _num_ok(data.get("version")) and int(data["version"]) >= 1:
				state = data
				_sanitize(t)
				if p != path:
					push_warning("Game: save restored from " + p)
				return advance(t)
		if FileAccess.file_exists(path):
			var keep := "%s.corrupt-%d.json" % [path.get_basename(), int(t)]
			DirAccess.copy_absolute(path, keep)
			push_warning("Game: unreadable save kept as %s, starting a new game" % keep)
	fresh(t)
	return []


func save() -> void:
	if path == "":
		return
	# never write a number JSON cannot read back
	if not _num_ok(state.get("money")):
		state["money"] = 0.0
	Store.write_json(path, state, true)


# a save from a newer clock (seen far in the future) or with odd numbers is made sane
func _sanitize(t: float) -> void:
	state["money"] = maxf(0.0, float(state["money"])) if _num_ok(state.get("money")) else 0.0
	# a save from the future (the clock was moved back) keeps its time: nothing is paid until
	# the clock passes it again, so moving the clock back and forth never pays twice
	var seen := float(state["seen"]) if _num_ok(state.get("seen")) else t
	state["seen"] = seen
	_last_now = maxf(t, seen)
	for key: String in ["loans", "offices", "stats"]:
		if not state.get(key) is Dictionary:
			state[key] = {}
	state["autopay"] = _snap_autopay(float(state["autopay"]) if _num_ok(state.get("autopay"))
		else 0.10)
	# anything malformed is dropped rather than allowed to crash the game later
	for kind: String in state["loans"].keys():
		var ln: Variant = state["loans"][kind]
		if not ln is Dictionary or Economy.loan_def(kind).is_empty() \
				or not _num_ok(ln.get("debt")) or not _num_ok(ln.get("lent")) \
				or float(ln["debt"]) <= 0.0:
			state["loans"].erase(kind)
	for id: String in state["offices"].keys():
		var o: Variant = state["offices"][id]
		if not o is Dictionary:
			state["offices"].erase(id)
			continue
		o["level"] = clampi(int(o.get("level", 1)) if _num_ok(o.get("level")) else 1, 1,
			Economy.max_level())
		o["works"] = maxi(0, int(o.get("works", 0)) if _num_ok(o.get("works")) else 0)
		if not o.get("lots") is Dictionary:
			o["lots"] = {}
		if not (o.get("manager") is Dictionary and o["manager"].get("traits") is Array):
			o["manager"] = null
		if not o.get("pool") is Dictionary or not _num_ok(o["pool"].get("at")):
			o["pool"] = {"n": 0, "at": t}
		for lid: String in o["lots"].keys():
			var l: Variant = o["lots"][lid]
			var ok: bool = l is Dictionary and _num_ok(l.get("t")) and (l.get("office", false)
				or _num_ok(l.get("k")) and _num_ok(l.get("mx")) and _num_ok(l.get("pk", 1.0)))
			# works with a missing or odd time are simply forgotten (the lot keeps its tier)
			if ok and (l.has("end") or l.has("to")) and not (_num_ok(l.get("end"))
					and _num_ok(l.get("to")) and _num_ok(l.get("start"))):
				l.erase("to")
				l.erase("end")
				l.erase("start")
			if not ok:
				o["lots"].erase(lid)
				continue
			l["t"] = clampi(int(l["t"]), 0, 5)
			if not l.get("office", false):
				l["mx"] = clampi(int(l["mx"]), int(l["t"]), 5)
			if l.has("to") and int(l["to"]) <= int(l["t"]):
				l.erase("to")
				l.erase("end")
				l.erase("start")
			elif l.has("to"):
				l["to"] = mini(int(l["to"]), 5)


static func _num_ok(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))


# --- offices -------------------------------------------------------------------------------------

func offices() -> Dictionary:
	return state["offices"]


func office(id: String) -> Dictionary:
	return state["offices"].get(id, {})


func has_office(id: String) -> bool:
	return state["offices"].has(id)


# a new office starts at level 1 with its own lot owned, free
func add_office(id: String, office_lot: String) -> void:
	if has_office(id):
		return
	var o := {"level": 1, "office_lot": office_lot, "lots": {}, "manager": null,
		"pool": {"n": 0, "at": now()}}
	if office_lot != "":
		o["lots"][office_lot] = {"t": 3, "k": 0.0, "pk": 1.0, "mx": 3, "office": true}
	state["offices"][id] = o


func level(id: String) -> int:
	return int(office(id).get("level", 1))


func radius(id: String) -> float:
	return Rules.active_radius(level(id))


func manager(id: String) -> Variant:
	return office(id).get("manager")


func lot(id: String, lot_id: String) -> Dictionary:
	return office(id).get("lots", {}).get(lot_id, {})


func owns(id: String, lot_id: String) -> bool:
	return office(id).get("lots", {}).has(lot_id)


func owned_count(id: String) -> int:
	return office(id).get("lots", {}).size()


func money() -> float:
	return float(state["money"])


# what a later office costs, or INF while no office is at the level it needs
func next_office_cost() -> float:
	var n := offices().size()
	if n >= Economy.OFFICE_COST.size():
		return INF
	if n == 0:
		return 0.0
	var best := 0
	for id: String in offices():
		best = maxi(best, level(id))
	return Economy.OFFICE_COST[n] if best >= Economy.OFFICE_NEEDS_LEVEL else INF


func can_open_office() -> String:
	var cost := next_office_cost()
	if offices().is_empty():
		return ""
	if offices().size() >= Economy.OFFICE_COST.size():
		return "No caben más oficinas"
	if cost == INF:
		return "Necesitas una oficina de Nv %d" % Economy.OFFICE_NEEDS_LEVEL
	if money() < cost:
		return "Te faltan " + Economy.money(cost - money())
	return ""


# takes the next office's price now (0 for the first); returns what was paid
func pay_office() -> float:
	if can_open_office() != "":
		return 0.0
	var cost := next_office_cost()
	if not is_finite(cost) or cost <= 0.0:
		return 0.0
	state["money"] = money() - cost
	return cost


# --- income --------------------------------------------------------------------------------------

# a manager's cut of one kind (cost, time, land, interest), never a whole 100 %
func cut(id: String, kind: String) -> float:
	return clampf(Economy.trait_of(manager(id), kind), 0.0, 0.9)


func lot_rent(id: String, l: Dictionary) -> float:
	var base := Economy.office_rent(level(id)) if l.get("office", false) \
		else Economy.RENT[int(l["t"])] * float(l["k"])
	return base * (1.0 + Economy.trait_of(manager(id), "rent"))


# rent per minute of one office, or of all of them
func income(id: String = "") -> float:
	if id != "":
		var sum := 0.0
		for lid: String in office(id).get("lots", {}):
			sum += lot_rent(id, office(id)["lots"][lid])
		return sum
	var all := 0.0
	for oid: String in offices():
		all += income(oid)
	return all


func offline_cap_s() -> float:
	var h: float = Economy.OFFLINE_HOURS[0]
	for id: String in offices():
		h = maxf(h, Economy.offline_hours(level(id)) + Economy.trait_of(manager(id), "offline"))
	return h * 3600.0


# --- time ----------------------------------------------------------------------------------------

# pays the rent (and runs the bank) up to `t`, finishing the works due; returns the works that
# finished: [{"office", "lot", "tier"}], oldest first
func advance(t: float) -> Array[Dictionary]:
	var done: Array[Dictionary] = []
	var seen := float(state["seen"])
	if t <= seen:
		return done
	var gap := t - seen
	var is_away := gap > AWAY_GAP
	var paid_until := seen + (minf(gap, offline_cap_s()) if is_away else gap)
	var i0 := float(state["stats"].get("interest", 0.0))
	var r0 := float(state["stats"].get("repaid", 0.0))
	var a0 := auto_started.size()
	var e0 := float(state["stats"].get("earned", 0.0))
	var builder := false
	for id: String in offices():
		builder = builder or auto_on(id)
	var cur := seen
	# events: works ending, and (with a builder on) a look every AUTO_STEP so idle cranes start
	# as soon as the money is there, offline too
	while true:
		var nxt := t
		for id: String in offices():
			var lots: Dictionary = office(id)["lots"]
			for lid: String in lots:
				var l: Dictionary = lots[lid]
				if l.has("end"):
					nxt = minf(nxt, maxf(float(l["end"]), cur))
		if builder:
			nxt = minf(nxt, cur + AUTO_STEP)
		if cur < paid_until:
			_flow(cur, minf(nxt, paid_until))
		cur = nxt
		for id: String in offices():
			var lots: Dictionary = office(id)["lots"]
			for lid: String in lots:
				var l: Dictionary = lots[lid]
				if l.has("end") and float(l["end"]) <= cur:
					l["t"] = int(l["to"])
					l.erase("to")
					l.erase("end")
					l.erase("start")
					state["stats"]["built"] = int(state["stats"].get("built", 0)) + 1
					done.append({"office": id, "lot": lid, "tier": int(l["t"])})
		# the builder takes free cranes at once
		for id: String in offices():
			auto_build(id, cur)
		if cur >= t:
			break
	state["seen"] = t
	if is_away:
		var gone := {"seconds": gap, "paid_s": paid_until - seen,
			"money": float(state["stats"].get("earned", 0.0)) - e0,
			"built": done.size(),
			"interest": float(state["stats"].get("interest", 0.0)) - i0,
			"repaid": float(state["stats"].get("repaid", 0.0)) - r0,
			"auto": auto_started.size() - a0, "capped": gap > offline_cap_s()}
		# a second absence before the first summary was seen adds up into it
		if not away.is_empty():
			for k: String in ["seconds", "paid_s", "money", "built", "interest", "repaid", "auto"]:
				gone[k] = gone[k] + away.get(k, 0)
			gone["capped"] = gone["capped"] or away.get("capped", false)
		away = gone
	return done


# rent (and the bank) over [a, b], with nothing finishing in between
func _flow(a: float, b: float) -> void:
	var dt := b - a
	if dt <= 0.0:
		return
	var per_s := income() / 60.0
	if total_debt() <= 0.0:
		_earn(per_s * dt)
		return
	var t := 0.0
	while t < dt and total_debt() > 0.0:
		var step := minf(BANK_STEP, dt - t)
		_bank_step(per_s, step)
		t += step
	if t < dt:
		_earn(per_s * (dt - t))


func _earn(amount: float) -> void:
	state["money"] = money() + amount
	state["stats"]["earned"] = float(state["stats"].get("earned", 0.0)) + amount


# one short step with loans: interest is added to the debt, capped by the rent; the autopay share
# of the rent goes to the dearest loan first; the rest is cash
func _bank_step(per_s: float, dt: float) -> void:
	var gross := per_s * dt
	var interest := minf(interest_per_min(false) / 60.0, Economy.INTEREST_CAP * per_s) * dt
	var raw := interest_per_min(false)
	var loans: Dictionary = state["loans"]
	if raw > 0.0 and interest > 0.0:
		for key: String in loans:
			var ln: Dictionary = loans[key]
			var share := float(ln["debt"]) * _rate_h(key) / 60.0 / raw
			var add := minf(interest * share, maxf(0.0, float(ln["lent"]) * Economy.GROWTH_CAP
				- float(ln["debt"])))
			ln["debt"] = float(ln["debt"]) + add
			state["stats"]["interest"] = float(state["stats"].get("interest", 0.0)) + add
	var pay := gross * float(state.get("autopay", 0.0))
	var left := _repay_any(pay)
	state["money"] = money() + gross - pay + left
	state["stats"]["earned"] = float(state["stats"].get("earned", 0.0)) + gross


# --- the bank ------------------------------------------------------------------------------------

func total_debt() -> float:
	var sum := 0.0
	for key: String in state["loans"]:
		sum += float(state["loans"][key]["debt"])
	return sum


func loan_debt(kind: String) -> float:
	return float(state["loans"].get(kind, {}).get("debt", 0.0))


func _rate_h(kind: String) -> float:
	return float(Economy.loan_def(kind)["rate_h"]) * (1.0 - _banker())


# the best interest cut a manager gives (a banker also lends you more)
func _banker() -> float:
	var best := 0.0
	for id: String in offices():
		best = maxf(best, cut(id, "interest"))
	return best


func loan_rate_h(kind: String) -> float:
	return _rate_h(kind)


# interest per minute of every loan; `capped` cuts it to what the rent allows, as charged
func interest_per_min(capped: bool = true) -> float:
	var sum := 0.0
	for key: String in state["loans"]:
		var ln: Dictionary = state["loans"][key]
		if float(ln["debt"]) < float(ln["lent"]) * Economy.GROWTH_CAP:
			sum += float(ln["debt"]) * _rate_h(key) / 60.0
	return minf(sum, Economy.INTEREST_CAP * income()) if capped else sum


# what the lots of every office are worth to the bank
func worth() -> float:
	var sum := 0.0
	for id: String in offices():
		for lid: String in office(id)["lots"]:
			var l: Dictionary = office(id)["lots"][lid]
			if not l.get("office", false):
				sum += Economy.worth(float(l.get("pk", 1.0)) * inflation(id), int(l["t"]))
	return sum


# the most a new loan of this kind may be: its own size limit, minus what it already owes, and
# never so much that the interest of all loans would pass AFFORD of the rent
func loan_room(kind: String) -> float:
	var def := Economy.loan_def(kind)
	if def.is_empty() or loan_debt(kind) > 0.0:
		return 0.0
	var inc := income()
	var room := float(def["minutes"]) * inc * (1.0 + 0.5 * signf(_banker()))
	if float(def["assets"]) > 0.0:
		room = minf(room, worth() * float(def["assets"]))
	var other := interest_per_min(false)
	var afford := (Economy.AFFORD * inc - other) * 60.0 / maxf(_rate_h(kind), 1e-9)
	# the fee is borrowed too, so the debt is room * (1 + fee)
	room = minf(room, afford / (1.0 + float(def["fee"])))
	return maxf(0.0, floorf(room / 1000.0) * 1000.0)


func can_borrow(kind: String, amount: float) -> String:
	var room := loan_room(kind)
	if loan_debt(kind) > 0.0:
		return "Ya tienes uno de este tipo"
	if room < Economy.LOAN_MIN:
		return "Tus alquileres no dan para más"
	if amount < Economy.LOAN_MIN:
		return "Muy poco"
	if amount > room + 0.5:
		return "Máximo " + Economy.money(room)
	return ""


func borrow(kind: String, amount: float) -> String:
	var why := can_borrow(kind, amount)
	if why != "":
		return why
	var fee := amount * float(Economy.loan_def(kind)["fee"])
	state["loans"][kind] = {"debt": amount + fee, "lent": amount + fee, "taken": now()}
	state["money"] = money() + amount
	state["stats"]["fees"] = float(state["stats"].get("fees", 0.0)) + fee
	state["stats"]["loans"] = int(state["stats"].get("loans", 0)) + 1
	return ""


# pays up to `amount` off one loan (all of it by default) from cash; returns what was paid
func repay(kind: String, amount: float = INF) -> float:
	if not state["loans"].has(kind):
		return 0.0
	var ln: Dictionary = state["loans"][kind]
	var pay := minf(minf(amount, money()), float(ln["debt"]))
	if pay <= 0.0:
		return 0.0
	state["money"] = money() - pay
	_pay_loan(kind, pay)
	return pay


func set_autopay(share: float) -> void:
	state["autopay"] = _snap_autopay(share)


# the autopay share nearest to `share` (numbers from JSON or a UI are never compared exactly)
static func _snap_autopay(share: float) -> float:
	var best: float = Economy.AUTOPAY[0]
	for a: float in Economy.AUTOPAY:
		if absf(a - share) < absf(best - share):
			best = a
	return best


func autopay() -> float:
	return float(state.get("autopay", 0.0))


# `amount` toward the dearest loans first; returns what was left over
func _repay_any(amount: float) -> float:
	var left := amount
	while left > 0.0 and not state["loans"].is_empty():
		var best := ""
		for key: String in state["loans"]:
			if best == "" or _rate_h(key) > _rate_h(best):
				best = key
		var pay := minf(left, float(state["loans"][best]["debt"]))
		_pay_loan(best, pay)
		left -= pay
	return left


func _pay_loan(kind: String, pay: float) -> void:
	var ln: Dictionary = state["loans"][kind]
	ln["debt"] = float(ln["debt"]) - pay
	state["stats"]["repaid"] = float(state["stats"].get("repaid", 0.0)) + pay
	if float(ln["debt"]) < 0.5:
		state["loans"].erase(kind)


# minutes until all the debt is paid at this autopay share, if the rent stayed as it is now;
# INF when it never would
func payoff_minutes(share: float, extra_debt: float = 0.0, extra_rate_h: float = 0.0) -> float:
	var inc := income()
	if share <= 0.0 or inc <= 0.0:
		return INF
	var debts: Array = []
	for key: String in state["loans"]:
		var ln: Dictionary = state["loans"][key]
		debts.append([float(ln["debt"]), _rate_h(key) / 60.0, float(ln["lent"])])
	if extra_debt > 0.0:
		debts.append([extra_debt, extra_rate_h / 60.0, extra_debt])
	var total := 0.0
	for d: Array in debts:
		total += float(d[0])
	if total <= 0.0:
		return 0.0
	# whole-debt approximation, in steps that shrink as the debt does
	var rate := 0.0
	for d: Array in debts:
		rate += float(d[0]) * float(d[1])
	rate /= total
	var t := 0.0
	var debt := total
	var pay := share * inc
	for _i in 4000:
		var interest := minf(debt * rate, Economy.INTEREST_CAP * inc)
		var net := pay - interest
		if net <= 0.0:
			return INF
		var step := maxf(1.0, debt / net / 50.0)
		debt -= net * step
		t += step
		if debt <= 0.0:
			return t
	return INF


# --- lots ----------------------------------------------------------------------------------------

func buy_price(id: String, info: Dictionary) -> float:
	return Economy.buy_price(info, int(info["base_tier"])) * plusvalia(id) \
		* (1.0 - cut(id, "land"))


# what owning part of the neighbourhood does to the price of the rest
func plusvalia(id: String) -> float:
	return pow(1.0 + Economy.PLUSVALIA, maxi(0, owned_count(id) - 1))


# "" when the lot can be bought now, else why not (for the card)
func can_buy(id: String, info: Dictionary) -> String:
	if owns(id, info["id"]):
		return "Ya es tuyo"
	if float(info["dist"]) > radius(id):
		return "Fuera de tu radio"
	var p := buy_price(id, info)
	if money() < p:
		return "Te faltan " + Economy.money(p - money())
	return ""


func buy(id: String, info: Dictionary) -> String:
	var why := can_buy(id, info)
	if why != "":
		return why
	state["money"] = money() - buy_price(id, info)
	office(id)["lots"][info["id"]] = {"t": int(info["base_tier"]), "k": float(info["rent_k"]),
		"pk": float(info["price_k"]), "mx": int(info["max_tier"])}
	state["stats"]["bought"] = int(state["stats"].get("bought", 0)) + 1
	return ""


# what building a lot up to tier `to` costs (one tier up by default): every tier on the way
func build_cost(id: String, l: Dictionary, to: int = -1) -> float:
	var t0 := int(l["t"])
	if to < 0:
		to = t0 + 1
	var sum := 0.0
	var step := 1.0
	# each tier on the way pays the inflation of the tiers before it, as one at a time would
	for t in range(t0 + 1, mini(to, 5) + 1):
		sum += Economy.BUILD_COST[t] * step
		step *= 1.0 + Economy.WORKS_INFLATION
	return sum * float(l.get("pk", 1.0)) * inflation(id) * (1.0 - cut(id, "cost"))


# the highest tier a lot could be built up to with the money there is now (its own tier when
# not even one more is affordable)
func best_target(id: String, lot_id: String) -> int:
	var l := lot(id, lot_id)
	if l.is_empty():
		return 0
	var best := int(l["t"])
	for to in range(int(l["t"]) + 1, int(l.get("mx", 5)) + 1):
		if build_cost(id, l, to) <= money():
			best = to
	return best


# what the works already done in an office (one per tier raised) do to the price of the next
func inflation(id: String) -> float:
	return pow(1.0 + Economy.WORKS_INFLATION, int(office(id).get("works", 0)))


# seconds of works from tier `from` up to `to`
func build_time(id: String, from: int, to: int) -> float:
	var sum := 0.0
	for t in range(from + 1, mini(to, 5) + 1):
		sum += Economy.BUILD_TIME[t]
	return sum * (1.0 - cut(id, "time"))


func cranes(id: String) -> int:
	return Economy.cranes(level(id)) + int(Economy.trait_of(manager(id), "crane"))


func cranes_busy(id: String) -> int:
	var n := 0
	for lid: String in office(id).get("lots", {}):
		if office(id)["lots"][lid].has("end"):
			n += 1
	return n


func can_build(id: String, lot_id: String, to: int = -1) -> String:
	var l := lot(id, lot_id)
	if l.is_empty():
		return "No es tuyo"
	if l.get("office", false):
		return "Es tu oficina"
	if l.has("end"):
		return "Ya está en obras"
	if int(l["t"]) >= int(l["mx"]):
		return "No cabe más aquí" if int(l["mx"]) < 5 else "Ya es lo más alto"
	if to >= 0 and to <= int(l["t"]):
		return "Nada que construir"
	if to > int(l["mx"]):
		return "No cabe tan alto"
	if cranes_busy(id) >= cranes(id):
		return "Grúas ocupadas"
	var c := build_cost(id, l, to)
	if money() < c:
		return "Te faltan " + Economy.money(c - money())
	return ""


# starts works on a lot up to tier `to` (one tier up by default), paid now (or at `at`)
func build(id: String, lot_id: String, to: int = -1, at: float = -1.0) -> String:
	var why := can_build(id, lot_id, to)
	if why != "":
		return why
	var l := lot(id, lot_id)
	if to < 0:
		to = int(l["t"]) + 1
	state["money"] = money() - build_cost(id, l, to)
	# the works count (inflation) goes up when they start, so cranes started together pay it too
	office(id)["works"] = int(office(id).get("works", 0)) + to - int(l["t"])
	var t := now() if at < 0.0 else at
	l["to"] = to
	l["start"] = t
	l["end"] = t + build_time(id, int(l["t"]), to)
	return ""


# 0..1 of the way through a lot's works
func progress(id: String, lot_id: String) -> float:
	var l := lot(id, lot_id)
	if not l.has("end"):
		return 1.0
	var a := float(l["start"])
	var b := float(l["end"])
	return clampf((now() - a) / maxf(1.0, b - a), 0.0, 1.0)


func auto_open(id: String) -> bool:
	return level(id) >= Economy.AUTO_LEVEL


func auto_on(id: String) -> bool:
	return auto_open(id) and bool(office(id).get("auto", false))


func set_auto(id: String, on: bool) -> void:
	if auto_open(id):
		office(id)["auto"] = on


# the office's builder: while a crane is free it starts the best-paying next tier on one of
# the lots, never spending more than AUTO_SHARE of the cash on one; returns the lots it started
func auto_build(id: String, at: float = -1.0) -> Array[String]:
	var started: Array[String] = []
	if not auto_on(id):
		return started
	while cranes_busy(id) < cranes(id):
		var best := ""
		var best_p := INF
		var lots: Dictionary = office(id)["lots"]
		for lid: String in lots:
			var l: Dictionary = lots[lid]
			if l.get("office", false) or l.has("end") or int(l["t"]) >= int(l["mx"]):
				continue
			var c := build_cost(id, l)
			if c > money() * Economy.AUTO_SHARE:
				continue
			var gain := (Economy.RENT[int(l["t"]) + 1] - Economy.RENT[int(l["t"])]) * float(l["k"])
			if c / gain < best_p:
				best_p = c / gain
				best = lid
		if best == "" or build(id, best, -1, at) != "":
			break
		started.append(best)
		auto_started.append({"office": id, "lot": best})
	return started


# --- office level --------------------------------------------------------------------------------

func can_level_up(id: String) -> String:
	var lv := level(id)
	if lv >= Economy.max_level():
		return "Nivel máximo"
	var c := Economy.level_cost(lv)
	if money() < c:
		return "Te faltan " + Economy.money(c - money())
	return ""


func level_up(id: String) -> String:
	var why := can_level_up(id)
	if why != "":
		return why
	state["money"] = money() - Economy.level_cost(level(id))
	office(id)["level"] = level(id) + 1
	# the first manager comes with the level that opens them, free
	if level(id) == Economy.MANAGER_LEVEL and manager(id) == null:
		var m := Economy.make_manager(_seed(id, -1, 0), level(id), true)
		office(id)["manager"] = m
		news.append("%s es tu gerente: %s" % [m["name"], Economy.trait_text(m["traits"][0])])
	return ""


# --- managers ------------------------------------------------------------------------------------

func managers_open(id: String) -> bool:
	return level(id) >= Economy.MANAGER_LEVEL


# the candidates for hire, a new set every POOL_HOURS; they are rolled when the set is made
# and kept in the save, so neither a level-up nor a clock moved back changes them
func pool(id: String) -> Array[Dictionary]:
	var o := office(id)
	if not o.get("pool") is Dictionary:
		o["pool"] = {"n": 0, "at": now()}
	var p: Dictionary = o["pool"]
	var t := now()
	if t < float(p["at"]) - 60.0:
		p["at"] = t
	if t >= float(p["at"]) + Economy.POOL_HOURS * 3600.0 or not p.has("list"):
		_new_pool(id, t, false)
	var out: Array[Dictionary] = []
	for m: Dictionary in p["list"]:
		if not m.get("hired", false):
			out.append(m)
	return out


func _new_pool(id: String, t: float, paid: bool) -> void:
	var p: Dictionary = office(id)["pool"]
	p["n"] = int(p.get("n", 0)) + 1
	p["refreshes"] = int(p.get("refreshes", 0)) + 1 if paid else 0
	if not paid:
		p["at"] = t
	var list: Array = []
	for k in Economy.POOL_SIZE:
		var m := Economy.make_manager(_seed(id, int(p["n"]), k), level(id))
		m["slot"] = k
		list.append(m)
	p["list"] = list


func pool_left_s(id: String) -> float:
	var p: Dictionary = office(id).get("pool", {"at": now()})
	return float(p.get("at", now())) + Economy.POOL_HOURS * 3600.0 - now()


func refresh_cost(id: String) -> float:
	var p: Dictionary = office(id).get("pool", {})
	return Economy.refresh_cost(level(id), income(), int(p.get("refreshes", 0)))


func refresh_pool(id: String) -> String:
	if not managers_open(id):
		return "Desde el Nv %d" % Economy.MANAGER_LEVEL
	pool(id)
	var c := refresh_cost(id)
	if money() < c:
		return "Te faltan " + Economy.money(c - money())
	state["money"] = money() - c
	_new_pool(id, now(), true)
	return ""


func hire_cost(id: String, m: Dictionary) -> float:
	return Economy.hire_cost(level(id), int(m["rarity"]), income())


func can_hire(id: String, m: Dictionary) -> String:
	if not managers_open(id):
		return "Desde el Nv %d" % Economy.MANAGER_LEVEL
	# only a candidate still in the pool as it is now
	var there := false
	for c: Dictionary in pool(id):
		there = there or (int(c["slot"]) == int(m.get("slot", -1)) and c["name"] == m.get("name"))
	if not there:
		return "Ya no está"
	var c := hire_cost(id, m)
	if money() < c:
		return "Te faltan " + Economy.money(c - money())
	return ""


# the new manager takes over the office; the old one leaves
func hire(id: String, m: Dictionary) -> String:
	var why := can_hire(id, m)
	if why != "":
		return why
	state["money"] = money() - hire_cost(id, m)
	var keep := m.duplicate(true)
	keep.erase("slot")
	keep.erase("hired")
	office(id)["manager"] = keep
	for c: Dictionary in office(id)["pool"].get("list", []):
		if int(c["slot"]) == int(m["slot"]):
			c["hired"] = true
	return ""


func dismiss(id: String) -> void:
	office(id)["manager"] = null


func _seed(id: String, n: int, k: int) -> int:
	return ("%s|%d|%d" % [id, n, k]).hash() & 0x7FFFFFFF


# the move that pays back soonest, affordable or not: {"kind" (buy, build, level, hire), "cost",
# "payback" (minutes), and "info" / "lot" + "to" / "m"}; {} when nothing is left. The HUD's
# "next move" hint and tools/econ_sim.gd's players both use it.
func best_move(id: String, infos: Array[Dictionary]) -> Dictionary:
	var best := {}
	var inc := maxf(income(), 1.0)
	var lv := level(id)
	if lv < Economy.max_level():
		var c := Economy.level_cost(lv)
		var gain := Economy.office_rent(lv + 1) - Economy.office_rent(lv) + inc * 0.3
		best = {"kind": "level", "cost": c, "payback": c / gain}
	if managers_open(id) and manager(id) == null:
		var cands := pool(id)
		if not cands.is_empty():
			var m: Dictionary = cands[0]
			for q in cands:
				if int(q["rarity"]) > int(m["rarity"]):
					m = q
			var c := hire_cost(id, m)
			var cand := {"kind": "hire", "m": m, "cost": c, "payback": c / (inc * 0.15)}
			if best.is_empty() or float(cand["payback"]) < float(best["payback"]):
				best = cand
	var free := cranes_busy(id) < cranes(id)
	for info in infos:
		var lid: String = info["id"]
		if owns(id, lid):
			if not free:
				continue
			var l := lot(id, lid)
			if l.get("office", false) or l.has("end") or int(l["t"]) >= int(l["mx"]):
				continue
			var to := maxi(best_target(id, lid), int(l["t"]) + 1)
			var c := build_cost(id, l, to)
			var gain := (Economy.RENT[to] - Economy.RENT[int(l["t"])]) * float(l["k"])
			var cand := {"kind": "build", "lot": lid, "to": to, "cost": c, "payback": c / gain}
			if best.is_empty() or float(cand["payback"]) < float(best["payback"]):
				best = cand
		elif float(info["dist"]) <= radius(id):
			var c := buy_price(id, info)
			var t := int(info["base_tier"])
			var payback := 0.0
			if t == 0:
				payback = (c + Economy.build_cost(1, info)) / Economy.rent(1, info)
			else:
				payback = c / Economy.rent(t, info)
			var cand := {"kind": "buy", "info": info, "cost": c, "payback": payback}
			if best.is_empty() or float(cand["payback"]) < float(best["payback"]):
				best = cand
	return best


# --- drawing ---------------------------------------------------------------------------------------

# writes this office's lots as the game has them into a baked area, so BlockView draws them:
# owned lots at their tier (owned colours), works in progress as building sites
func apply(id: String, block: Dictionary) -> void:
	var lots: Dictionary = office(id).get("lots", {})
	for p: Dictionary in block["plots"]:
		var pid: String = p["id"]
		if not lots.has(pid):
			continue
		var l: Dictionary = lots[pid]
		p["owned"] = true
		if l.get("office", false):
			continue
		p["built_tier"] = int(l["t"])
		p["levels"] = BlockBaker.levels_for(pid, int(l["t"]))
		if l.has("to"):
			p["works"] = int(l["to"])
		else:
			p.erase("works")
