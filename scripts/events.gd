class_name Events
extends RefCounted

# The game's events (docs/GAMEPLAY.md "Eventos"): flash offers and tenant jobs that turn up only
# while the player is looking at an office, one at a time per office, each waiting a minute or two
# of active play. Ignoring one costs nothing; taking one pays minutes of the income you have then.
# Plain rules over Game.state["events"] (saved with the game), driven by `tick` with the seconds
# of active play since the last call, so the tools drive it with a fake clock like Game.
#
# Kinds: "sale" (a lot for sale at a discount while the event lives: Game.buy_price reads
# `sale_cut`), "express" (accepted: the office's next works within EXPRESS_WINDOW take half the
# time, Game.build calls `take_express`), "vip" (accepted: one building pays double for a while,
# the lot's `vip` / `vx`, Game.lot_rent), "buyer" (cash now), "job" (a minigame, JobPanel; paid
# by `finish_job` with its score). Rewards are reserved from an hourly bucket (`budget`, minutes
# of income) when the event appears and given back when it is not taken, so the bucket caps what
# events can add, never the idle game.
#
# State: wait (active s until the next event), n (events made, seeds them), pending {office:
# event}, budget (minutes), budget_t (when it was last filled), last_game, log (the last LOG_MAX
# outcomes), stats {spawned, taken, expired, dismissed, paid, jobs, jobs_won, express_saved}.
# An event: n, kind, office, lot, left / life (active s), seed, minutes (reserved), cut (sale),
# secs / x (vip), game (job).

const KINDS: Array[String] = ["sale", "express", "vip", "buyer", "job"]
const LOG_MAX := 20
# the game's own screens tick events; tools that want still shots switch it off
static var auto := true


static func fresh(t: float) -> Dictionary:
	return {"wait": Economy.EVENT_WAIT[0], "n": 0, "pending": {}, "budget": Economy.EVENT_START,
		"budget_t": t, "last_game": "", "log": [], "stats": {"spawned": 0, "taken": 0,
		"expired": 0, "dismissed": 0, "paid": 0.0, "jobs": 0, "jobs_won": 0, "express_saved": 0.0}}


static func of(g: Game) -> Dictionary:
	if not g.state.get("events") is Dictionary:
		g.state["events"] = fresh(_t(g))
	return g.state["events"]


# the rules' "now": the time the game has been paid up to (UI actions sync it first)
static func _t(g: Game) -> float:
	return float(g.state.get("seen", 0.0))


static func pending(g: Game, id: String) -> Dictionary:
	return of(g)["pending"].get(id, {})


# --- the clock -----------------------------------------------------------------------------------

# `dt` seconds of play went by in office `id` (active: the player was looking). Only active time
# counts: the event waiting runs out and the next one comes closer only then, so after time away
# at most the one that was waiting is still there. Returns a new event, or {}.
static func tick(g: Game, id: String, infos: Array[Dictionary], dt: float,
		active: bool) -> Dictionary:
	var e := of(g)
	_refill(g)
	if not active or dt <= 0.0 or not g.has_office(id):
		return {}
	var p := pending(g, id)
	if not p.is_empty():
		p["left"] = float(p["left"]) - dt
		# a lot on sale that was bought some other way is no offer any more
		if p["kind"] == "sale" and g.owns(id, p["lot"]):
			_close(g, id, "taken", 0.0)
		elif float(p["left"]) <= 0.0:
			_close(g, id, "expired", 0.0)
		return {}
	e["wait"] = float(e["wait"]) - dt * (1.0 + Economy.trait_of(g.manager(id), "deals"))
	if float(e["wait"]) > 0.0:
		return {}
	var ev := spawn(g, id, infos)
	if ev.is_empty():
		e["wait"] = Economy.EVENT_RETRY
	return ev


# active seconds until the next event could appear in an office (0 while one is waiting)
static func next_in(g: Game, id: String) -> float:
	if not pending(g, id).is_empty():
		return 0.0
	return maxf(0.0, float(of(g)["wait"])) / (1.0 + Economy.trait_of(g.manager(id), "deals"))


static func _refill(g: Game) -> void:
	var e := of(g)
	var t := _t(g)
	var dt := t - float(e["budget_t"])
	if dt < 0.0:
		e["budget_t"] = t
		return
	e["budget"] = minf(Economy.EVENT_HOUR_CAP, float(e["budget"])
		+ dt / 3600.0 * Economy.EVENT_HOUR_CAP)
	e["budget_t"] = t


# a new event for office `id` now, of `kind` or of whatever kind makes sense (weighted); {} when
# none does. Its reward is reserved from the bucket.
static func spawn(g: Game, id: String, infos: Array[Dictionary], kind: String = "") -> Dictionary:
	var e := of(g)
	if not pending(g, id).is_empty() or g.income() <= 0.0:
		return {}
	_refill(g)
	var n := int(e["n"]) + 1
	var rng := RandomNumberGenerator.new()
	rng.seed = ("%s|ev|%d" % [id, n]).hash()
	var opts := {}
	var total := 0.0
	for k in KINDS:
		if kind != "" and k != kind:
			continue
		var ev := _make(g, id, infos, k, rng)
		if not ev.is_empty():
			opts[k] = ev
			total += float(Economy.EVENT_WEIGHT[k])
	if opts.is_empty():
		return {}
	var roll := rng.randf() * total
	var pick: String = opts.keys()[0]
	for k: String in opts:
		roll -= float(Economy.EVENT_WEIGHT[k])
		if roll <= 0.0:
			pick = k
			break
	var ev: Dictionary = opts[pick]
	var life := rng.randf_range(Economy.EVENT_LIFE[0], Economy.EVENT_LIFE[1])
	ev.merge({"n": n, "kind": pick, "office": id, "left": life, "life": life,
		"seed": rng.randi() & 0x7FFFFFFF})
	if not ev.has("lot"):
		ev["lot"] = ""
	e["n"] = n
	e["wait"] = rng.randf_range(Economy.EVENT_WAIT[0], Economy.EVENT_WAIT[1])
	e["budget"] = float(e["budget"]) - float(ev.get("minutes", 0.0))
	e["pending"][id] = ev
	if pick == "job":
		e["last_game"] = ev["game"]
	e["stats"]["spawned"] = int(e["stats"].get("spawned", 0)) + 1
	return ev


# one kind of event as it would be now, or {} when it makes no sense now
static func _make(g: Game, id: String, infos: Array[Dictionary], kind: String,
		rng: RandomNumberGenerator) -> Dictionary:
	var inc := g.income()
	var budget := float(of(g)["budget"])
	var lots: Dictionary = g.office(id).get("lots", {})
	match kind:
		"sale":
			# the lots for sale nearest the office (where the view opens), one picked at random
			var cands: Array = []
			for info in infos:
				if not g.owns(id, info["id"]) and float(info["dist"]) <= g.radius(id):
					cands.append(info)
			cands.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				return float(a["dist"]) < float(b["dist"]))
			cands = cands.slice(0, 10)
			var cut: float = Economy.SALE_CUTS[rng.randi() % Economy.SALE_CUTS.size()]
			var start := rng.randi() % maxi(1, cands.size())
			for k in cands.size():
				var info: Dictionary = cands[(start + k) % cands.size()]
				var full := g.buy_price(id, info)
				var c := minf(cut, minf(Economy.SALE_MAX, budget) * inc / maxf(full, 1.0))
				c = floorf(c * 20.0 + 1e-6) / 20.0
				if c < 0.1 or c * full < Economy.SALE_MIN * inc:
					continue
				# only what you could buy soon anyway: a sale saves money, it does not unlock a lot
				# far beyond your means
				if full > g.money() + Economy.SALE_REACH * inc:
					continue
				return {"lot": info["id"], "cut": c, "minutes": c * full / inc}
		"express":
			if g.cranes_busy(id) >= g.cranes(id):
				return {}
			var best := ""
			var best_s := 0.0
			for lid: String in lots:
				var l: Dictionary = lots[lid]
				if l.has("end") or int(l["t"]) >= int(l["mx"]) or l.get("fill", false):
					continue
				if g.build_cost(id, l) > g.money() + 2.0 * inc:
					continue
				var secs := g.build_time(id, int(l["t"]), int(l["t"]) + 1)
				if secs >= Economy.EXPRESS_MIN_S and secs > best_s:
					best = lid
					best_s = secs
			if best != "":
				return {"lot": best}
		"vip":
			var cands: Array = []
			for lid: String in lots:
				var l: Dictionary = lots[lid]
				if int(l["t"]) < 1 or l.has("end") or l.has("vip"):
					continue
				var r := g.lot_rent(id, l)
				if r <= 0.0:
					continue
				var room := minf(Economy.VIP_MAX, budget) * inc * 60.0
				var secs := minf(Economy.VIP_S, room / (r * (Economy.VIP_X - 1.0)))
				secs = floorf(secs / 30.0) * 30.0
				if secs >= Economy.VIP_MIN_S:
					cands.append([lid, secs, r])
			if not cands.is_empty():
				var c: Array = cands[rng.randi() % cands.size()]
				var extra := float(c[2]) * (Economy.VIP_X - 1.0) * float(c[1]) / 60.0
				return {"lot": c[0], "secs": c[1], "x": Economy.VIP_X, "minutes": extra / inc}
		"buyer":
			var built := _built_lots(lots)
			var m := minf(rng.randf_range(Economy.BUYER_MIN[0], Economy.BUYER_MIN[1]), budget)
			if not built.is_empty() and m >= 1.0:
				return {"lot": built[rng.randi() % built.size()], "minutes": m}
		"job":
			var built := _built_lots(lots)
			var m := minf(Economy.JOB_MIN * (1.0 + Economy.trait_of(g.manager(id), "handy")),
				budget)
			if built.is_empty() or m < 1.5:
				return {}
			var games: Array[String] = Economy.JOB_GAMES.duplicate()
			# never the same minigame twice in a row
			games.erase(of(g).get("last_game", ""))
			return {"lot": built[rng.randi() % built.size()], "minutes": m,
				"game": games[rng.randi() % games.size()]}
	return {}


# owned lots with a building and no works, where a tenant lives
static func _built_lots(lots: Dictionary) -> Array[String]:
	var out: Array[String] = []
	for lid: String in lots:
		var l: Dictionary = lots[lid]
		if int(l["t"]) >= 1 and not l.has("end"):
			out.append(lid)
	out.sort()
	return out


# --- taking an event ------------------------------------------------------------------------------

# what an event pays now (buyer, job at a perfect score), or saves (sale), in money
static func reward(g: Game, ev: Dictionary) -> float:
	return float(ev.get("minutes", 0.0)) * g.income()


# a job's pay for a score 0..1: a perfect one pays all of it, a failed one JOB_FAIL of it
static func job_pay(g: Game, ev: Dictionary, score: float) -> float:
	return reward(g, ev) * _job_share(score)


static func _job_share(score: float) -> float:
	return Economy.JOB_FAIL + (1.0 - Economy.JOB_FAIL) * clampf(score, 0.0, 1.0)


# takes the waiting event of an office that is taken with one tap (express, vip, buyer); a sale
# is taken by buying the lot (Game.buy), a job by playing it (finish_job). "" or why not
static func accept(g: Game, id: String) -> String:
	var p := pending(g, id)
	if p.is_empty():
		return "Ya no está"
	var t := _t(g)
	match p["kind"]:
		"express":
			g.office(id)["express"] = t + Economy.EXPRESS_WINDOW
			_close(g, id, "taken", 0.0)
		"vip":
			var l := g.lot(id, p["lot"])
			if l.is_empty() or l.has("end"):
				_close(g, id, "expired", 0.0)
				return "Ya no está"
			l["vip"] = t + float(p["secs"])
			l["vx"] = float(p["x"])
			_close(g, id, "taken", float(p["minutes"]))
		"buyer":
			var pay := reward(g, p)
			_pay(g, pay)
			_close(g, id, "taken", float(p["minutes"]), pay)
		_:
			return "Esto no se acepta así"
	return ""


# the player said no (the X): nothing is lost, the reward goes back to the bucket
static func dismiss(g: Game, id: String) -> void:
	if not pending(g, id).is_empty():
		_close(g, id, "dismissed", 0.0)


# a job played with a score 0..1: pays, closes it and returns what it paid (0 when the job is
# not the one waiting any more)
static func finish_job(g: Game, id: String, n: int, score: float) -> float:
	var p := pending(g, id)
	if p.is_empty() or p["kind"] != "job" or int(p["n"]) != n:
		return 0.0
	var pay := job_pay(g, p, score)
	_pay(g, pay)
	var e := of(g)
	e["stats"]["jobs"] = int(e["stats"].get("jobs", 0)) + 1
	if score >= 0.999:
		e["stats"]["jobs_won"] = int(e["stats"].get("jobs_won", 0)) + 1
	_close(g, id, "job", float(p["minutes"]) * _job_share(score), pay, score)
	return pay


# a sale's discount on a lot (0 when none): Game.buy_price applies it
static func sale_cut(g: Game, id: String, lot_id: String) -> float:
	if not g.state.get("events") is Dictionary:
		return 0.0
	var p: Dictionary = g.state["events"]["pending"].get(id, {})
	if p.get("kind", "") == "sale" and p.get("lot", "") == lot_id:
		return float(p["cut"])
	return 0.0


# Game.buy bought a lot: a sale on it was taken
static func on_bought(g: Game, id: String, lot_id: String) -> void:
	if sale_cut(g, id, lot_id) > 0.0:
		_close(g, id, "taken", float(pending(g, id)["minutes"]))


# seconds left of an office's accepted exprés (0 when none)
static func express_left(g: Game, id: String) -> float:
	return maxf(0.0, float(g.office(id).get("express", 0.0)) - _t(g))


# Game.build starts works of `secs` at `t`: with an exprés running they take less, and the
# exprés is used up
static func take_express(g: Game, id: String, secs: float, t: float) -> float:
	var o := g.office(id)
	if not o.has("express"):
		return secs
	var until := float(o["express"])
	o.erase("express")
	if until < t:
		return secs
	var saved := minf(secs * Economy.EXPRESS_CUT, Economy.EXPRESS_MAX_S)
	var e := of(g)
	e["stats"]["express_saved"] = float(e["stats"].get("express_saved", 0.0)) + saved
	_log(g, {"n": -1, "kind": "express", "game": ""}, "used", 0.0)
	return secs - saved


# what an exprés would make works of `secs` take now (for the card), or `secs` without one
static func express_time(g: Game, id: String, secs: float) -> float:
	if express_left(g, id) <= 0.0:
		return secs
	return secs - minf(secs * Economy.EXPRESS_CUT, Economy.EXPRESS_MAX_S)


# seconds left of a lot's VIP tenant (0 when none)
static func vip_left(g: Game, id: String, lot_id: String) -> float:
	var l := g.lot(id, lot_id)
	if not l.has("vip"):
		return 0.0
	return maxf(0.0, float(l["vip"]) - _t(g))


static func _pay(g: Game, amount: float) -> void:
	g.state["money"] = g.money() + amount
	var e := of(g)
	e["stats"]["paid"] = float(e["stats"].get("paid", 0.0)) + amount


# ends the waiting event: `used` minutes of the reserved reward are spent, the rest goes back
static func _close(g: Game, id: String, how: String, used: float, paid: float = 0.0,
		score: float = -1.0) -> void:
	var e := of(g)
	var p: Dictionary = e["pending"].get(id, {})
	if p.is_empty():
		return
	e["pending"].erase(id)
	e["budget"] = minf(Economy.EVENT_HOUR_CAP, float(e["budget"])
		+ maxf(0.0, float(p.get("minutes", 0.0)) - used))
	var key := "taken" if how in ["taken", "job"] else how
	e["stats"][key] = int(e["stats"].get(key, 0)) + 1
	_log(g, p, how, paid, score)


static func _log(g: Game, p: Dictionary, how: String, paid: float, score: float = -1.0) -> void:
	var e := of(g)
	var entry := {"n": int(p.get("n", -1)), "kind": p.get("kind", ""), "how": how,
		"paid": paid, "t": _t(g)}
	if p.get("game", "") != "":
		entry["game"] = p["game"]
	if score >= 0.0:
		entry["score"] = snappedf(score, 0.01)
	e["log"].append(entry)
	while e["log"].size() > LOG_MAX:
		e["log"].pop_front()


# --- the save -------------------------------------------------------------------------------------

# a loaded save's events made sane: a missing block starts fresh (a v2 save), odd numbers are
# clamped, events of offices or lots that are gone are dropped; and the timed effects kept on
# offices (express) and lots (vip, vx)
static func sanitize(g: Game, t: float) -> void:
	var e: Variant = g.state.get("events")
	if not e is Dictionary:
		g.state["events"] = fresh(t)
		e = g.state["events"]
	var d := fresh(t)
	for k: String in ["wait", "budget", "budget_t"]:
		if not Game._num_ok(e.get(k)):
			e[k] = d[k]
	e["wait"] = clampf(float(e["wait"]), 0.0, Economy.EVENT_WAIT[1])
	e["budget"] = clampf(float(e["budget"]), 0.0, Economy.EVENT_HOUR_CAP)
	e["n"] = maxi(0, int(e["n"])) if Game._num_ok(e.get("n")) else 0
	if not e.get("last_game") is String:
		e["last_game"] = ""
	if not e.get("log") is Array:
		e["log"] = []
	if not e.get("stats") is Dictionary:
		e["stats"] = d["stats"]
	if not e.get("pending") is Dictionary:
		e["pending"] = {}
	for id: String in e["pending"].keys():
		var p: Variant = e["pending"][id]
		var ok: bool = p is Dictionary and g.has_office(id) and p.get("kind") in KINDS \
			and Game._num_ok(p.get("left")) and Game._num_ok(p.get("n")) \
			and Game._num_ok(p.get("minutes", 0.0)) and p.get("lot", "") is String
		if ok:
			match p["kind"]:
				"sale":
					ok = Game._num_ok(p.get("cut")) and not g.owns(id, p["lot"])
					if ok:
						p["cut"] = clampf(float(p["cut"]), 0.0, 0.9)
				"vip":
					ok = Game._num_ok(p.get("secs")) and Game._num_ok(p.get("x")) \
						and g.owns(id, p["lot"])
				"job":
					ok = p.get("game") in Economy.JOB_GAMES and Game._num_ok(p.get("seed"))
		if not ok:
			e["pending"].erase(id)
			continue
		p["office"] = id
		p["left"] = clampf(float(p["left"]), 0.0, Economy.EVENT_LIFE[1])
		p["life"] = clampf(float(p.get("life", p["left"])) if Game._num_ok(p.get("life"))
			else float(p["left"]), float(p["left"]), Economy.EVENT_LIFE[1])
		p["minutes"] = maxf(0.0, float(p.get("minutes", 0.0)))
		if not Game._num_ok(p.get("seed")):
			p["seed"] = int(p["n"])
	for id: String in g.offices():
		var o: Dictionary = g.office(id)
		if o.has("express") and not Game._num_ok(o["express"]):
			o.erase("express")
		for lid: String in o["lots"]:
			var l: Dictionary = o["lots"][lid]
			if l.has("vip") and not (Game._num_ok(l["vip"]) and Game._num_ok(l.get("vx"))):
				l.erase("vip")
				l.erase("vx")
			elif l.has("vip"):
				l["vx"] = clampf(float(l["vx"]), 1.0, 5.0)
			else:
				l.erase("vx")
