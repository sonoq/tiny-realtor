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
#   active  the widget player, plus a session of active play each day (an hour the first day,
#           half an hour after: he plays like ideal then) where he takes the events (Events):
#           most of them (TAKE), with realistic minigame scores (a perfect job about half the
#           time, a failed one now and then)
#   active_noev  the same sessions without events, to see what the events alone add
# With both widget and active played it prints how much sooner active reaches each milestone
# and exits 1 unless that is about 1.5-2.5x on average and never above MAX_RATIO.

const DAY := 86400.0
# everyone plays the first ten minutes like the ideal player
const FIRST_SESSION := 600.0
const SNAPS: Array[float] = [300.0, 3600.0, DAY, 7.0 * DAY, 14.0 * DAY, 28.0 * DAY]
const SNAP_NAMES: Array[String] = ["5 min", "1 h", "1 dia", "1 sem", "2 sem", "4 sem"]
# the active player's daily session of active play (the first day's is longer), and how he
# answers events: the share he takes, and how long he takes to react
const SESSION_FIRST := 3600.0
const SESSION := 1800.0
const TAKE := 0.8
const REACT_S := 8.0
# active against widget: the average speed-up over the milestones must be within this, and no
# milestone may come more than MAX_RATIO times sooner. The office's last milestones are set by
# its cranes (every lot built to the top, three works at a time): everyone reaches them at the
# same time, events or not, so they are shown but not counted
const CRANE_BOUND: Array[String] = ["oficina Nv 5", "radio 500 m todo tuyo", "todo al maximo"]
const RATIO_MIN := 1.5
const RATIO_MAX := 2.5
const MAX_RATIO := 3.0
# the active player's luck (which events come, how he scores) changes a run: he is judged over
# these seeds (the first one is the run printed in full)
const SEEDS: Array[int] = [2024, 7, 99, 12345, 5]

var _infos: Array[Dictionary] = []
var _office_lot := ""
var _t := 0.0
var _bad := 0
var _stats: Dictionary = {}
var _miles := {}
# the active player's milestones, one entry per seed
var _runs: Array[Dictionary] = []
var _ev := {}


func _init() -> void:
	var file := ""
	var days := 14.0
	var only: Array[String] = ["ideal", "widget", "lazy", "loans", "abuser", "absent", "active",
		"active_noev"]
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
	if _miles.has("widget") and _miles.has("active"):
		for k in range(1, SEEDS.size()):
			_play("active", days * DAY, SEEDS[k], true)
		_compare()
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

func _play(who: String, span: float, seed: int = SEEDS[0], quiet: bool = false) -> void:
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
	var casual := who in ["widget", "lazy", "active", "active_noev"]
	var events := who == "active"
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_ev = {"seen": 0, "taken": 0, "paid": 0.0, "jobs": 0, "score": 0.0}
	while _t - t0 < span:
		var age := _t - t0
		var online := true
		var clicks := 1000
		var first := age < FIRST_SESSION
		var sess := who in ["active", "active_noev"] and _session_left(age) > 0.0
		match who:
			"widget", "active", "active_noev":
				var hour := fmod(age / 3600.0, 24.0)
				online = hour < 16.0
				clicks = 1000 if first or sess else 4
			"lazy":
				online = first
				clicks = 1000 if first else 6
		# act
		var acted := 0
		if who in ["ideal", "loans", "abuser", "absent"] or _t >= visit or first or sess:
			if who == "abuser" and abuse_stage == 0 and age >= DAY:
				abuse_stage = 1
				g.set_autopay(0.0)
				for def in Economy.LOANS:
					var room := g.loan_room(def["id"])
					if room >= Economy.LOAN_MIN:
						g.borrow(def["id"], room)
				_spend_anything(g)
			# the casual players switch the office's builder on as soon as it opens (one click)
			if casual and g.auto_open("sim") and not g.auto_on("sim"):
				g.set_auto("sim", true)
			acted = _act(g, who, clicks, miles, age)
			_milestones(g, miles, age)
			if casual and not first and not sess:
				visit = _next_visit("lazy" if who == "lazy" else "widget", age, t0)
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
		var playing := not casual or first or sess
		if not playing:
			stop = minf(stop, visit)
		else:
			stop = minf(stop, _t + _wait_for_best(g))
		if sess:
			stop = minf(stop, _t + maxf(1.0, _session_left(age)))
		# the active player's events come at their time
		if events and (first or sess):
			stop = minf(stop, _t + maxf(1.0, Events.next_in(g, "sim")))
		if acted > 0 and playing:
			stop = minf(stop, _t + 1.0)
		stop = maxf(stop, _t + 1.0)
		var was := _t
		# a closed game is one long jump (away, capped); an open one is paid in pieces
		if online:
			while _t < stop:
				_t = minf(stop, _t + 1800.0)
				g.advance(_t)
		else:
			_t = stop
			g.advance(_t)
		if events and (first or sess):
			var ev := Events.tick(g, "sim", _infos, _t - was, true)
			if not ev.is_empty():
				_react(g, ev, rng)
		_milestones(g, miles, _t - t0)
		while next_snap < SNAPS.size() and _t - t0 >= SNAPS[next_snap]:
			snaps.append([SNAP_NAMES[next_snap], g.money(), g.income(), g.owned_count("sim"),
				g.level("sim"), _avg_tier(g), g.total_debt()])
			next_snap += 1
	_stats = g.state["stats"]
	if quiet:
		_runs.append(miles)
		return
	_miles[who] = miles
	if who == "active":
		_runs.append(miles)
	_report(who, miles, snaps, loan_peak, worst_ratio)
	if events:
		var e := Events.of(g)
		print("  events: %d seen, %d taken, %d jobs (average score %.2f), paid %s, exprés saved %s"
			% [_ev["seen"], _ev["taken"], _ev["jobs"], float(_ev["score"]) / maxf(1.0, _ev["jobs"]),
			Economy.money(float(e["stats"].get("paid", 0.0))), Economy.duration(float(
			e["stats"].get("express_saved", 0.0)))])
	if worst_ratio > Economy.INTEREST_CAP + 1e-6:
		_broken("%s: interest reached %.1f%% of rent" % [who, worst_ratio * 100.0])


# seconds left of today's active session (0 outside it)
func _session_left(age: float) -> float:
	var day := floorf(age / DAY)
	var into := age - day * DAY
	var length := SESSION_FIRST if day == 0.0 else SESSION
	return maxf(0.0, length - into)


# the active player answers an event: most he takes, after a few seconds; a job he plays with
# a realistic score; the rest he lets run out
func _react(g: Game, ev: Dictionary, rng: RandomNumberGenerator) -> void:
	_ev["seen"] = int(_ev["seen"]) + 1
	if OS.has_environment("SIM_TRACE") and int(_ev["seen"]) <= 40:
		print("    event %s %s %s min=%.1f cut=%s money %s income %s" % [ev["kind"], ev.get("lot", ""),
			ev.get("game", ""), float(ev.get("minutes", 0.0)), ev.get("cut", "-"),
			Economy.money(g.money()), Economy.money(g.income())])
	var e := Events.of(g)
	var ok := rng.randf() < TAKE
	if ok:
		_t += REACT_S
		g.advance(_t)
		match ev["kind"]:
			"sale":
				var info := {}
				for i in _infos:
					if i["id"] == ev["lot"]:
						info = i
				ok = not info.is_empty() and g.buy("sim", info) == ""
			"job":
				# a perfect job about half the time, a decent one mostly, a failed one now and then
				var r := rng.randf()
				var score := 1.0 if r < 0.5 else (rng.randf_range(0.5, 0.84) if r < 0.85
					else rng.randf_range(0.0, 0.34))
				Events.finish_job(g, "sim", int(ev["n"]), score)
				_ev["jobs"] = int(_ev["jobs"]) + 1
				_ev["score"] = float(_ev["score"]) + score
			_:
				ok = Events.accept(g, "sim") == ""
	if ok:
		_ev["taken"] = int(_ev["taken"]) + 1
	elif not Events.pending(g, "sim").is_empty():
		# let run out: it would have waited out its life before the next one could come
		var left := float(Events.pending(g, "sim")["left"])
		Events.dismiss(g, "sim")
		e["wait"] = float(e["wait"]) + left


# how much sooner the active player reaches each milestone than the widget player: per milestone
# the geometric mean over the seeds (and the luckiest seed), then the mean over milestones
func _compare() -> void:
	var w: Dictionary = _miles["widget"]
	var n: Dictionary = _miles.get("active_noev", {})
	print("\n== active vs widget (milestones after the first %s, %d seeds) ==" % [
		Economy.duration(FIRST_SESSION), _runs.size()])
	var sum := 0.0
	var count := 0
	var worst := 0.0
	var luckiest := 0.0
	for name: String in _MILESTONES:
		if not w.has(name) or float(w[name]) <= FIRST_SESSION:
			continue
		var logs := 0.0
		var best := 0.0
		var got := 0
		var at := 0.0
		for run in _runs:
			if run.has(name):
				var q := float(w[name]) / maxf(1.0, float(run[name]))
				logs += log(q)
				best = maxf(best, q)
				at += log(maxf(1.0, float(run[name])))
				got += 1
		if got == 0:
			continue
		var r := exp(logs / got)
		var no_ev := "-"
		if n.has(name):
			no_ev = "%.2fx" % (float(w[name]) / maxf(1.0, float(n[name])))
		var bound := name in CRANE_BOUND
		print("  %-24s widget %12s  active %12s  %.2fx (luckiest %.2fx, without events %s)%s"
			% [name, Economy.duration(w[name]), Economy.duration(exp(at / got)), r, best, no_ev,
			"  cranes, not counted" if bound else ""])
		if bound:
			continue
		sum += log(r)
		count += 1
		worst = maxf(worst, r)
		luckiest = maxf(luckiest, best)
	if count == 0:
		return
	var mean := exp(sum / count)
	print("  average %.2fx, at most %.2fx (the luckiest run %.2fx)" % [mean, worst, luckiest])
	if mean < RATIO_MIN or mean > RATIO_MAX:
		_broken("the active player is %.2fx the widget's pace, not %.1f-%.1fx" % [mean,
			RATIO_MIN, RATIO_MAX])
	if worst > MAX_RATIO:
		_broken("a milestone comes %.2fx sooner for the active player (max %.1fx)" % [worst,
			MAX_RATIO])


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


const _MILESTONES: Array[String] = ["1a compra", "1a obra acabada", "1er Urbanización",
	"1er Bloque de pisos", "oficina Nv 2", "1er gerente", "oficina Nv 3", "1er Torres",
	"oficina Nv 4", "1er Rascacielos", "oficina Nv 5", "radio 500 m todo tuyo", "todo al maximo"]


func _report(who: String, miles: Dictionary, snaps: Array, loan_peak: float,
		worst: float) -> void:
	print("\n== %s ==" % who)
	for n: String in _MILESTONES:
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
