extends SceneTree

# Drives the game's rules headless with a fake clock, like a player would, and fails loudly:
# buy, build (one tier and several), wait, rent, level up (and the free first manager), the
# office's builder (also offline), save and reload, time away (capped), a clock moved back and
# forth, a broken save, the bank (limits, fee, interest never above the rent's cap, money never
# going down, debt shrinking with autopay, a max loan then lost income then a week away), the
# managers (stable candidates, prices, hiring) and the office with no building (its free lot is
# an ordinary one, its own income by level) including a v1 save from before, migrated on load.
# Uses the made-up fixture area (no network).
#
#   godot --headless --path . --script res://tools/game_check.gd
#
# Prints PASS and exits 0, or prints every failure and exits 1.

const SAVE := "user://game_check_save.json"
const OFFICE := "check_1"
const T0 := 2.0e9

var _t := T0
var _mono := 1000.0
var _bad := 0
var _infos: Array[Dictionary] = []
var _block: Dictionary


func _init() -> void:
	var raw := Fixture.area(39.4733, -0.3877, Rules.MAX_RADIUS)
	_block = BlockBaker.bake(raw, 39.4733, -0.3877, Rules.MAX_RADIUS)
	_infos = Economy.lot_infos(_block)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	_loop()
	_offline_and_save()
	_clock_tricks()
	_bank()
	_bank_adversarial()
	_managers()
	_builder()
	_office_lot()
	_migration()
	_broken_save()
	_format()
	for p in [SAVE, SAVE + ".bak", SAVE + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if _bad > 0:
		printerr("GAME CHECK FAILED: %d problems" % _bad)
		quit(1)
		return
	print("PASS game_check")
	quit(0)


func _game() -> Game:
	var g := Game.new(SAVE)
	g.clock = func() -> float: return _t
	g.mono = func() -> float: return _mono
	return g


func _new_game() -> Game:
	_t = T0
	_mono = 1000.0
	var g := _game()
	g.fresh(g.now())
	g.add_office(OFFICE, _block["office_plot"], _infos)
	return g


func _wait(g: Game, s: float) -> Array[Dictionary]:
	_t += s
	_mono += s
	return g.advance(g.now())


# online play: the game ticks every few seconds
func _play(g: Game, s: float) -> Array[Dictionary]:
	var done: Array[Dictionary] = []
	var left := s
	while left > 0.0:
		var step := minf(30.0, left)
		done.append_array(_wait(g, step))
		left -= step
	return done


func _check(ok: bool, what: String) -> void:
	if not ok:
		printerr("FAIL: " + what)
		_bad += 1


func _near(a: float, b: float, tol: float = 0.01) -> bool:
	return absf(a - b) <= maxf(1.0, absf(b)) * tol


func _solar(g: Game) -> Dictionary:
	for info in _infos:
		if int(info["base_tier"]) == 0 and float(info["dist"]) <= g.radius(OFFICE) \
				and not g.owns(OFFICE, info["id"]):
			return info
	return {}


# --- the loop --------------------------------------------------------------------------------------

func _loop() -> void:
	var g := _new_game()
	_check(g.money() == Economy.START_MONEY, "starts with START_MONEY")
	_check(g.owns(OFFICE, _block["office_plot"]), "the office lot is owned from the start")
	_check(g.income() == Economy.office_income(1), "the office's own income from the start")
	var solar := _solar(g)
	_check(not solar.is_empty(), "a solar inside the first radius (START_SOLARES)")
	if solar.is_empty():
		return
	var price := g.buy_price(OFFICE, solar)
	_check(g.buy(OFFICE, solar) == "", "buy a solar")
	_check(_near(g.money(), Economy.START_MONEY - price), "buying takes its price")
	_check(g.buy(OFFICE, solar) != "", "cannot buy a lot twice")
	var far := {}
	for info in _infos:
		if float(info["dist"]) > Rules.MAX_RADIUS - 100.0:
			far = info
			break
	_check(not far.is_empty() and g.can_buy(OFFICE, far) == "Fuera de tu radio",
		"lots outside the radius are refused")
	var lid: String = solar["id"]
	var cost := g.build_cost(OFFICE, g.lot(OFFICE, lid))
	_check(g.build(OFFICE, lid) == "", "build Casas")
	_check(g.cranes_busy(OFFICE) == 1, "the works takes the crane")
	var solar2 := _solar(g)
	if not solar2.is_empty():
		g.state["money"] = 1e6
		g.buy(OFFICE, solar2)
		_check(g.can_build(OFFICE, solar2["id"]) == "Grúas ocupadas", "one crane at level 1")
	var before := g.money()
	var done := _play(g, Economy.BUILD_TIME[1] + 1.0)
	_check(done.size() == 1 and int(g.lot(OFFICE, lid)["t"]) == 1, "the works finish on time")
	_check(g.cranes_busy(OFFICE) == 0, "the crane is free again")
	var expect := Economy.office_income(1) + Economy.rent(1, solar)
	_check(_near(g.income(), expect), "rent goes up when the works finish")
	_check(g.money() > before, "rent comes in while playing")
	before = g.money()
	_play(g, 60.0)
	_check(_near(g.money() - before, g.income(), 0.02), "a minute pays a minute of rent")
	# poor: the reason says how much is missing
	g.state["money"] = 0.0
	_check(g.can_build(OFFICE, lid).begins_with("Te faltan"), "too poor says what is missing")
	# several tiers in one works
	g.state["money"] = 1e9
	var top := g.best_target(OFFICE, lid)
	_check(top > 2, "with money the best target is several tiers up")
	var multi := g.build_cost(OFFICE, g.lot(OFFICE, lid), 3)
	var one := g.build_cost(OFFICE, g.lot(OFFICE, lid), 2)
	_check(multi > one, "building to tier 3 costs more than to tier 2")
	_check(g.build(OFFICE, lid, 3) == "", "works up to Bloque in one click")
	var span := Economy.BUILD_TIME[2] + Economy.BUILD_TIME[3]
	_play(g, span - 5.0)
	_check(int(g.lot(OFFICE, lid)["t"]) == 1, "multi-tier works take the sum of the times")
	_play(g, 10.0)
	_check(int(g.lot(OFFICE, lid)["t"]) == 3, "multi-tier works end at the target tier")
	_check(int(g.office(OFFICE)["works"]) == 3, "inflation counts every tier raised")
	# level up, and the first manager comes free
	g.state["money"] = Economy.level_cost(1)
	_check(g.level_up(OFFICE) == "", "level up")
	_check(g.level(OFFICE) == 2 and g.radius(OFFICE) == Rules.active_radius(2),
		"level 2 grows the radius")
	_check(g.money() < 1.0, "levelling takes its price")
	var m: Variant = g.manager(OFFICE)
	_check(m is Dictionary and Economy.trait_of(m, "rent") > 0.0,
		"the first manager comes free with level 2, with a rent bonus")
	_check(g.cranes(OFFICE) == Economy.cranes(2), "level 2 has two cranes")
	var bm := g.best_move(OFFICE, _infos)
	_check(not bm.is_empty() and bm.has("cost"), "there is always a next move")


func _offline_and_save() -> void:
	var g := _new_game()
	var solar := _solar(g)
	g.buy(OFFICE, solar)
	g.build(OFFICE, solar["id"])
	g.save()
	var inc0 := g.income()
	# five hours closed: the works finish (after 20 s) and the rent pays piecewise
	_t += 5.0 * 3600.0
	_mono = 0.0
	var h := _game()
	var done := h.load_or_new()
	_check(done.size() == 1, "works finish while away")
	_check(not h.away.is_empty(), "coming back after hours makes an away summary")
	var t_end: float = Economy.BUILD_TIME[1]
	var expect := inc0 * t_end / 60.0 + h.income() * (5.0 * 3600.0 - t_end) / 60.0
	_check(_near(float(h.away["money"]), expect, 0.002),
		"away rent is paid piecewise (works end mid-way): %s vs %s" % [h.away["money"], expect])
	# thirty hours closed: only the offline cap is paid
	h.save()
	var m0 := h.money()
	_t += 30.0 * 3600.0
	var k := _game()
	k.load_or_new()
	var cap := Economy.offline_hours(1) * 3600.0
	_check(_near(k.money() - m0, k.income() * cap / 60.0, 0.002), "away pay stops at the cap")
	_check(bool(k.away.get("capped", false)), "the summary says it was capped")
	# a save survives a reload exactly
	k.save()
	var j := _game()
	j.load_or_new()
	_check(_near(j.money(), k.money(), 1e-9) and j.owned_count(OFFICE) == k.owned_count(OFFICE),
		"save and reload keep money and lots")
	# a sleep of a few minutes with the game open counts as away too
	var m1 := j.money()
	_wait(j, 600.0)
	_check(not j.away.is_empty() and _near(j.money() - m1, j.income() * 10.0, 0.002),
		"a long pause while open is paid as away time")


func _clock_tricks() -> void:
	var g := _new_game()
	var solar := _solar(g)
	g.buy(OFFICE, solar)
	_play(g, 120.0)
	g.save()
	var seen := float(g.state["seen"])
	var money := g.money()
	# the clock goes back an hour while playing: play goes on by the engine's timer
	_t -= 3600.0
	_mono += 60.0
	g.advance(g.now())
	_check(float(g.state["seen"]) >= seen, "seen never goes back")
	_check(_near(g.money() - money, g.income(), 0.02),
		"with the clock moved back, a minute of play still pays a minute")
	# the clock moved back a day, the game reopened: nothing is paid until it passes `seen`
	g.save()
	money = g.money()
	_t = T0 - 86400.0
	var h := _game()
	h.load_or_new()
	_check(_near(h.money(), money, 1e-9), "a save from the future pays nothing on load")
	_check(float(h.state["seen"]) >= seen, "a save from the future keeps its time")
	# and moving the clock forward again pays only the real gap since `seen`
	h.save()
	_t = float(h.state["seen"]) + 3600.0
	var k := _game()
	k.load_or_new()
	_check(_near(k.money() - money, k.income() * 60.0, 0.002),
		"back-and-forth clock never pays twice")


# --- the bank --------------------------------------------------------------------------------------

func _bank() -> void:
	var g := _new_game()
	g.state["money"] = 1e7
	for info in _infos:
		if float(info["dist"]) <= g.radius(OFFICE):
			g.buy(OFFICE, info)
	g.state["money"] = 0.0
	var room := g.loan_room("quick")
	_check(room > 0.0 and room <= 30.0 * g.income() + 1.0, "quick loan room is up to 30 min of rent")
	_check(g.can_borrow("quick", room + 5000.0) != "", "cannot borrow more than the room")
	_check(g.borrow("quick", room) == "", "borrow a quick loan")
	_check(_near(g.money(), room), "the loan pays out the amount")
	_check(_near(g.total_debt(), room * 1.01), "the debt carries the fee")
	_check(g.borrow("quick", 1000.0) != "", "one loan of a kind at a time")
	# farming: borrow and repay at once only loses the fee
	var g2 := _new_game()
	g2.state["money"] = 1e7
	for info in _infos:
		if float(info["dist"]) <= g2.radius(OFFICE):
			g2.buy(OFFICE, info)
	var m0 := g2.money()
	var r2 := g2.loan_room("normal")
	g2.borrow("normal", r2)
	g2.repay("normal")
	_check(g2.money() < m0 and g2.total_debt() == 0.0, "borrow + repay at once loses money")
	# repay part by hand
	var d0 := g.total_debt()
	g.state["money"] = d0 * 0.5
	g.repay("quick")
	_check(_near(g.total_debt(), d0 * 0.5) and g.money() == 0.0, "repay uses the cash there is")


# the owner's rule: a loan never chokes. Max every loan, autopay off, lose income (the manager),
# go away a week: money never goes down, interest never passes INTEREST_CAP of the rent, and
# with autopay on the debt shrinks
func _bank_adversarial() -> void:
	var g := _new_game()
	g.state["money"] = 1e8
	g.state["offices"][OFFICE]["level"] = 3
	for info in _infos:
		if float(info["dist"]) <= g.radius(OFFICE):
			g.buy(OFFICE, info)
	g.state["offices"][OFFICE]["manager"] = {"name": "Test", "face": 1, "rarity": 3,
		"traits": [{"k": "rent", "v": 0.45}], "level": 3}
	g.set_autopay(0.0)
	for def in Economy.LOANS:
		var room := g.loan_room(def["id"])
		if room >= Economy.LOAN_MIN:
			_check(g.borrow(def["id"], room) == "", "max %s loan" % def["id"])
	_check(g.interest_per_min(false) <= Economy.AFFORD * g.income() * 1.001,
		"max loans keep interest under AFFORD of the rent")
	g.dismiss(OFFICE)
	_check(g.interest_per_min() <= Economy.INTEREST_CAP * g.income() * 1.0001,
		"after losing income the charged interest is still capped")
	var money := g.money()
	var worst := 0.0
	for day in 7:
		for step in 24:
			_wait(g, 3600.0)
			_check(g.money() >= money - 1e-6, "money never goes down with debt (day %d)" % day)
			money = g.money()
			if g.income() > 0.0:
				worst = maxf(worst, g.interest_per_min() / g.income())
	_check(worst <= Economy.INTEREST_CAP + 1e-6, "interest never above the cap (%.3f)" % worst)
	# a whole week closed in one jump
	g.save()
	_t += 7.0 * 86400.0
	var h := _game()
	var m1 := g.money()
	h.load_or_new()
	_check(h.money() >= m1, "a week away with max debt still gains money")
	for share in [0.10, 0.25, 0.50]:
		h.set_autopay(share)
		var d0 := h.total_debt()
		_play(h, 600.0)
		_check(h.total_debt() < d0 or d0 == 0.0, "debt shrinks with autopay %d%%" % roundi(
			share * 100.0))
	h.set_autopay(0.5)
	var est := h.payoff_minutes(0.5)
	_check(est < INF, "payoff estimate is finite with autopay on")
	_check(h.payoff_minutes(0.0) == INF, "payoff estimate is INF with autopay off")
	_play(h, minf(est * 60.0 * 1.5 + 600.0, 30.0 * 86400.0))
	_check(h.total_debt() == 0.0, "autopay 50% pays everything off")


# --- managers --------------------------------------------------------------------------------------

func _managers() -> void:
	var g := _new_game()
	g.state["offices"][OFFICE]["level"] = 2
	var a := g.pool(OFFICE)
	_check(a.size() == Economy.POOL_SIZE, "a pool of candidates")
	var names := a.map(func(m: Dictionary) -> String: return m["name"])
	g.state["offices"][OFFICE]["level"] = 3
	var b := g.pool(OFFICE).map(func(m: Dictionary) -> String: return m["name"])
	_check(names == b, "the candidates stay the same after a level-up")
	_t -= 7200.0
	var c := g.pool(OFFICE).map(func(m: Dictionary) -> String: return m["name"])
	_check(names == c, "a clock moved back does not reroll the candidates")
	_t += 7200.0 + Economy.POOL_HOURS * 3600.0 + 10.0
	var d := g.pool(OFFICE).map(func(m: Dictionary) -> String: return m["name"])
	_check(names != d, "a new pool after POOL_HOURS")
	var m: Dictionary = g.pool(OFFICE)[0]
	g.state["money"] = 0.0
	_check(g.can_hire(OFFICE, m) != "", "hiring needs money")
	g.state["money"] = 1e12
	var price := g.hire_cost(OFFICE, m)
	_check(price >= Economy.HIRE_MINUTES[int(m["rarity"])] * g.income() - 1.0,
		"hire price is at least its minutes of rent")
	_check(g.hire(OFFICE, m) == "", "hire")
	_check((g.manager(OFFICE) as Dictionary)["name"] == m["name"], "the hired one is in charge")
	_check(g.pool(OFFICE).size() == Economy.POOL_SIZE - 1, "a hired candidate leaves the pool")
	var r0 := g.refresh_cost(OFFICE)
	g.refresh_pool(OFFICE)
	_check(g.refresh_cost(OFFICE) > r0 * 1.9, "refreshing again costs double")
	var g1 := _new_game()
	g1.state["offices"][OFFICE]["level"] = 1
	_check(not g1.managers_open(OFFICE), "no managers at level 1")
	# faces build for any seed and stay on the palette
	for seed in [0, 1, 99, 123456, 0xFFFFFF]:
		var runs := Faces.runs(seed)
		_check(runs.size() > 20, "a face has pixels (seed %d)" % seed)
		for r: Array in runs:
			_check(int(r[3]) >= 0 and int(r[3]) < Pal.NAMES.size(), "face pixel on the palette")


func _builder() -> void:
	var g := _new_game()
	g.state["money"] = 1e9
	g.state["offices"][OFFICE]["level"] = 3
	var n := 0
	for info in _infos:
		if float(info["dist"]) <= g.radius(OFFICE) and int(info["base_tier"]) < 3:
			g.buy(OFFICE, info)
			n += 1
	_check(n >= 2, "lots to build on for the builder test")
	_check(g.auto_open(OFFICE), "the builder opens at AUTO_LEVEL")
	g.set_auto(OFFICE, true)
	var started := g.auto_build(OFFICE)
	_check(started.size() == g.cranes(OFFICE), "the builder fills every free crane")
	var works := int(g.state["stats"]["built"])
	g.save()
	_t += 6.0 * 3600.0
	var h := _game()
	h.load_or_new()
	_check(int(h.state["stats"]["built"]) > works + started.size(),
		"the builder keeps building while away")
	h.set_auto(OFFICE, false)
	_check(h.auto_build(OFFICE).is_empty(), "the builder can be switched off")


# the office has no building: the lot it was placed on is an ordinary solar of the player's,
# built like any other, and the office earns its own income by level
func _office_lot() -> void:
	var g := _new_game()
	var lid: String = _block["office_plot"]
	var info: Dictionary = _infos[_infos.map(func(i: Dictionary) -> String: return i["id"]).find(
		lid)]
	var l := g.lot(OFFICE, lid)
	_check(int(l["t"]) == Economy.OFFICE_LOT_TIER and not l.has("fill") and not l.has("office"),
		"the office lot starts as an ordinary lot at OFFICE_LOT_TIER")
	_check(_near(float(l["k"]), float(info["rent_k"]), 1e-6) and int(l["mx"]) == int(
		info["max_tier"]), "the office lot has the area's multipliers and max tier")
	_check(_near(g.office_income(OFFICE), Economy.office_income(1), 1e-9) and _near(
		g.lots_rent(OFFICE), 0.0), "a solar pays nothing; the office's own income does")
	_check(g.can_build(OFFICE, lid) == "", "the office lot can be built on")
	var bm := g.best_move(OFFICE, _infos)
	_check(bm.get("kind") == "build" and bm.get("lot") == lid or bm.get("kind") == "buy",
		"the first move is to build on the office lot or buy: %s" % bm.get("kind"))
	_check(g.build(OFFICE, lid) == "", "build Casas on the office lot")
	_play(g, Economy.BUILD_TIME[1] + 1.0)
	_check(int(g.lot(OFFICE, lid)["t"]) == 1, "the office lot's works finish")
	_check(_near(g.income(), Economy.office_income(1) + Economy.rent(1, info)),
		"the office lot pays rent like any lot, plus the office's income")
	# all the way up: the office lot may hold the tallest tier its size allows
	g.state["money"] = 1e15
	g.state["offices"][OFFICE]["level"] = Economy.max_level()
	_check(g.build(OFFICE, lid, int(info["max_tier"])) == "" or int(info["max_tier"]) <= 1,
		"the office lot builds up to its max tier")
	_play(g, 5.0 * 3600.0)
	_check(int(g.lot(OFFICE, lid)["t"]) == int(info["max_tier"]), "the office lot reaches %d"
		% int(info["max_tier"]))
	# the office's income grows with its level, the manager's rent bonus counts on it
	for lv in range(1, Economy.max_level() + 1):
		g.state["offices"][OFFICE]["level"] = lv
		_check(_near(g.office_income(OFFICE), Economy.office_income(lv), 1e-9),
			"office income at Nv %d" % lv)
	g.state["offices"][OFFICE]["manager"] = {"name": "T", "face": 1, "rarity": 0,
		"traits": [{"k": "rent", "v": 0.10}], "level": 2}
	_check(_near(g.office_income(OFFICE), Economy.office_income(Economy.max_level()) * 1.1,
		1e-9), "the manager's rent bonus counts on the office's income")
	# an office whose lot is not known yet pays nothing for it and builds nothing on it
	var h := _game()
	h.fresh(h.now())
	h.add_office("pending", lid)
	_check(h.lot("pending", lid).get("fill", false), "without the area the lot waits to be filled")
	h.state["money"] = 1e9
	_check(h.can_build("pending", lid) != "" and h.lots_rent("pending") == 0.0,
		"a lot waiting to be filled cannot be built and pays nothing")
	h.state["offices"]["pending"]["level"] = Economy.AUTO_LEVEL
	h.set_auto("pending", true)
	_check(h.auto_build("pending").is_empty(), "the builder leaves a lot waiting to be filled")
	_check(h.fill_lots("pending", _infos) and not h.lot("pending", lid).has("fill"),
		"fill_lots fills it from the area")
	_check(not h.fill_lots("pending", _infos), "filling twice changes nothing")


# a v1 save (the office stood on its lot: tier 3, the office's rent, never rebuilt) loads into
# the new model: the same income, the lot an ordinary solar to build on
func _migration() -> void:
	var lid: String = _block["office_plot"]
	var solar := {}
	for info in _infos:
		if info["id"] != lid and int(info["base_tier"]) == 0:
			solar = info
			break
	var mgr := {"name": "Lola Ferrer", "face": 7, "rarity": 0, "traits": [{"k": "rent",
		"v": 0.10}], "level": 2}
	Store.write_json(SAVE, {"format": Game.FORMAT, "version": 1, "money": 123456.0, "seen": _t,
		"created": _t - 3600.0, "last_office": OFFICE, "autopay": 0.10, "loans": {},
		"stats": {"earned": 0.0, "interest": 0.0, "fees": 0.0, "repaid": 0.0, "built": 3,
			"bought": 1},
		"offices": {OFFICE: {"level": 2, "office_lot": lid, "works": 2, "auto": false,
			"manager": mgr, "pool": {"n": 0, "at": _t},
			"lots": {lid: {"t": 3, "k": 0.0, "pk": 1.0, "mx": 3, "office": true},
				solar["id"]: {"t": 2, "k": float(solar["rent_k"]), "pk": float(solar["price_k"]),
				"mx": int(solar["max_tier"])}}}}})
	# what a v1 game paid: the office lot paid the office's rent (now its own income)
	var v1_income := (Economy.office_income(2) + Economy.RENT[2] * float(solar["rent_k"])) * 1.1
	var g := _game()
	g.load_or_new()
	var l := g.lot(OFFICE, lid)
	_check(int(g.state["version"]) == Game.VERSION, "a v1 save is brought to the current version")
	_check(not l.has("office") and int(l["t"]) == Economy.OFFICE_LOT_TIER,
		"the v1 office lot becomes an ordinary solar")
	_check(_near(g.income(), v1_income, 1e-9), "a migrated save earns what it earned: %s vs %s"
		% [g.income(), v1_income])
	_check(_near(g.money(), 123456.0, 1e-9) and g.level(OFFICE) == 2 and g.manager(OFFICE)
		is Dictionary and int(g.lot(OFFICE, solar["id"])["t"]) == 2,
		"money, level, manager and the other lots survive the migration")
	_check(g.news.size() == 1 and g.news[0].contains("solar"), "the player is told the lot is free")
	_check(g.can_build(OFFICE, lid) != "", "before the area is seen the lot waits")
	g.fill_lots(OFFICE, _infos)
	g.state["money"] = 1e9
	_check(g.can_build(OFFICE, lid) == "", "once the office opens the old office lot builds")
	g.save()
	var h := _game()
	h.load_or_new()
	var k := h.lot(OFFICE, lid)
	_check(not k.has("office") and not k.has("fill") and int(k["mx"]) >= 1 and h.news.is_empty(),
		"the migrated save reloads as it is, without migrating twice")
	for p in [SAVE + ".bak", SAVE + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _broken_save() -> void:
	# a broken save with a good backup comes back from the backup
	var g := _new_game()
	g.state["money"] = 777777.0
	g.save()
	g.state["money"] = 888888.0
	g.save()
	var f := FileAccess.open(SAVE, FileAccess.WRITE)
	f.store_string("{this is not json")
	f.close()
	var h := _game()
	h.load_or_new()
	_check(_near(h.money(), 777777.0, 1e-9) or _near(h.money(), 888888.0, 1e-9),
		"a broken save comes back from its backup")
	# with no readable copy at all: a new game, and the broken file kept aside
	for p in [SAVE, SAVE + ".bak", SAVE + ".tmp"]:
		var w := FileAccess.open(p, FileAccess.WRITE)
		w.store_string("garbage")
		w.close()
	var k := _game()
	k.load_or_new()
	_check(k.money() == Economy.START_MONEY, "an unreadable save starts a new game")
	var kept := false
	for file in DirAccess.get_files_at(ProjectSettings.globalize_path("user://")):
		if file.begins_with("game_check_save.corrupt-"):
			kept = true
			DirAccess.remove_absolute(ProjectSettings.globalize_path("user://" + file))
	_check(kept, "the unreadable save is kept aside, not overwritten")
	for p in [SAVE + ".bak", SAVE + ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	# odd values inside a readable save are made sane instead of crashing
	Store.write_json(SAVE, {"format": Game.FORMAT, "version": 1, "money": [1, 2], "seen": _t,
		"autopay": 0.0, "loans": {"quick": {"debt": "x"}, "bogus": {"debt": 5.0, "lent": 5.0}},
		"offices": {"a": {"level": 99, "lots": {"l1": {"t": 9, "k": 1.0, "pk": 1.0, "mx": 12,
		"to": 3, "end": _t + 10.0}, "l2": "nonsense", "l3": {"t": 2}}, "manager": "bob"},
		"b": "nonsense"}})
	var j := _game()
	j.load_or_new()
	_check(j.money() == 0.0, "money that is not a number becomes 0")
	_check(j.total_debt() == 0.0, "malformed loans are dropped")
	_check(j.offices().size() == 1 and j.level("a") == Economy.max_level(),
		"malformed offices are dropped and levels clamped")
	_check(j.owned_count("a") == 1 and int(j.lot("a", "l1")["t"]) == 5
		and not j.lot("a", "l1").has("end"), "malformed lots are dropped or clamped")
	_check(j.autopay() == 0.0, "autopay off survives a reload")
	_play(j, 60.0)
	_check(is_finite(j.money()), "a sanitized save plays on")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE + ".bak"))


func _format() -> void:
	_check(Economy.money(12345.0) == "$12.345", "money 12345: " + Economy.money(12345.0))
	_check(Economy.money(1234567.0) == "$1,23M", "money 1,23M: " + Economy.money(1234567.0))
	_check(Economy.money(4.5e10) == "$45,0MM", "money 45MM: " + Economy.money(4.5e10))
	_check(Economy.duration(45.0) == "45 s", "duration 45 s")
	_check(Economy.duration(3 * 3600.0 + 1200.0) == "3 h 20 min", "duration 3 h 20 min")
