extends SceneTree

# Plays the economy (scripts/economy.gd through the real Game rules, with a fake clock) as a few
# kinds of player and prints when each milestone happens and how they stand at 5 min, 1 h, 1 day
# and 1 week. Used to tune the numbers; also checks the bank's promises (no player, however he
# borrows, ever has interest above his rent or a debt that grows with autopay on) and exits 1 if
# one is broken.
#
#   godot --headless --path . --script res://tools/econ_sim.gd [-- --file=/abs/office.json]
#       [--days=14] [--only=ideal,widget,lazy,loans,abuser]
# With no --file it bakes the made-up fixture area (no network).
#
# Players:
#   ideal   always watching, does the best-paying thing the moment it can
#   (widget and lazy play their first ten minutes like ideal, and switch the office's builder
#   on as soon as it opens)
#   widget  the game open all day in its corner, a look every hour (4 clicks), closed at night
#   lazy    opens the game three times a day (9, 14, 21 h), 6 clicks, closed in between
#   loans   ideal, but borrows (quick / normal) when that buys the best move now, autopay 25%
#   abuser  ideal, then on day 2 borrows the most of every loan, autopay off, spends it on
#           anything; on day 3 loses his manager and goes away for a week
#   absent  ideal with the abuser's week away but no loans, to see what the loans cost him

const DAY := 86400.0
# everyone plays the first ten minutes like the ideal player
const FIRST_SESSION := 600.0
const SNAPS: Array[float] = [300.0, 3600.0, DAY, 7.0 * DAY, 14.0 * DAY, 28.0 * DAY]
const SNAP_NAMES: Array[String] = ["5 min", "1 h", "1 dia", "1 sem", "2 sem", "4 sem"]

var _infos: Array[Dictionary] = []
var _office_lot := ""
var _t := 0.0
var _bad := 0
var _stats: Dictionary = {}


func _init() -> void:
	var file := ""
	var days := 14.0
	var only: Array[String] = ["ideal", "widget", "lazy", "loans", "abuser", "absent"]
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--file="):
			file = arg.substr(7)
		elif arg.begins_with("--days="):
			days = arg.substr(7).to_float()
		elif arg.begins_with("--only="):
			only.assign(arg.substr(7).split(","))
	var block: Dictionary
	if file != "":
		var data: Variant = Store.read_json(file)
		if not data is Dictionary:
			printerr("SIM FAILED: cannot read " + file)
			quit(1)
			return
		block = data
		if int(block.get("format_version", 0)) == 2:
			block = BlockBaker.upgrade(block)
	else:
		var raw := Fixture.area(39.4733, -0.3877, Rules.MAX_RADIUS)
		block = BlockBaker.bake(raw, 39.4733, -0.3877, Rules.MAX_RADIUS)
	_infos = Economy.lot_infos(block)
	_office_lot = block.get("office_plot", "")
	_describe()
	for who in only:
		_play(who, days * DAY)
	if _bad > 0:
		printerr("SIM FAILED: %d broken promises" % _bad)
		quit(1)
		return
	print("SIM PASS")
	quit(0)


func _describe() -> void:
	var line := "area: %d lots" % _infos.size()
	for r in Rules.ACTIVE_RADIUS:
		var n := 0
		var solar := 0
		for i in _infos:
			if float(i["dist"]) <= r:
				n += 1
				if int(i["base_tier"]) == 0:
					solar += 1
		line += " | %dm: %d (%d solares)" % [roundi(r), n, solar]
	print(line)


# --- one player ------------------------------------------------------------------------------------

func _play(who: String, span: float) -> void:
	_t = 1.0e9
	var t0 := _t
	var g := Game.new("")
	g.clock = func() -> float: return _t
	g.fresh(_t)
	g.add_office("sim", _office_lot, _infos)
	var miles := {}
	var snaps: Array = []
	var next_snap := 0
	var visit := 0.0
	var loan_peak := 0.0
	var worst_ratio := 0.0
	var abuse_stage := 0
	var debt_before_week := 0.0
	while _t - t0 < span:
		var age := _t - t0
		var online := true
		var clicks := 1000
		var first := age < FIRST_SESSION
		match who:
			"widget":
				var hour := fmod(age / 3600.0, 24.0)
				online = hour < 16.0
				clicks = 1000 if first else 4
			"lazy":
				online = first
				clicks = 1000 if first else 6
		# act
		var acted := 0
		if who in ["ideal", "loans", "abuser", "absent"] or _t >= visit or first:
			if who == "abuser" and abuse_stage == 0 and age >= DAY:
				abuse_stage = 1
				g.set_autopay(0.0)
				for def in Economy.LOANS:
					var room := g.loan_room(def["id"])
					if room >= Economy.LOAN_MIN:
						g.borrow(def["id"], room)
				_spend_anything(g)
			# the casual players switch the office's builder on as soon as it opens (one click)
			if who in ["widget", "lazy"] and g.auto_open("sim") and not g.auto_on("sim"):
				g.set_auto("sim", true)
			acted = _act(g, who, clicks, miles, age)
			_milestones(g, miles, age)
			if who in ["widget", "lazy"] and not first:
				visit = _next_visit(who, age, t0)
		loan_peak = maxf(loan_peak, g.total_debt())
		if g.income() > 0.0:
			worst_ratio = maxf(worst_ratio, g.interest_per_min() / g.income())
		# the abuser loses his manager and leaves for a week
		if who == "absent" and abuse_stage == 0 and age >= 2.0 * DAY:
			abuse_stage = 2
			g.dismiss("sim")
			_t += 7.0 * DAY
			g.advance(_t)
			continue
		if who == "abuser" and abuse_stage == 1 and age >= 2.0 * DAY:
			abuse_stage = 2
			g.dismiss("sim")
			debt_before_week = g.total_debt()
			var m_before := g.money()
			var inc := g.income()
			var int_rate := g.interest_per_min()
			_t += 7.0 * DAY
			g.advance(_t)
			print("  abuser: week away with debt %s, rent %s/min, interest %s/min -> money %s, debt %s" % [
				Economy.money(debt_before_week), Economy.money(inc), Economy.money(int_rate),
				Economy.money(g.money() - m_before) + " gained", Economy.money(g.total_debt())])
			if g.money() < m_before:
				_broken("abuser lost money over a week away")
			g.set_autopay(0.10)
			var d0 := g.total_debt()
			_t += 3600.0
			g.advance(_t)
			if d0 > 0.0 and g.total_debt() >= d0:
				_broken("debt did not shrink with autopay 10%")
			continue
		# where to stop next: a snapshot, a works end, a visit, or when the best move is affordable
		var stop := t0 + span
		if next_snap < SNAPS.size():
			stop = minf(stop, t0 + SNAPS[next_snap])
		stop = minf(stop, _next_end(g))
		if who in ["widget", "lazy"] and not first:
			stop = minf(stop, visit)
		else:
			stop = minf(stop, _t + _wait_for_best(g))
		if acted > 0 and who in ["ideal", "loans", "abuser", "absent"]:
			stop = minf(stop, _t + 1.0)
		stop = maxf(stop, _t + 1.0)
		# a closed game is one long jump (away, capped); an open one is paid in pieces
		if online:
			while _t < stop:
				_t = minf(stop, _t + 1800.0)
				g.advance(_t)
		else:
			_t = stop
			g.advance(_t)
		_milestones(g, miles, _t - t0)
		while next_snap < SNAPS.size() and _t - t0 >= SNAPS[next_snap]:
			snaps.append([SNAP_NAMES[next_snap], g.money(), g.income(), g.owned_count("sim"),
				g.level("sim"), _avg_tier(g), g.total_debt()])
			next_snap += 1
	_stats = g.state["stats"]
	_report(who, miles, snaps, loan_peak, worst_ratio)
	if worst_ratio > Economy.INTEREST_CAP + 1e-6:
		_broken("%s: interest reached %.1f%% of rent" % [who, worst_ratio * 100.0])


func _next_visit(who: String, age: float, t0: float) -> float:
	if who == "widget":
		var hour := fmod(age / 3600.0, 24.0)
		if hour + 1.0 < 16.0:
			return _t + 3600.0
		return t0 + (floorf(age / DAY) + 1.0) * DAY
	# lazy: 9, 14 and 21 h of each day (day starts at 0 = 9 h)
	var day := floorf(age / DAY)
	var into := age - day * DAY
	for at: float in [5.0 * 3600.0, 12.0 * 3600.0]:
		if into < at - 1.0:
			return t0 + day * DAY + at
	return t0 + (day + 1.0) * DAY


# does the best moves it can afford, at most `clicks`; returns how many
func _act(g: Game, who: String, clicks: int, miles: Dictionary, age: float) -> int:
	var n := 0
	while n < clicks:
		var best := _best(g)
		if best.is_empty():
			break
		if g.money() < float(best["cost"]):
			if who == "loans" and _borrow_for(g, best):
				pass
			else:
				break
		var err := ""
		match best["kind"]:
			"buy":
				err = g.buy("sim", best["info"])
			"build":
				err = g.build("sim", best["lot"], best["to"])
			"level":
				err = g.level_up("sim")
			"hire":
				err = g.hire("sim", best["m"])
		if err != "":
			break
		if OS.has_environment("SIM_TRACE") and age < 4.0 * 3600.0:
			print("    %s %s %s money left %s" % [Economy.duration(age), best["kind"],
				Economy.money(best["cost"]), Economy.money(g.money())])
		n += 1
	if who == "loans":
		g.set_autopay(0.25)
		# pay loans back from spare cash once nothing is worth buying soon
		if g.total_debt() > 0.0 and _best(g).is_empty():
			for def in Economy.LOANS:
				g.repay(def["id"])
	return n


# takes the cheapest loan that pays for this move, when the move pays back fast
func _borrow_for(g: Game, best: Dictionary) -> bool:
	if float(best["payback"]) > 120.0:
		return false
	var need := float(best["cost"]) - g.money()
	for kind in ["quick", "normal"]:
		if g.loan_room(kind) >= need and need >= Economy.LOAN_MIN:
			return g.borrow(kind, ceilf(need / 1000.0) * 1000.0) == ""
	return false


func _best(g: Game) -> Dictionary:
	return g.best_move("sim", _infos)


func _spend_anything(g: Game) -> void:
	for _i in 200:
		var spent := false
		for info in _infos:
			if not g.owns("sim", info["id"]) and g.buy("sim", info) == "":
				spent = true
		for lid: String in g.office("sim")["lots"]:
			if g.build("sim", lid) == "":
				spent = true
		if not spent:
			break


func _wait_for_best(g: Game) -> float:
	var best := _best(g)
	if best.is_empty():
		return DAY
	var need := float(best["cost"]) - g.money()
	if need <= 0.0:
		return 1.0
	var inc := g.income() * (1.0 - g.autopay() if g.total_debt() > 0.0 else 1.0)
	return clampf(need / maxf(inc, 1e-6) * 60.0 + 1.0, 1.0, DAY)


func _next_end(g: Game) -> float:
	var t := INF
	for lid: String in g.office("sim")["lots"]:
		var l: Dictionary = g.office("sim")["lots"][lid]
		if l.has("end"):
			t = minf(t, float(l["end"]) + 0.01)
	return t


func _avg_tier(g: Game) -> float:
	var sum := 0.0
	var n := 0
	for lid: String in g.office("sim")["lots"]:
		var l: Dictionary = g.office("sim")["lots"][lid]
		sum += int(l["t"])
		n += 1
	return sum / maxf(1.0, n)


func _milestones(g: Game, miles: Dictionary, age: float) -> void:
	var lots: Dictionary = g.office("sim")["lots"]
	var top := 0
	for lid: String in lots:
		top = maxi(top, int(lots[lid]["t"]))
	_mark(miles, "1a compra", age, lots.size() > 1)
	_mark(miles, "1a obra acabada", age, int(g.state["stats"].get("built", 0)) > 0)
	for t in range(2, 6):
		_mark(miles, "1er " + Economy.TIER_NAMES[t], age, top >= t)
	for lv in range(2, Economy.max_level() + 1):
		_mark(miles, "oficina Nv %d" % lv, age, g.level("sim") >= lv)
	_mark(miles, "1er gerente", age, g.manager("sim") != null)
	var inside := 0
	var mine := 0
	var maxed := 0
	for info in _infos:
		if float(info["dist"]) <= Rules.MAX_RADIUS:
			inside += 1
			if g.owns("sim", info["id"]):
				mine += 1
				var l := g.lot("sim", info["id"])
				if int(l["t"]) >= int(l["mx"]):
					maxed += 1
	_mark(miles, "radio 500 m todo tuyo", age, g.level("sim") >= Economy.max_level() \
		and mine >= inside)
	_mark(miles, "todo al maximo", age, maxed >= inside)


func _mark(miles: Dictionary, name: String, age: float, hit: bool) -> void:
	if hit and not miles.has(name):
		miles[name] = age


func _report(who: String, miles: Dictionary, snaps: Array, loan_peak: float,
		worst: float) -> void:
	print("\n== %s ==" % who)
	var names := ["1a compra", "1a obra acabada", "1er Urbanización", "1er Bloque de pisos",
		"oficina Nv 2", "1er gerente", "oficina Nv 3", "1er Torres", "oficina Nv 4",
		"1er Rascacielos", "oficina Nv 5", "radio 500 m todo tuyo", "todo al maximo"]
	for n: String in names:
		print("  %-24s %s" % [n, Economy.duration(miles[n]) if miles.has(n) else "-"])
	print("  %-7s %12s %14s %6s %3s %5s %10s" % ["at", "money", "rent/min", "lots", "lv",
		"tier", "debt"])
	for s: Array in snaps:
		print("  %-7s %12s %14s %6d %3d %5.2f %10s" % [s[0], Economy.money(s[1]),
			Economy.money(s[2]), s[3], s[4], s[5], Economy.money(s[6])])
	if loan_peak > 0.0:
		print("  debt peak %s, worst interest/rent %.1f%%, paid to the bank: fees %s + interest %s" % [
			Economy.money(loan_peak), worst * 100.0, Economy.money(_stats.get("fees", 0.0)),
			Economy.money(_stats.get("interest", 0.0))])


func _broken(why: String) -> void:
	printerr("BROKEN: " + why)
	_bad += 1
