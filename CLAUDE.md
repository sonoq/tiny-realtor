# Tiny Realtor (working title)

An idle real-estate tycoon that lives in a small always-on-top desktop widget, same format as the
owner's other game Tiny Battlegrounds. You open real-estate offices (oficinas inmobiliarias) in
real neighbourhoods, buy big lots (terrenos) in the streets around them, build on them and earn
rent, from empty lots to skyscrapers. The streets are REAL data from OpenStreetMap; blocks, lots and buildings are
made by the game, drawn as procedural isometric pixel art made with maths.

- Engine: **Godot 4.7.1**, GL Compatibility renderer, GDScript only, no autoloads, no addons.
- Window: 600x600 logical canvas, borderless, always on top, not resizable, stretch mode
  `canvas_items`, nearest texture filter, max 60 fps.
- Main scene `res://main.tscn` (one node running `scripts/main.gd`).
- **Current state: first gameplay loop.** Start on the world map, pick a city, see its real
  map, place offices
  (download and bake each office's area once from OpenStreetMap), and play in the office view:
  rent per minute (offline too, capped), buy lots in the office's radius, build tiers (works with
  scaffolding and cranes), the office tab (the office is a business, not a building: level up
  for a bigger radius and more commissions, the builder switch, one manager per office with
  pixel portraits, rarity and bonuses, greyed PRONTO rows; on the map only a gold pin marks it)
  and the bank (three loans that can never choke you, autopay), plus **events** for active
  play (flash offers and tenant jobs with minigames, in a slim banner under the header). The
  game is saved under `user://`. The design and every number: `docs/GAMEPLAY.md` (Spanish),
  `scripts/economy.gd`, `tools/econ_sim.gd`.
- **Visual style: A, "sibling of Tiny Battlegrounds" (decided by Oscar).** The spec is the
  mockup in `docs/style_mockups/a_battlegrounds/` (`gen_battlegrounds.py` + its PNGs); the other
  three mockups there were the rejected options. See "Style A" below.

## Design (decided so far)

Full text, in Spanish, in `docs/DESIGN.md` (it wins over the older `docs/FEASIBILITY.md`).

- World map (pixel art from Natural Earth's public-domain coastlines, the first screen) -> pick
  a city from a shipped list (later GeoNames) (no live geocoding: Nominatim forbids autocomplete) -> city map (neighbourhood
  names + main avenues from Overpass, 3-5 MB raw once per city, ~150-250 KB saved) -> click to
  place an office.
- **You build; you never buy real buildings.** Placing an office downloads, ONCE, within its max
  radius (500 m) only the streets (names, refs), railways, land-use zones, parks and water from
  the public Overpass API (no own server; polite User-Agent, retry + mirror fallback, "server
  busy" message). No building footprints. The bake derives blocks from the street network and
  cuts each block into 1 to ~4 big **lots** ("terrenos", ~2,500-8,000 m2; every lot faces a
  street and knows its streets and zone): a 500 m area is ~100-150 lots, ~10-15 of them inside
  the 150 m level-1 radius. A share starts pre-built; a built lot is drawn as a small
  development of its tier (several buildings). Saved locally forever, never updated.
- Office level grows the active radius (e.g. 150 m at level 1) inside the downloaded one, so
  levelling never needs the network. Offices are >= 2x max radius + margin apart (~1.5 km), so
  each is a self-contained island; never stitch snapshots taken at different dates.
- Lots: buy, build, rent per minute (offline too, capped), tiers Solar -> Casas -> Urbanizacion
  -> Bloque de pisos -> Torres -> Rascacielos (each tier fills the whole lot). Lot size and zone cap
  building; rezoning (recalificacion) is a goal. Value modifiers from real data (parks, metro,
  schools, shops, corners, full block). One-click events, prestige ("salir a bolsa"), day/night.
- Licence: ODbL. "© OpenStreetMap contributors" must stay visible on screen (the HUD reserves it).

## The user

The owner is **Oscar**. He speaks **Spanish** and **does not read code**. Talk to him in Spanish,
in terms of what he can see and do in the game, never in terms of functions or files. Show, don't
describe: in the cloud, render screenshots (below) and look at / share the PNGs.

## Architecture map

Everything is drawn by hand; no `Control` nodes. `App` routes all input and hands screens plain
calls (`press`/`click`/`drag`/`hover`/`wheel`/`back`) in canvas coordinates.

**Root and screens**
- `scripts/main.gd` (`App`) - root of `main.tscn`. Owns the current `Screen`, the input (left-drag
  on the header bar moves the OS window; a press that moves more than `SLOP` is a drag, else a
  click; Esc = back: office -> its city map -> the world map centred on that city
  (`show_world(focus)`), quits from the world map; the game still opens on the last office)
  and the download jobs: `Overpass` fetch -> parse
  and bake on a `Thread` -> save with `Store` -> open the next screen. Prints a `CITY ...` /
  `OFFICE ...` line with sizes and timings after each job.
- `screen.gd` (`Screen`) - base for full-window screens. `ui.gd` (`Ui`) - shared drawing, a mirror
  of Battlegrounds' `UiKit`: slate checker `backdrop`, Kenney nine-slice `plate`s (panel 12
  studded, 13 slot, 15 button; a flat `chip` under 48 px), `button` (steel, cyan rim when hot,
  gold `accent`), cyan `arrow` buttons (< > + - as pixel glyphs), the top-left `back_button` and
  `header` (title beside it; `BAR_H` is also the window-drag zone), `text` (TinyFont capitals
  with an ink rim and drop shadow; `caps()` swaps letters the fonts lack for their base letter),
  `micro` (the mockup's 3x5 font), `bar`, `coin`, and the `footer` with the OSM credit (on every
  screen) and the red DATOS DE PRUEBA tag in fixture mode. Hit targets >= `MIN_HIT`.
- `world_map.gd` (`WorldMap`) + `world.gd` (`World`) - the first screen: the world in pixel art
  from `assets/world/world_<level>.png` (4 pictures baked by `tools/build_world.gd`, each art
  pixel 2x2 on screen), Miller projection cropped 84 N .. ~58 S so the map is exactly 2:1
  (`World.unit` / `lat_at` / `lon_at`). Zoom steps x1 x2 x4 x8 x16 (`World.STEPS`; x16 shows
  the x8 picture at 4x4, `texture_level`); the screen starts at `WorldMap.STEP_MIN` (1), the
  farthest step whose map is as tall as the window, so the map always covers the whole window
  (under the header and footer; markers and clicks stay in the band between them, `_band`;
  the footer counts zoom from that step as X1), drag pans, wheel / - + zoom; the zoom and the view's middle are static, kept
  for the session. Markers drawn live: a cream dot per `CityDb` city, a gold pin (the office
  view's pin sprite, `WorldMap.pin`) with the office count where the player has offices, and
  markers closer than `HIT` (48, >= MIN_HIT) on both axes grouped (`World.clusters`, offices'
  cities first so they anchor) into a steel disc with the city count (a pin on top when the
  group holds offices). Hover = a chip with the name(s); names under markers where they fit
  (offices' cities gold, others from x4). Click: a lone city opens its map (`App.open_city`);
  a city with offices or a group of <= `LIST_MAX` (4) opens the list (a panel at the bottom,
  5 rows a page: city rows open the map, office rows the office); a bigger group zooms in to
  the first step that splits it. HUD: money + income/min top right, - + and the list button
  (`LIST_BTN` -> CityPick) down the right like the office view; footer note NATURAL EARTH +
  zoom. With no office yet a hint asks for the first one. Esc closes the list, else quits.
  Tool hooks: `set_level`, `center_on`, `focus`, `spot_of(city)`, `list_open`, `list_rows`,
  `show_row`, `row_rect`.
- `city_pick.gd` (`CityPick`) - the shipped city list, 12 a page with < > arrows, reached from
  the world map's list button; back / Esc return to the world map.
- `city_map.gd` (`CityMap`) + `city_paint.gd` (`CityPaint`) - the city map, north up, painted once
  into a SubViewport at 12 m/px and shown at x1/x2/x4, in a slate night palette (land SL1, sea
  CYAN_DD, parks GRASS_DD, roads slate -> gold by class); labels, office markers (gold house +
  dashed pixel ring) and the cursor are drawn live on top. The cursor carries the
  `Rules.MAX_RADIUS` circle, red when closer than `Rules.MIN_SEPARATION` to any office; click =
  pending spot + confirm box. Clicking an office marker opens it.
  `center_on`/`hover_latlon`/`pick_latlon`/`confirm` drive it from tools.
- `loading.gd` (`Loading`) - status, bytes received, spinner; on failure a message with
  Reintentar / Volver.
- `office_view.gd` (`OfficeView`) - one saved office, the map viewer: shows `BlockView.texture`
  (drawn once, a frame or two after opening; `is_drawn()`) at x1/x2/x3 (x2 = the mockup), back +
  neighbourhood ("N / M tuyos"). **No street names on the map** (Oscar): a click on open
  ground (a street, a pavement, a park; `lot_under` -1) calls `name_street`, which finds the
  street whose kerb is within `StreetNames.REACH` of the ground point under it (`ground_at`)
  and shows its plate (kind in gold micro font over the name, a stem down to the street) for
  `STREET_SHOW_MS` or until the next click (`street`, drawn by `_draw_street`).
  Lots are pointed at through BlockView's pick image (`lot_under`): hover = a cyan outline of
  everything the lot shows (grey when outside the active radius, still selectable), click =
  `select` (gold outline, slid up out from under the card; `focus_lot` pans one into view).
  Before drawing it writes the game's lots into the area (`Game.apply`) and lets the game fill
  in its free office lot's multipliers (`Game.fill_lots`); `redraw_lot(i)` redraws one lot,
  `relevel(radius)` draws the whole area again off screen after a level-up and swaps it in. The
  office's pin: `on_mark(at)` (the pin or the ground round it, at least `MIN_HIT` at any zoom,
  never a building in front of it; hovering it outlines no lot) and `mark_on_screen()`. Every
  input goes to its `OfficePlay` first. Esc / back closes a panel, then the card, then
  leaves. A saved v2 area is upgraded to v3 on open (`BlockBaker.upgrade`) and written back.
- `office_play.gd` (`OfficePlay`) - the game layer drawn over the map (a child node of
  OfficeView, so the map code and the game code stay apart): money + rent/min (+ debt) top
  right; under the zoom the bank button and the office button (a gold briefcase, a dot when a
  level-up is affordable or a manager could be hired); on the map price tags (gold = affordable)
  over lots for sale in the radius, gold arrows over lots that can be built on now, a bar + time
  over each works, "+$amount" pops over owned roofs only while the pointer is over the window,
  "TU OFICINA" over the office's pin while pointed at (a click on it opens the office tab); at
  the bottom the next move (`Game.best_move`; tap = pan to it and open its card, or the office
  tab for a level-up / a hire) and the level line (level, free cranes, "Nv 2: faltan $X · ~5
  min" or "¡Subir!", money/cost bar; tap = the office tab). The lot card buys, builds the next
  tier or several at once ("Hasta Torres $X"), or borrows what is missing and does it in one tap
  ("Pedir $X", the note says what you will owe); the office's own lot has an ordinary card. A
  level-up in the tab redraws the area for the new radius (`_leveled`). Buy / build can be undone for 6 s (the whole state comes back, a loan
  taken for it too; opening a panel or another action ends the undo). Guards for a window that
  is always on top: the card's buttons keep their action while the pointer is on them, a click
  right after the window got the focus (`App.focus_ms`) or the second tap of a double tap does
  not spend (nor does it in the office tab), the welcome card ignores taps for 0.7 s, a drag that starts on the UI does not pan.
  Before an action the game is brought up to date (`OfficeView.sync`). Toasts (important ones
  queue). The welcome-back card ("Mientras no estabas: +$X"). The events' layer `events_ui`
  (EventUi, below) ticks the events while the map is in front, draws its banner and marks, and
  takes clicks before the rest; the toast moves under the banner (`_toast_rect`). A panel with
  `step` / `press` / `drag` (JobPanel) is stepped every frame and gets the press (once: OfficeView
  calls `press` a single time) and drags. `open_job(ev)`, `event_buy(i)`, `street_of(i)`.
  Holds the panel:
- `bank_panel.gd` (`BankPanel`), `office_panel.gd` (`OfficePanel`) - full-window panels over the
  office with the back button and title: the bank (debt, interest/min next to rent/min, autopay
  NO/10/25/50 % with the payoff time, three loans with Pedir / Devolver; Pedir opens a sheet that
  shows amount, debt, interest vs rent and the payoff at each autopay before Firmar) and the
  office tab "Tu oficina", two pages under the header (`TABS`): OFICINA (level, radius, income
  = lots' rent + commissions, lots / works / free cranes, offline hours; the next level with
  its cost, what it brings and `LEVEL_BTN`; the "Obras solas" switch, greyed until Nv 3; greyed
  PRONTO rows `SOON` for later features) and GERENTE, which is `team_panel.gd` (`TeamPanel`,
  drawn inside the tab: the one in charge, the agency's three candidates, reroll, hire with a
  second tap). `OfficePlay.open_panel("office" | "team" | "bank")`.
- `event_ui.gd` (`EventUi`) - the events on the map: a slim banner (`BANNER`, under the header,
  left of the zoom column) that slides in with the event's icon (`ICONS`, 8x8 pixel glyphs), a
  title, a micro-font line (what and where) with the seconds it still waits and a shrinking gold
  bar, a button (`BTN`: the sale price, ACTIVAR, ACEPTAR, +$X, AYUDAR) and an X (`CLOSE`,
  dismiss); a tap on its body pans to the lot and opens its card (a job opens JobPanel). An
  accepted exprés shows in it until used. Clicks on it fall through to the map for `GRACE_S`
  after it slides in; buying from it goes through OfficePlay's guards and undo. A gold bubble
  with the icon bobs over the event's lot, a star + time over each VIP building (`draw_marks`);
  `card_line(i)` is the lot card's line about it. `active()`: window focused and the pointer
  moved within `ACTIVE_FOCUS_S` (180), or the pointer over the window within `ACTIVE_HOVER_S` (30);
  a frame longer than `TICK_MAX` is not played time.
- `job_panel.gd` (`JobPanel`) - a tenant job, full-window like the bank: INTRO (who, how, what a
  perfect / failed job pays, EMPEZAR), PLAY (the minigame under a time bar, a hint line, a short
  "¡Ya!" `READY_S` before the clock runs), DONE (one to three stars, the money, ¡BIEN!). Pays in
  `_finish` (Events.finish_job) before the result shows: back mid-game ends it with the score so
  far, back on the intro leaves the job waiting. `paused` + `run(dt)` let tools step it.
- `minigames/` - `job_game.gd` (`JobGame`, base: own clock, `limit` = `Economy.JOB_S`, score 0..1,
  `press` / `click` / `drag`, rising pops, pixel `sprite` / `inked` / `thick` helpers, seeded
  rng, `outro()` = how long the end shows before the result, JobPanel waits for it),
  `pipes_game.gd` (`PipesGame`, "Sin agua en casa"; it replaced the toilet job, Oscar: a 5x4
  board of pipe pieces (80 px tiles) between the water main (left, red wheel) and the tenant's
  sink (right); a tap turns a piece a quarter clockwise; water runs from the main through every
  piece joined to it (`flow_of`, filling at `FLOW` pieces a second, dripping from open ends) and,
  once the main reaches the sink, on into the basin ("¡AGUA!"; the game ends at the join, the
  water keeps running in its `outro`). The board: a random run of `LEN_MIN`..`LEN_MAX` straights
  and elbows from the main to the sink with at least `WAYS_MIN` bits of ways to lie (so random
  taps hardly ever find it), the rest straights, elbows and tees at random, then every piece of
  the run turned wrong within `TURNS_MAX` taps, the first one shut to the main; boards that
  sweeping every tile in turn (rows, columns, backwards, four rounds) would join are scrambled
  again (`_mash_safe`). Score 1 joined, else `PART` (0.9) x the share of the run the water
  reaches; idle = 0. A save's "plunge" job or `last_game` becomes "pipes" (`Events.sanitize`)),
  `wires_game.gd` (`WiresGame`, "Sin luz en
  casa": 4 wires to their sockets in a shuffled order, click-click either way or drag over the
  socket; colours plus shapes), `bulbs_game.gd` (`BulbsGame`, "Bombillas fundidas": a facade at
  night, tap the dark windows; more go out at `BURNS`, each flickering first). Every hit box is
  over MIN_HIT.
- `faces.gd` (`Faces`) - manager portraits: 16x16 pixel busts from a seed (skin, hair style and
  colour, eyes, glasses, moustache, suit and tie or blouse), palette colours with an ink rim,
  drawn at whole multiples; `badge` frames one in its rarity's colour.

**Data and rules**
- `economy.gd` (`Economy`) - every number of the game (tiers: build cost, time, rent; land;
  pre-built markup; plusvalía and works inflation; office levels: cost, the office's own
  income `OFFICE_INCOME` (commissions), cranes, offline hours; `OFFICE_LOT_TIER` (the free lot
  starts a solar); later offices; the three loans and the bank's caps; managers: hire prices,
  pool odds, traits, among them the event ones `deals` (Ofertas) and `handy` (Mañoso); the
  events: `EVENT_WAIT`, `EVENT_LIFE`, `EVENT_HOUR_CAP` (20 min of income an hour),
  `EVENT_START` (a new game's bucket, 6), `EVENT_EARLY` (no reward over 20 % of all earned so
  far: the opening is not skipped), `EVENT_WEIGHT`, SALE_* / EXPRESS_* / VIP_* / BUYER_MIN /
  JOB_*) and what a lot is worth from real data (`lot_infos`: area factor, location
  bonuses park / avenue / water / commercial / rails, max tier by zone and size, distance).
  `money()` ("$12.345", "$1,23M", "$45,6MM" = mil millones, "$7,1B" = billón) and `duration()`.
- `game.gd` (`Game`) - the player's game, plain data with an injectable clock (`clock`, `mono`):
  money, the bank, and per office its level, lots (tier, rent and price multipliers, max tier,
  works), works count, builder switch, manager and candidate pool. Income = each office's own
  `office_income` (commissions by level) + its `lots_rent`, both with the manager's rent bonus.
  `add_office` owns the lot the office was placed on, free, as an ordinary lot at
  `OFFICE_LOT_TIER`; until `fill_lots` has seen the area it is `fill` (pays nothing, takes no
  works). A v1 save's `office: true` lot is migrated to that in `_sanitize` (with a news line).
  Rules: `buy`, `build` (one
  tier or several), `level_up` (the first manager comes free at Nv 2), `auto_build` (the
  office's builder), `borrow` / `repay` / `set_autopay`, `pool` / `refresh_pool` / `hire`,
  `best_move`. `advance(now)` pays rent piecewise between works ends (the builder starts new
  works at each end, offline too), runs the bank in 60 s steps (interest added to the debt, cut to
  8 % of the rent; autopay), treats a gap > 2 min as away (paid up to the offline cap, summary in
  `away`), and never pays twice for a clock moved back (`seen` only grows; while the wall clock
  is behind, `now()` runs on the engine's timer). `load_or_new` falls back to `save.json.tmp`
  then `save.json.bak` and keeps an unreadable save aside (`save.corrupt-<time>.json`) before a
  new game; `save` keeps the previous file as `.bak`; `_sanitize` drops or clamps malformed
  entries. Works count for inflation when they start; each tier of a multi-tier works pays the
  inflation one at a time would. `apply` writes the game's lots into a baked area. Event hooks:
  `buy_price` takes a sale's cut (`Events.sale_cut`) and `buy` closes it (`Events.on_bought`);
  `build` started by the player (not the builder, `at` < 0) uses an accepted exprés
  (`Events.take_express`); `lot_rent` doubles a lot with a live `vip` (checked against `_rent_t`,
  the start of the piece `advance` is paying; a VIP's end is a boundary of `advance`, so it pays
  to the second); `_sanitize` calls `Events.sanitize`.
- `events.gd` (`Events`) - the events' rules, static functions over `Game.state["events"]`, driven
  by `tick(g, id, infos, dt, active)` with seconds of play (only active ones count: the wait for
  the next event and the life of the waiting one), so tools drive it with a fake clock. One
  waiting event per office (`pending`); `spawn(g, id, infos, kind?)` picks among the kinds that
  make sense now (`_make`: sale = a lot for sale in the radius whose full price is within
  `SALE_REACH` min of income of your cash, 30-50 % off worth 0.5-6 min; express = a free crane
  and works of 1 min+ you can pay; vip = a built lot, at most `VIP_MAX` extra minutes; buyer /
  job = a built lot; never the same minigame twice running), deterministic from (office, n).
  Rewards are minutes of income reserved from the hourly bucket (`budget`, refilled by game time
  up to `EVENT_HOUR_CAP`; never over `early_cap`) and given back when not taken. `accept` (express, vip, buyer),
  `dismiss`, `finish_job(g, id, n, score)` (pays `JOB_FAIL` + the rest by score, once), `reward`,
  `job_pay`, `express_left` / `express_time` / `vip_left`, a short `log` and `stats`. `auto` off
  (tools) stops the screens from ticking them.
- `rules.gd` (`Rules`) - `MAX_RADIUS` (500 m), `ACTIVE_RADIUS` per level (150 m at level 1),
  `MIN_SEPARATION` (1.5 km), nearest office / too-close checks (great-circle distance).
- `store.gd` (`Store`) - everything under `user://`: `cities/<city>.json`,
  `offices/index.json`, `offices/<id>.json`, `save.json` (the game; `save_fixture.json` in
  fixture mode). Writes go through a temp file; `read_json` is null on a missing or broken file.
  Offices, city maps and saves made of fixture data are kept apart from real ones.

**Download and bake**
- `overpass.gd` (`Overpass`, a Node) - one query at a time: POST to overpass-api.de, then
  overpass.kumi.systems, then overpass.private.coffee, waits 2/5/10/20/30 s between tries, 150 s
  timeout, User-Agent `TinyRealtor/0.1` (no personal data). Detects Overpass's "200 + runtime
  error" answers. Sets the HTTPS proxy only when `HTTPS_PROXY` is set and the TLS CA only when
  `SSL_CERT_FILE` or `/root/.ccr/ca-bundle.crt` exists (the cloud container); on a normal PC
  Godot's defaults apply. Debug flags (after `--`): `--fixture` (or env `TINY_REALTOR_FIXTURE=1`)
  = no network, made-up data from `Fixture`; `--raw-cache=DIR` = keep/reuse raw answers in DIR
  keyed by the query's md5 (dev only).
- `fixture.gd` (`Fixture`) - made-up Overpass-shaped answers: a city box (grid, ring road,
  river, maybe a coast, "Barrio ..." names) and an office area (the prototype's hand-made
  Eixample without its buildings when within 1.5 km of it, else a generated street grid).
- `geo.gd` (`Geo`) - lat/lon <-> local metres, haversine, polygon helpers (`repair` untangles
  self-intersections, `clip`, `minus`, `cut_out` never leaves holes), multipolygon ring
  assembly, and `sea()`: sea polygons from coastline ways (land on the left) inside a border.
  Clipper hands outer rings back counter-clockwise (y up) and holes clockwise.
- `city_baker.gd` (`CityBaker`) - city query (8 km box: motorway..secondary, coastline, water,
  rivers, parks, place=borough/suburb/quarter/neighbourhood nodes) and its bake (format
  `tiny-realtor-city` v1: roads, sea, land, water, rivers, parks, places; names picked so the
  Latin font can draw them: `name`, else `name:en`/`name:ja-Latn`/romanised, else `name:es`).
- `block_baker.gd` (`BlockBaker`) - the office query and bake (see the format below). **No
  buildings are downloaded**: the streets (with names/refs), railways, land-use zones, parks and
  water within `MAX_RADIUS`. Steps: project, turn so the dominant street direction (length-
  weighted histogram mod 90 deg) lies on the iso axes, roads/rails/greens/water/sea, then blocks,
  then `parcel()`: lots (Plotter.split), each side tested against the street kerbs (`_frontage`:
  a side whose middle and one more point lie within half the street's width + `PAVEMENT` +
  `FRONT_TOL` of a street faces it), slivers / thin / street-less blocks become `courts` of kind
  `garden`, pre-built tiers, then the office's lot (a solar, `OFFICE_LOT_TIER`), then the
  office's pin (`office_mark`). `upgrade()` re-parcels a v2 file from its saved blocks and roads
  (same result as a fresh bake).
- `office_mark.gd` (`OfficeMark`) - where the office's pin stands: the open ground (no lot within
  `LOT_CLEAR`, no asphalt or rail bed, no water, inside the disc) nearest the clicked point,
  searched in rings out to `REACH`; among the spots up to `PREFER` m farther, the one nearest the
  viewer. `at(block)` reads `office_mark` or works it out and keeps it in the block.
- `street_graph.gd` (`StreetGraph`) - polygonizes the streets (plus the disc edge): node every
  crossing, weld at 0.5 m, prune dead ends, walk the faces (leave each node by the next way
  clockwise; bounded faces are counter-clockwise). Elevated motorways and trams do not bound
  blocks; other rail lines do.
- `plotter.gd` (`Plotter`) - two cuts. `split()` (bake): a block over `LOT_MAX` (7,600 m2,
  +-22% per block) is halved by a straight cut across its long side (else its short side, else
  square to its longest street side), area-balanced 50 +- 8%, recursively; a cut is kept only
  if every piece is >= `LOT_MIN` and faces >= `FRONT_MIN` m of street. `sites()` (drawing): a lot
  cut into building sites, a perimeter strip one site deep along its street sides only, each
  side owning the wedge between its corner bisectors (or running square to a side with no
  street), cut across every frontage width; convex street corners merge into one corner site.
- `block_view.gd` (`BlockView`) - draws a v3 area once, style A, into `texture` (signal
  `drawn`): `set_block` builds the ops (AreaBuilder) and sorts them (DepthSort); `_ready` runs
  GPU passes in throwaway SubViewports, each read back once: the ground as palette indices
  + the shadow mask + the **pick** image, then the world (ground through WorldShader's ground
  shader, the slab, the ring, every object in painter's order with its ink outline, price tags).
  The pick pass draws each lot's ground, then each lot's objects (outline included, walls
  trimmed to the wall) in painter's order, all in the lot's number (`r + g * 256 = lot + 1`):
  `lot_at(px)` is whatever lot is drawn there, a tower's roof included; `outline(lot)` gives
  the two pixel rings around it as runs (cached). `lots` = AreaBuilder's per-lot entries.
  `pops` the roofs income pops rise from;
  `mark_box` the office's pin, `sign_box` it with a margin (labels keep clear), and
  `points_at_mark(px, grow)` (live mode: the depth image says nothing stands in front).
  `live` mode (the game): any lot may become a rascacielos, so the drawing leaves room for
  `top_of(5, 35)` (~70 px, a third of the old skyscraper's); the
  builder and the image are kept, and `redraw_lot(i)` re-lays one lot (`AreaBuilder.rebuild_lot`)
  and redraws only the rectangle it touches (old and new buildings and shadows + a margin; only
  the ops and objects that reach it, the objects re-sorted among themselves) in small viewports,
  then pastes it into the image, the texture and the pick image (signal `redrawn`; `redraw_ms`,
  `redraw_wall_ms`, `redraw_px` for the logs). The ground shader takes the piece's `offset`.
  A fourth pass, **depth**, replays every object in painter's order with each pixel's ground
  depth (x - y, bigger = nearer; `depth_code()`: `(d + 1024) * 16` in r + g * 256, 0 = bare
  ground, 65535 = price tags) as `depth_tex`, kept with the shadow mask (`shade_tex`) for
  Traffic. In live mode their images are kept too and a lot redraw patches its rectangle of
  both (depth of the new buildings, works and cranes; their shadows), so cars hide behind what
  was just built at once. After a level-up OfficeView hands Traffic the new drawing and radius
  (`Traffic.attach`), so its fade follows the new radius.- `area_builder.gd` (`AreaBuilder`) - a v3 area -> ops: the ground (pavement, asphalt, pedestrian
  paving, rails, parks, water, gardens, lane dashes, zebra crossings at junctions), shadows, the
  earth slab, the dashed gold ring, and each lot as a development of its tier, laid out at draw
  time from the lot's polygon, `fronts`, tier, levels, zone and owned flag (so a lot can be
  rebuilt at any tier without touching the file), with the mockup's recipes: 0 dirt lot with
  fence posts, weed patches, bushes and a "$" sign (in the radius); 1 a row of houses with
  hedged gardens (`Plotter.sites`, `SITE_DEPTH/FRONT`); 2 bigger houses with pools; 3
  apartment blocks of mixed heights and facades round a courtyard garden; 4 torres and 5
  rascacielos as `Skyline` plans them (`_skyline` / `_piece`: the plan's ground (plaza, paving
  or lawn), its gardens and pools, each group one object, each mass in it ringed in ink by
  `Painter.ink_under`, trees on what is left open; pieces BOX / HIP (pyramid roofs through
  `Painter.pitched`) / BRIDGE / LAWN / POOL / SOLAR / SIGN (`_sign`, a billboard in a car tint)
  / ANTENNA / TREE / PAD; an owned building's main roof is teal); industrial 1-2 = sheds in a
  yard; a plot with `works` = a building site (fence, concrete floors under a skeleton,
  scaffolding, a tower crane from bloque up; torres / rascacielos use the plan's footprints and
  heights, the plan made from the same lot, `fronts` and `corner`). The office has no building: `_office_mark` draws a dashed gold ring on the ground
  (`pre`, under everything that stands) and a gold map pin sprite (`office`, the city map's
  house in its head; an object of no lot, so it sorts, outlines and goes through the depth pass
  like a lamp but never into the pick image) at `OfficeMark.at`; street trees, lamps, people and
  garden trees keep `MARK_CLEAR` from it. The lot the office was placed on is an ordinary lot.
  Owned = one cyan flag per lot (`_take_flag`; roofs keep their own colours: teal ones read as a sea of blue lids); an owned solar flies a flag instead of the sale sign.
  Each lot's ground ops (`lot_ground`), shadows (`lot_shadows`) and objects are kept apart so
  `rebuild_lot` can lay it out again; `lots[i].roof` is where its pops rise; `tags` off leaves the
  price tags to the game. Every object records its `lot`; buildings fade per lot (`lots[i].active`
  = centroid inside the radius). Trees (gardens, parks, street trees), lamps and people inside
  the active radius (people only when `people` is on: one-off renders; the game's live
  drawing leaves them to Walkers), cars, price tags (`price_tag`, `price_of`) on the nearest signed lots. All
  placement by stable hashes. **No trees on the road**: OSM parks often run under the
  carriageways (the Gran Via's median); `_index_roads` buckets carriageways and rail beds as
  capsules on a `ROAD_CELL` grid, `on_road(q, clear)`; `_scatter` keeps every trunk `TREE_CLEAR`
  (1.8 m) off them, plants as many trees as the ground the park still shows (`_open_share`) over
  its spacing and tries again the tries that land by a road, so a park keeps its density; street
  trees on asphalt are dropped. All ground ops go through `Pal.ground` (PAVE* -> cement).
- `skyline.gd` (`Skyline`) - the two top tiers as plans (data only; AreaBuilder draws them and
  lays their works out from them). **Every lot its own**: `archetype()` picks one of 13 by
  stable hash (`WEIGHT`; corner lots favour the corner landmark, small lots skip the roomy
  ones): RACIMO (staggered towers of different widths), PUENTES (towers on a podium, sky bridges
  on rascacielos), MEGABLOQUE (terraces with roof gardens), ANILLO (towers round a garden with a
  fountain), MANZANA (mid-rise along the streets, a garden courtyard, the tall one rising out of
  it), ZIGURAT (a stepped tower), TORRE Y BLOQUE (a slim tower beside a long slab), ART DECO (a
  stone tower on a shop podium, two setbacks under trim bands, spire or mast), OFICINAS (a slab
  on the street, a taller one behind it, AC, signs, helipad), HOTEL (a pool deck wing and a
  balcony tower), ESQUINA (a chamfered landmark on the street corner, wings along both streets),
  BLOQUE EN L (a stepped slab round the streets, its corner rising, pool and garden inside),
  PLAZA (a tower on a plaza, pavilions; it was a pyramid roof, Oscar dropped them); an archetype the lot has no room for hands
  over to the next. `_fill` then lines the lot's free street sides with lower buildings of their
  own heights and facades (some sites left open), so a grown district keeps the mid tiers'
  grain. `_greens` (Oscar: no sandy wasteland) then plants the paving the plan leaves open, past
  a 2 m rim along the lot's edges and paths round every building and garden: squares on a grid
  square to the lot (`GREEN_CELL` 9-14 m by lot, `GREEN_PATH` cement between, half to four fifths
  of them, three kinds of lawn / bed), or for `GREEN_PARK` of the lots one park lawn per piece;
  pieces under `GREEN_MIN` (140 m2) stay paved; all as plan `ground`. **Materials**: `SCHEMES` (12) give each lot a tall / alt / mid material, trim and roof:
  glass in GLS blue, TEAL, CYN, GRN, BRZ bronze or STL dark steel (STYLE_SKY in that ramp),
  concrete frames (STYLE_TOWER, its glass by variant), ribbon office slabs (STYLE_RIBBON), brick
  / stone / white towers with punched windows, balconies or fins (STYLE_GRID), apartments and
  offices. `_tower` ends a tower as `C_FLAT`, `C_SETBACK`, `C_GOLD`, `C_STEPS`, `C_PYRAMID`,
  `C_PAD`, `C_ANTENNA` or `C_SPIRE`; `_props` puts AC units, water tanks, huts, solar panels, a
  rooftop sign or a roof garden on flat roofs. **Height cap** so a grown area reads in the
  widget: torres' tallest `TOWER_Z` 30-42 px (+ up to a 5 px setback), rascacielos' tallest
  exactly `SKY_Z` 52-60 px (`sky_z`) + a crown (gold bands, spire, helipad or mast, never a pyramid; a
  7 px spire at most); mid-rise `MID_Z`, pavilions `LOW_Z`; `top()` is what
  `AreaBuilder.top_of` and the live headroom use. `AreaBuilder.skyline` (default `MIX`) lets
  tools force one archetype.
- `street_names.gd` (`StreetNames`) - street names for the click plate: `nearest(block, p)` (the
  road whose kerb is within `REACH` of a ground point), `kind(road)` (Calle, Avenida, Plaza,
  Paseo, Gran Vía, Autovía, Calle peatonal... from the name's first word, else the OSM kind),
  `short()` (generic word dropped or abbreviated for the micro font: "Carrer d'Àngel Guimerà"
  -> ANGEL GUIMERA, Avinguda -> AV.; used when a name is too long for the plate), `plain()`.
- `painter.gd` (`Painter`) - records one object's ops (POLY, WALL, RECT, TEX) with the mockup's
  primitives: `wall` (wall_pixels), `prism`, `face3d`, `pitched`, Bresenham `line`. POLY ops
  from `flat`/`face3d` carry each corner's ground depth, WALL ops their two ends' (depth pass).
  `ink_under(start)` puts a one-pixel ink silhouette under the ops since `start` (a sprite's
  ink copy carries a 4th element), so masses sharing one object still read apart.
- `world_shader.gd` (`WorldShader`) - the two shaders, generated with the palette's names: the
  facade shader (walls per pixel: apartment, office, house, tower (glass by variant), sky
  (glass in its ramp), ribbon, grid, plain, skeleton, scaffold, slab, cab, shed, ink; sprites from the atlas) and the ground shader.
- `depth_sort.gd` (`DepthSort`) - painter's order: separating axis between footprint hulls for
  every pair whose screen boxes overlap, then a topological sort (fixes long thin plots). Where
  the rules go round in a circle the farthest object left goes next and the sort carries on,
  so a circle only reorders itself: a lot redraw (which sorts only the objects round the lot)
  then agrees with a fresh drawing; the old fallback (everything left sorted by centre) let a
  circle closed by a new building reorder hundreds of far trees and lamps.
- `pal.gd` (`Pal`), `iso.gd` (`Iso`), `sprites.gd` (`Sprites`) - see "Style A".
- `docs/prototype/` - the Python prototype (Pillow + Shapely); its `block_raw_overpass.json` is
  the hand-made Eixample sample the fixture uses. Not shipped.

**Traffic** (moving cars and walking people over the office drawing;
`docs/screenshots/traffic/`, `docs/screenshots/walkers/`)
- `road_net.gd` (`RoadNet`) - the area's roads (pedestrian streets aside) as lanes: lines split
  where they cross or touch (`split_crossings`), junctions under `MERGE` (8 m) apart or whose
  boxes overlap merged;
  a two-way edge gets one lane each way (two on 18 m+ avenues), a one-way edge (`oneway`) one
  to three lanes its way, right-hand (left-hand for `Traffic.LEFT_HAND` countries); each lane
  is pulled back from its junctions until clear of every street meeting it at an angle
  (`_trim_at`). Junctions are crossed on **connectors**, cubic curves from lane end to lane
  start, bent round the lanes' corner, re-routed via the junction when they would leave the
  asphalt, made lazily (`connector(a, b)`); `conflict(c1, c2)` = they pass within 2.4 m (two
  from the same lane never conflict); `conflict_end(c1, c2)` = how far along c1 that ends (a car
  past it is out of c2's way). `choose()` picks the next lane: no U-turn unless a dead
  end, no hairpins or "rough" curves, avenues and straight on preferred, lanes already full of
  cars avoided (Traffic's per-lane `load`, `JAM_M` m a car). A one-way street with
  no way out is never chosen; at the disc's edge a street with no way on is an exit (the car
  drives off the world). Lanes and connectors are "paths" (polyline + running
  length) in one index space, lanes first; `CRUISE` / `DENSITY` / `PULL` per street kind.
- `traffic.gd` (`Traffic`, a Node2D child of OfficeView's sprite, so it draws in drawing pixels
  at the view's zoom) - up to `CAP` (80) vehicles, struct-of-arrays, simulated at `TICK`
  (10 Hz) and interpolated + rounded to whole art pixels when drawn. Each tick: speeds from
  where everyone is (cruise x a per-car pace, braking into the next connector's speed, gap to
  the car ahead on the path / next two paths, `_sense` for cars ahead on other paths where
  streets merge), then everyone moves. Junctions: a car within `LOOK` of its kerb line asks
  (every 3rd tick) for its connector: never before the car in front on its lane, nothing
  along it (`_swept`: a car standing there makes it `held` and the others do not give way to
  it; one driving by does not; one on the street beyond is `_room`'s business), clear of
  every reserved conflicting connector (a car past where the two meet, `conflict_end`, no
  longer counts), nobody free to go waiting longer for a conflicting one, room on the street
  beyond; when that street is shorter than the car + 1 m, the next junction is reserved in the
  same go (`nxt2`), and only when that short street is empty and nobody heads into it
  (`_via_free`; while not, the car is not `held`); a car held up by the car in front on its
  lane is `held` too. Waiters and reservations are listed per junction (`_node_wait`,
  `_node_res`). **Fair turns**: a car right behind one that just got the same way follows it
  in the same go (`FOLLOW` m, up to `TRAIN` cars, room for all of them); a car whose way fits
  with the one crossing may go before an older waiter that one holds up (`_crossed`) until
  that waiter has waited `PASS_MAX` (35 s); at **odd junctions**, where a way across crosses
  the end of another lane (`_mark_odd`, e.g. a street that joins inside the avenue's queue
  after a node merge), the cars on that lane stop short of the way of a car that has waited
  longer or is crossing now (`_keep_clear`, geometry cached by `_tail`: where the way crosses
  the lane, where it leaves it), wait there (`kept`), and give way to it in turn (`_clear`'s
  tail rule); elsewhere none of this runs. Safeguards (`_would_hit`, `_into_way`) keep
  footprints apart in odd geometry; who waits for whose junction decides who gives way, so it
  never deadlocks.
  Cars gather around the view (`set_view`): the target count is the lanes' density within
  reach of the view's corners; a car far out of reach (or stuck 40 s) and out of sight is
  removed, new ones start out of sight on lanes near the view (`populate()` fills and settles
  6 s at the start). Redrawn at most 30 times a second (`DRAW_EVERY`).
  All choices from one RandomNumberGenerator seeded by the office id. Brake lights while
  slowing. Drawn as one `canvas_item_add_triangle_array` (preallocated quads) through its car
  shader: atlas index -> palette, the pixel hidden where the depth pass holds something more
  than `HIDE_TOL` (1.5 m) nearer than the car's middle, faded when the car's middle is beyond
  the active radius and darkened per pixel in cast shadows, via the palette's tables
  (`blend_disabled`, never off-palette).
  `frozen` + `run(n)` let tools step it. In the game OfficeView freezes and hides it while a
  full-window panel (bank, office tab) covers the map, and re-attaches it to the new drawing and
  radius after a level-up. It owns the `walkers` (below): steps them after the cars each tick,
  draws them in the same batch sorted with the cars (COLOR.b: bit 1 = faded, bit 2 = a walker:
  its own atlas `walk_atlas` and `WALK_TOL` 0.3 m), and its cars keep out of crossings people
  are on (`_walk_gap`), stop before the zebra while they wait for their junction
  (`_zebra_line`, `CROSS_STOP`), never ask for their way while people cross just before or
  after the junction, and never start on a crossing.
- `car_sprites.gd` (`CarSprites`) - the vehicles (5 car colours, taxi, 2 vans, bus) in 16
  headings, with and without brake lights, drawn once per session with Painter + the facade
  shader + ink outline like AreaBuilder's parked cars, read back to palette indices.
- `walk_net.gd` (`WalkNet`) - the pavements as a walking network: each block's ring
  `RING_OUT` (0.95 m) out, between the shop fronts and the street trees, kept where it runs by a
  street (near a kerb, on no carriageway, `BLOCK_CLEAR` off every lot and garden, inside the
  disc); crossings from `zebra_spots()` (AreaBuilder's zebra rule, copied: keep the two in step;
  plus unpainted ones at corners of narrow streets, over pedestrian streets and where streets
  cross without sharing a point, as `RoadNet.split_crossings` splits them), each marched across
  to the first walkway on both sides, cut at medians (`MEDIAN`) into one crossing per
  carriageway, dropped when over `SPAN_MAX` of road or running along a street (`SLANT_MAX`).
  Walkways are edges of at most `PIECE` m between nodes (crossing ends, run ends); edge kinds
  PAVE / CROSS / FREE (no cars); per crossing its kerbs along the edge (`c_k0`, `c_k1`) and the
  `busy` count Walkers keeps. `bands(roadnet, path)` (cached per path, lazily as junction curves
  appear) gives where a car path runs through each crossing's band (`BAND` 1.6 m either side
  of its line). Built on a thread (~0.3 s on a real area) while the office is drawn.
- `walkers.gd` (`Walkers`) - up to `CAP` (48) people, struct-of-arrays, owned and stepped by
  Traffic at its tick: keep right (`LAT_MIN..LAT_MAX`), own pace, pick their way at random at
  every node (crossings preferred, no queueing three deep), step out to pass someone in the way
  (`DODGE`, never on a crossing), now and then stop at a shop front (dog walkers more), never
  come closer than `SEP` (0.45 m) to anyone (whoever moves later in the tick checks against the
  other's new place), turn back when held up `STUCK_TURN` s. At a crossing they wait
  `WAIT_BACK` before the kerb and step out (`busy`) only when no car is on it, none is coming
  too fast to stop gently, none has its junction (`granted`) or has waited `CAR_TURN` s on its
  way through it (and for `CAR_PHASE` after that, none waiting just behind it, so a queue of
  cars gets through in one go); on it they never wait for a car; they give up after
  `PATIENCE` s. Gather
  round the view like the cars (`DENSITY` per 100 m of walkway within `REGION` of Traffic's
  reach), one seeded RNG per office.
- `walker_sprites.gd` (`WalkerSprites`) - the people: a one-pixel column of shoes, trousers,
  shirt, face and hair (the static people's look) with a hand, in 16 `LOOKS`, 4 headings
  (towards / away, right / left) x 3 walk frames, alone, with a dog or a pram; painted on the
  CPU into an index atlas like CarSprites'.
- AreaBuilder keeps static cars only parked at the kerb: both kerbs of 12-18 m streets (whose
  lanes sit at 0.22 of the width from the middle), one kerb of 8.5-10 m one-way streets (one
  lane down the middle); BlockBaker keeps each road's `oneway`.

## Style A (the look, and the rules that keep it)

The office view is the mockup's renderer ported to the GPU, pixel for pixel in spirit:
- **One palette** (`Pal`, 74 colours from `gen_battlegrounds.py`: Battlegrounds' slate/ink/gold/
  cyan/mint/red plus the city ramps CRM OCH SAL STN TER TIL TEAL GLS CON; `Pal.EXTRA` adds
  ramps made of palette colours: GLD gold trim, STL dark steel, CYN / GRN / BRZ glass, numbered
  after the car tints). The ground is **cement, not sand** (Oscar): `Pal.CEMENT` maps the
  ground's PAVE names to CON1 (pavements, plazas, paved lots) with SL5 slab joints, a CON0 kerb
  and lip (`Pal.ground`, the ground shader's `CEM` / `CEM_J`); the PAVE colours stay in the
  palette unused by the ground. Every pixel of the
  drawing is a palette colour: nothing blends (`render_mode blend_disabled`), shadows, the dim
  outside the active radius and the faded "unpainted miniature" buildings are remap tables over
  the palette (`Pal.shadow/dim/fade`, rows of `Pal.lut()`). `render_office.gd` fails on any
  off-palette pixel. Sprites go through an index atlas read with `texelFetch`, never a canvas
  item's own TEXTURE (compat converts it from sRGB and the colours drift).
- **Camera** (`Iso`): `S` = 1.19 low-res px per metre, `u = x, v = -y`, screen
  `((u - v) S, (u + v) S / 2 - z)` with z already in pixels (a storey is 3-5 px by tier); light
  from the upper left (`Iso.LIGHT`, `Iso.shade`). The drawing is low-res; the view shows it at x2
  (one art pixel = 2x2 screen pixels) with nearest filtering. Only integer zooms.
- **Outlines**: every object (not lamps/people) gets a 1 px INK outline: its ops replayed shifted
  left/right/up/down in ink before the colour pass.
- **Walls** are quads whose vertex colour and UV carry the facade parameters (style, light k,
  ramp, variant, height, width, seed; see the comment in `world_shader.gd`); the shader finds
  each pixel's column and row above the base exactly like `wall_pixels` and picks the colour.
- **Determinism**: placement and details hash with `Iso.h01` (String.hash, mixed), never `randf`.
- **UI**: TinyFont 12 bold / narrow bold / 10 bold (`fonts/`, see `TinyFont-README.md`; imported
  with antialiasing, hinting and subpixel positioning off) only at whole multiples of the design
  size (24, 36; 20 for the 10 px font); the mockup's micro font for the credit and tags; Kenney
  CC0 nine-slices (`assets/ui/`, `LICENSE_kenney.txt`) at 1:1 with 16 px slices, as UiKit.
  Colours: VOID/SL0 backdrop checker (76 px), CREAM text, MUTED secondary, GOLD money/level/
  accent buttons, CYAN arrows and hover, BLOOD/RED warnings, MINT reserved for income.
- The game's overlay (OfficePlay, the panels) is UI drawn with Ui helpers over the drawing, not
  part of it: price tags, arrows, bars and pops come from the game, live. `render_office` still
  draws AreaBuilder's own placeholder tags (`PRICE_M2`) for one-off renders.

## Save format (`tiny-realtor-save` v3, `user://save.json`)

Written through `save.json.tmp`, the previous file kept as `save.json.bak`.
`format`, `version` 3, `money`, `seen` (unix seconds paid up to; only grows), `created`,
`last_office` (opened at start), `autopay` (0 / 0.1 / 0.25 / 0.5), `loans` {quick | normal |
mortgage: {debt, lent (incl. fee; growth stops at 1.5x), taken}}, `stats` {earned, interest,
fees, repaid, built, bought, loans}, `offices` {office id: {level, office_lot, works (tiers
raised, for inflation), auto (builder on), lots {lot id: {t (tier), k (rent multiplier), pk
(price multiplier), mx (max tier), fill (true while the office's free lot waits for its
multipliers from the area), to / start / end (works)}},
manager (null or {name, face (portrait seed), rarity 0-3, traits [{k, v}], level}), pool {n,
at, refreshes, list [candidates with slot, hired]}}}. Only owned lots are stored; the rest come
from the office file. Rents and prices are kept per lot so income needs no office file.
v1 (the office stood on its lot): that lot was `{t: 3, k: 0, mx: 3, office: true}` and paid
the office's rent; on load it becomes the free solar `{t: OFFICE_LOT_TIER, fill: true}` and the
office's rent is its `office_income`, so a migrated game earns the same.
v3 adds `events` {wait (active s to the next), n, pending {office id: {n, kind (sale | express |
vip | buyer | job), office, lot, left / life (active s), seed, minutes (reserved), cut, secs, x,
game (pipes | wires | bulbs; an old "plunge" loads as pipes)}}, budget (minutes), budget_t,
last_game, log [{n, kind, how, paid, t, game?, score?}], stats {spawned, taken, expired, dismissed, paid, jobs, jobs_won,
express_saved}}, an office's `express` (unix s an accepted exprés lasts until) and a lot's `vip`
(unix s) + `vx` (rent multiplier); a v2 save gets `events` fresh; `Events.sanitize` drops odd
ones.

## Office area format (`tiny-realestate-block` v3)

Metres, x east / y north, already turned by `rotation_deg` so streets follow the axes; origin =
the office. Top level: `format`, `format_version` 3, `source`, `attribution`, `center {lat, lon}`,
`rotation_deg`, `radius_m`, `seed`, `fetched`, `data_source` (`osm` | `fixture`), `stats`,
`office_plot` (lot id or "": the lot the player gets free, a solar in fresh bakes),
`office_mark` ([x, y] metres: the office's pin, OfficeMark; files without it work it out when
drawn), `office` (the meta also kept in the index: id, city, name, lat,
lon, level, max_radius, active_radius, created, source, stats), and the layers:
`roads[] {name, ref, kind, width, line, oneway?}` (`oneway` 1 = along the line, -1 = against
it, absent = two-way; files baked before it have none), `rails[] {kind, line}`, `greens[] {kind, poly}`,
`courts[] {kind, poly}`, `water[] {kind, poly}` (kind `sea` from coastlines), `land[]` (islands),
`blocks[] {id, zone, poly}`, `plots[]` = the LOTS (terrenos; the name is kept from v2)
`{id, block, poly, street, streets, corner, fronts, zone, front_m, area_m2, built_tier, levels,
owned}`: `poly` counter-clockwise; `fronts` (new) = indices i of the sides poly[i] -> poly[i+1]
that face a street (never empty); `streets` (new) = every street name it faces, most frontage
first (`street` = the first, "" when unnamed); `front_m` = metres of street frontage; `corner`
= faces streets at an angle. `courts[]` are now small gardens (`kind` garden: blocks too small,
thin or street-less for a lot). Optional `upgraded_from` (2) on a file re-parcelled from v2,
whose `courts` are replaced too. `stats.plots` = `stats.lots` = the lot count. Zones:
residential / commercial / industrial (from landuse, else residential). Tiers: 0 solar,
1 casas, 2 urbanizacion, 3 bloque, 4 torres, 5 rascacielos. Every polygon is snapped to 10 cm
and guaranteed to triangulate.

## Conventions (same as Tiny Battlegrounds)

- Static typing everywhere (`:=`, typed arrays, `-> void`), tabs, lines up to ~100 chars.
- One `class_name` per script; data/helpers extend `RefCounted`, drawn things extend `Node2D`.
  Everything is drawn by hand with `_draw()` / `draw.connect(...)`; no `Control` nodes.
- Constants `UPPER_SNAKE` at the top; private members and methods start with `_`.
- Comments are lower-case one-liners above a const/func explaining **why**, not what. No docstrings.
- All layout is in the fixed 600x600 canvas; anything tappable must stay usable at a 200 px window.
- Performance matters: draw static things once into a texture, no per-frame allocation in hot loops.
- Every script has a committed `.gd.uid` file and every asset a committed `.import`; commit them
  with the file. `.gitattributes` forces LF. `.godot/`, `build/`, `.claude/settings.local.json`,
  `.claude/worktrees/` are ignored.

## Verify (Linux / cloud)

```bash
bash tools/cloud/setup.sh                         # fresh container: Godot 4.7.1 + apt deps + import
godot --headless --path . --import                # after adding/renaming files
godot --headless --path . --quit-after 300        # boots main.tscn for 300 frames
godot --headless --path . --script res://tools/bake_check.gd   # bakes fixtures, checks lots
godot --headless --path . --script res://tools/traffic_check.gd # 5 seeds x 6 min on 4 areas
godot --headless --path . --script res://tools/walker_check.gd  # 5 simulated min of walkers
godot --headless --path . --script res://tools/game_check.gd   # the game's rules, saves, bank
godot --headless --path . --script res://tools/econ_sim.gd     # pacing table + bank promises
godot --headless --path . --script res://tools/world_check.gd   # world map pictures + groups
bash tools/cloud/screenshot.sh docs/screenshots --fixture       # the whole flow on test data
bash tools/cloud/screenshot.sh docs/screenshots --fresh         # the whole flow on real downloads
godot --headless --path . --script res://tools/net_check.gd     # one small real download
```

`screenshot.sh [outdir] [args]` runs `tools/cloud/capture.gd` under
`xvfb-run -a -s "-screen 0 1280x1024x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy`
(mesa llvmpipe), because `--headless` renders nothing. The capture drives the real flow: the
world map it opens on (`00_world_start`), the city list from its list button, Barcelona map,
cursor, confirm, loading, office (x2, a hovered lot, a selected lot with
its card, then Esc must close it), then plays the game in it (`NN_game_*`: the HUD, the
office's pin pointed at, the office tab opened by clicking it (Esc closes it), a solar's buy
card, bought + undo toast, build card, works with a crane, the office tab from the level line
and the level-up in it, level 2, the bank, a loan sheet, the office tab at Nv 2 and its GERENTE
page, the welcome-back card, a fully grown area x1/x2, the 200 px window), x3 close-up, x1 far, the red
too-close cursor, offices in Tokyo and Warsaw, then the busy-server screen, the traffic
close-up, and the world map (`NN_world_*`): a fourth office placed from it in Valencia (a big
group clicked zooms in, then city -> office; back -> city map -> back -> the world centred on
Valencia), the whole world with the four pins, Europe x8, a city pointed at, Spain x16, the
list Barcelona's pin opens (its office row must open the office), Tokyo, the city list and
back, the 200 px window; last the events (`8N_event_*` / `8N_job_*`, numbered from 80, made to
order in the first office: a flash sale's banner and the lot it opens, a job's banner, each
minigame's intro, mid-play and result through the real input path with its clock stepped by
hand, the pipes and the wires solved frame by frame into `pipes_gif/NNN.png` and
`events_gif/NNN.png`, a VIP's star, the 200 px window
with a banner; `Events.auto` is off for the whole capture, so events never pop up in the other
shots). `docs/screenshots/events/` holds the best ones for Oscar on real Barcelona data and
`wires.gif` / `pipes.gif` (`ffmpeg -framerate 12 -i events_gif/%03d.png` or `pipes_gif/%03d.png`,
cropped to 600x540, halved with nearest and a palette). Leave Valencia out
of `--spot`. Extra args: `--fixture`, `--fresh` (also re-download city maps;
offices are always wiped first), `--spot=city:lat:lon` (repeatable, replaces the places),
`--raw-cache=DIR`. Under Xvfb a `WARNING: Could not set V-Sync mode` line is normal.

World map: `tools/fetch_natural_earth.sh /abs/dir` downloads Natural Earth's 1:50m land,
lakes and country borders (GeoJSON, ~3.3 MB, public domain, `docs/NATURAL_EARTH.md`) outside
the repo; `godot --headless --path . --script res://tools/build_world.gd -- --src=/abs/dir`
bakes `assets/world/world_0..3.png` (300x150 .. 2400x1200 art px, ~265 KB together, palette
colours only: land SL2 dithered SL1 with an SL3 coast rim, sea CYAN_DD with a TEAL3 shore ring,
dotted SL1 borders from level 1, dotted TEAL3 30-degree graticule on open sea; pixel-centre
scanline fill, even-odd per polygon, one-pixel lakes dropped; deterministic), then `--import`.
Only rerun it to change the look. `world_check.gd` (headless) checks the pictures' sizes and
palette, that every city lands on land, the projection round trip, and at every step that each
city is in one group and no two hit boxes overlap. `docs/screenshots/worldmap/` holds the
world map's shots on real data.

Other tools: `bake_check.gd -- --raw=/abs/answer.json --lat= --lon= [--city]` bakes a saved raw
Overpass answer (checks: polygons, every lot faces a street, 20..600 lots per 500 m area, an
office lot, the office's pin on open ground and found again from the file); `bake_check.gd -- --upgrade=/abs/office_v2.json` checks the v2 -> v3 upgrade;
`seed_cache.gd` files a raw answer under the name `--raw-cache` looks for;
`tools/cloud/render_office.gd -- --out=/abs/dir [--file=/abs/office.json] [--tiers]` (under
xvfb-run like the capture) renders saved offices alone (whole drawing + x2 crop; v2 files are
upgraded in memory) in seconds and fails on any pixel off the palette; `--tiers` adds
`<id>_tiers.png`, lots near the office rebuilt at each tier (+ sheds and the office lot), each
outlined in gold and labelled (`docs/screenshots/tiers_valencia.png`); `--redraw` buys,
rebuilds and starts works on four lots (the office's own lot among them) through
`BlockView.redraw_lot`, prints each redraw's
main-thread time, saves `<id>_redraw.png` (before | after) and fails when the result differs
from a fresh drawing by more than a few pixels. `docs/screenshots/office_tab/` shows the
office without a building (Valencia: the start before | after, the office tab, its manager page,
a grown area with the old office lot built high). `docs/screenshots/game/` holds the game's
shots on real Valencia data (`office_before_after_valencia.png`: the old big office | the modest one;
`lot_redraw_valencia.png`: four lots redrawn one at a time). `render_office --redraw` also
compares Traffic's depth and shadow images after the redraws with a fresh drawing's.
`tools/cloud/game_traffic.gd -- --out=/abs/dir [--id=office]` (xvfb-run) opens a saved office in
the real game with a grown save (two works with cranes), lets the cars drive and saves
`game_with_traffic_<city>.png` (x2); then stops a car on a street just behind an empty lot,
builds a tower there through the one-lot redraw and fails if any pixel of the car still shows
(`cars_hide_<city>.png`: before | after, x3). It overwrites `user://save.json`.
`game_check.gd` drives the rules with a fake clock (and the events: none while away, one waiting
through time away, expiry, the pace, determinism, every kind turning up, each offer's effect -
a sale's price, an exprés's half time and its window, a VIP's extra to the second, a buyer's
cash, a job's pay by score and only once - the hourly cap, the event traits, the three
minigames played well, badly and by mashing (the pipes over 400 boards: each has a way, starts
dry and a decent player joins it in time; tapping every tile in turn never joins it, random
taps at most 1 %; half a job scores in between), and saves of pending events and timed effects,
a v2 save, a toilet job from an old save turned pipes and malformed event data) (buy, build, multi-tier, rent, level up and
the free manager, saves, time away and its cap, clock moved back and forth, a broken save, the
bank's limits and an adversarial max-loan + lost income + week away, managers, the builder, the
office's free lot built like any other and its income by level, a v1 save migrated on load).
`tools/cloud/skyline_sheet.gd -- --out=/abs/dir --file=/abs/office.json [--n=16]` (xvfb-run)
builds up to 16 lots near the office as high as they may go, each with its own archetype as
the game picks it (archetypes not shown yet first), into `top_tiers_gallery.png` (x2 cells,
labelled), and `works_vs_built.png` (four of them as building sites | finished); fails on any
pixel off the palette. `tools/cloud/variety_sheet.gd -- --out=/abs/dir --file=/abs/office.json
[--tag=new] [--pair]` (xvfb-run; uses only BlockView, so it also runs on an older checkout for a
before | after) grows every lot to its max tier (`grown_<tag>.png` x2 round the office,
`grown_far_<tag>.png` x1) and to bloque (`bloque_<tag>.png`), `--pair` adds `bloque_vs_max.png`.
`tools/cloud/street_click.gd -- --out=/abs/dir [--id=office]` (xvfb-run, overwrites
`user://save.json`) opens a grown office in the real game, shoots it with no names, clicks a
street and shoots its plate (`click_street_name.png`); fails if a plate shows before the click,
none after it, or it outlives the next click. `docs/screenshots/variety/` holds them for
Valencia (`grown_before_after.png`: the grown area at x2, the twin glass clusters | every lot its
own; `grown_far_before_after.png` the same at x1; `top_tiers_gallery.png`, `works_vs_built.png`,
`bloque_vs_max.png`, `click_street_name.png`).
`tools/cloud/cement_sheet.gd -- --out=/abs/dir --file=/abs/office.json [--tag=new] [--pair=old]
[--spot=name:x:y ...]` (xvfb-run; uses only BlockView, so it runs on an older checkout too) draws
the whole office grown and early (`whole_<tag>_*.png` + their metre -> pixel maps) and with
`--pair` puts an older run beside it, ANTES | AHORA: `grown_before_after.png`,
`early_before_after.png` (x2 round the office) and an x3 close-up per spot; fails on any pixel
off the palette. `docs/screenshots/cement/` holds them for Valencia: the sand turned cement and
planted, `jesus_maria_triangle.png` (spot -75:55), `gran_via_trees.png` (40:-100, the median's
trees off the carriageways).
`docs/screenshots/skyline/` keeps the earlier height-cap work (the four old layouts).
`econ_sim.gd [-- --file=/abs/office.json] [--days=N] [--only=ideal,widget,lazy,loans,abuser,absent,active,active_noev]`
plays kinds of player and prints milestones and snapshots (fixture area by default); it exits 1
if any player ever has interest above the cap or debt that does not shrink with autopay. The
`active` player is the widget one plus a daily session of active play (`SESSION_FIRST` 1 h,
then `SESSION` 30 min) taking events (`TAKE` 80 %, realistic job scores), over five `SEEDS`;
`active_noev` the same sessions without events. With widget and active played it prints how much
sooner active reaches each milestone (geometric mean over the seeds, the luckiest seed, and
without events) and exits 1 unless the average is `RATIO_MIN`..`RATIO_MAX` (1.5-2.5x) and no
milestone's mean passes `MAX_RATIO` (3x); the office's last three milestones are set by its
cranes (`CRANE_BOUND`), the same for everyone, so they are shown but not counted. `docs/screenshots/style_a_side_by_side.png` is the mockup next to the
real Barcelona office.

Traffic: `traffic_check.gd [-- --file=/abs/office.json] [--minutes=6] [--seeds=5]` runs the
three fixture areas, the real Valencia sample and any saved office headless with the window as
the game opens it, each on 5 seeds (the office id, then `id#1`..), and fails when a car leaves
the street, two cars stand on each other (middles < 2 m), a car stands still over 60 s
(`WAIT_MAX`), the traffic hardly moves, two seeds play the same or one seed plays differently
twice (~2 min); it prints the longest wait per seed. `tools/check_areas.gd` (preloaded, no
class_name) gives both checks their areas: the fixtures and `tools/data/valencia_overpass.json`,
a saved Overpass answer around the Gran Via de Ferran el Catolic (ODbL) baked on the spot; a
missing sample fails the checks. `docs/screenshots/traffic/jam_fixed_valencia.gif` (and
`.png`, one frame) is the junction where Sant Ignasi de Loiola joins the Gran Via inside its
queue, before | after the fair turns, at x3: the side street's first car circled with its wait.
The capture ends
with `NN_office_traffic` (the first office again at x3 on its cars).
`tools/cloud/traffic_frames.gd -- --file=/abs/office.json --out=/abs/dir` (xvfb-run) opens an
office in the real game with the traffic clock stopped and stepped by hand: `gif/NNN.png` at
x2 round the busiest junction near the office (one tick apart; its header has the ffmpeg line
that makes `traffic.gif`), `junction_sheet.png`, `hidden.png` (a car behind a building with
and without the depth test) and `BENCH` lines (sim ms per tick, frame times traffic off / on).

Walkers: `walker_check.gd [-- --file=/abs/office.json] [--minutes=5]` runs the fixture areas,
the Valencia sample (and any saved office) with their traffic and fails when a walker leaves
the pavement (onto a carriageway, a lot or a garden) or its crossing, is on the road without
holding the crossing,
two walkers' middles come within 0.3 m, a walker stands under a car, jumps (> 0.5 m a tick) or
stands still over 60 s, a crossing stays busy over 90 s, a car waits over 60 s for people or
stands still over 60 s at all (`CAR_WAIT_MAX`), a busy count is wrong, nobody crosses, or a
seed plays differently (~25 s). It drives the same areas as traffic_check (one seed).
`tools/cloud/walker_frames.gd -- --file=/abs/office.json --out=/abs/dir [--gif=70]` (xvfb-run)
opens an office in the real game (welcome card dismissed), saves `game_x2.png`, waits for
someone to step onto a visible crossing near the office with people around and films
`gif/NNN.png` at x3 one tick apart (the ffmpeg line is in its header), `walkers_sheet.png`
(every 6th frame's middle, x2), `sprites.png` (the atlas, x6) and `BENCH` lines.

**Network in the cloud container**: Overpass hosts must be on the environment's allowlist. In
this container overpass-api.de reset every TLS handshake, overpass.kumi.systems timed out and
overpass.private.coffee answered (slowly); the downloader's mirror rotation copes. When nothing
answers, work with `--fixture` and never present fixture shots as real data.

**What "fail" means**: any `SCRIPT ERROR`, any line starting `ERROR:`, a `Parse Error`, or a
non-zero exit. Fix it, never commit it. Note `draw_colored_polygon` errors on shapes it cannot
triangulate; `BlockView._fill` checks first, keep using it.

## Git rules

- **Cloud session**: develop and commit on the branch the session was assigned (e.g.
  `ccr-...`), push with `git push -u origin <that branch>`. Never push to `main` from the cloud.
- Remote: `sonoq/tiny-realtor` on GitHub.
- Verify (import + headless run + screenshot) before every commit.
