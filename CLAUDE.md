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
- **Current state: first gameplay loop.** Pick a city, see its real map, place offices
  (download and bake each office's area once from OpenStreetMap), and play in the office view:
  rent per minute (offline too, capped), buy lots in the office's radius, build tiers (works with
  scaffolding and cranes), the office tab (the office is a business, not a building: level up
  for a bigger radius and more commissions, the builder switch, one manager per office with
  pixel portraits, rarity and bonuses, greyed PRONTO rows; on the map only a gold pin marks it)
  and the bank (three loans that can never choke you, autopay). The game is saved under
  `user://`. The design and every number: `docs/GAMEPLAY.md` (Spanish),
  `scripts/economy.gd`, `tools/econ_sim.gd`.
- **Visual style: A, "sibling of Tiny Battlegrounds" (decided by Oscar).** The spec is the
  mockup in `docs/style_mockups/a_battlegrounds/` (`gen_battlegrounds.py` + its PNGs); the other
  three mockups there were the rejected options. See "Style A" below.

## Design (decided so far)

Full text, in Spanish, in `docs/DESIGN.md` (it wins over the older `docs/FEASIBILITY.md`).

- World map (pixel art from Natural Earth coastlines, later) -> pick a city from a shipped
  GeoNames list (no live geocoding: Nominatim forbids autocomplete) -> city map (neighbourhood
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
  click; Esc = back, quits from the city list) and the download jobs: `Overpass` fetch -> parse
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
- `city_pick.gd` (`CityPick`) - the shipped city list, 12 a page with < > arrows.
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
  neighbourhood ("N / M tuyos"), street names as `LABEL_STYLE` says (`StreetNames`; the static
  `labels` lets tools switch it): PAINTED (default) has them in the drawing and only adds a
  plate for the street under the pointer (`_street_under`, `HOVER_REACH`); MICRO / PLATES place
  them over the map per view (`_labels_now`: each name once, nearest the view's middle first,
  never over a lot or a building in the pick image, never over the pin).
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
  queue). The welcome-back card ("Mientras no estabas: +$X"). Holds the panel:
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
- `faces.gd` (`Faces`) - manager portraits: 16x16 pixel busts from a seed (skin, hair style and
  colour, eyes, glasses, moustache, suit and tie or blouse), palette colours with an ink rim,
  drawn at whole multiples; `badge` frames one in its rarity's colour.

**Data and rules**
- `economy.gd` (`Economy`) - every number of the game (tiers: build cost, time, rent; land;
  pre-built markup; plusvalía and works inflation; office levels: cost, the office's own
  income `OFFICE_INCOME` (commissions), cranes, offline hours; `OFFICE_LOT_TIER` (the free lot
  starts a solar); later offices; the three loans and the bank's caps; managers: hire prices,
  pool odds, traits) and what a lot is worth from real data (`lot_infos`: area factor, location
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
  inflation one at a time would. `apply` writes the game's lots into a baked area.
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
  `street_labels()` gives label spots for the overlay (short names); `names` paints them on the
  asphalt instead (AreaBuilder `names`); `pops` the roofs income pops rise from;
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
  rascacielos as `Skyline` plans them (`_skyline` / `_piece`: each group one object, each mass
  in it ringed in ink by `Painter.ink_under`) on a paved plaza; industrial 1-2 = sheds in a
  yard; a plot with `works` = a building site (fence, concrete floors under a skeleton,
  scaffolding, a tower crane from bloque up; torres / rascacielos use the plan's footprints and
  heights). With `names` on (the game, PAINTED), `_paint_names` paints `StreetNames.painted`
  into the ground right after the lane marks (the dashes under a name are taken out) and every
  tree laid out later keeps off them (`_on_name`), so a lot redraw keeps them. The office has no building: `_office_mark` draws a dashed gold ring on the ground
  (`pre`, under everything that stands) and a gold map pin sprite (`office`, the city map's
  house in its head; an object of no lot, so it sorts, outlines and goes through the depth pass
  like a lamp but never into the pick image) at `OfficeMark.at`; street trees, lamps, people and
  garden trees keep `MARK_CLEAR` from it. The lot the office was placed on is an ordinary lot.
  Owned = teal roofs + cyan flags; an owned solar flies a flag instead of the sale sign.
  Each lot's ground ops (`lot_ground`), shadows (`lot_shadows`) and objects are kept apart so
  `rebuild_lot` can lay it out again; `lots[i].roof` is where its pops rise; `tags` off leaves the
  price tags to the game. Every object records its `lot`; buildings fade per lot (`lots[i].active`
  = centroid inside the radius). Trees (gardens, parks, street trees), lamps and people inside
  the active radius, cars, price tags (`price_tag`, `price_of`) on the nearest signed lots. All
  placement by stable hashes.
- `skyline.gd` (`Skyline`) - the two top tiers as plans (data only; AreaBuilder draws them and
  lays their works out from them). **Height cap** so a grown area reads in the widget: torres
  roofs `TOWER_Z` 30-42 px + a 5 px setback (+ a podium in B), rascacielos' tallest roof
  `SKY_Z` 52-60 px + a 7 px spire, the others of a lot stepped down (`STAGGER`); `top()` is
  what `AreaBuilder.top_of` and the live headroom use. The tiers differ by count, glass and
  gold, not height. Four layouts, `AreaBuilder.SKYLINE_STYLE` picks one (`AreaBuilder.skyline`
  lets tools switch it): CLUSTER A (staggered slender glass towers), BRIDGES B (default: towers
  on a lawn-roofed podium, rascacielos joined by gold sky bridges), MEGA C (a terraced block,
  roof gardens, a helipad), RING D (towers round a garden with a fountain).
- `street_names.gd` (`StreetNames`) - street names for the office view: `short()` (generic
  word dropped or abbreviated: "Carrer d'Àngel Guimerà" -> ANGEL GUIMERA, Avinguda -> AV.,
  accents dropped for the micro font), `runs()` (named streets' straight stretches),
  `painted()` (B: names in the micro font painted on the asphalt in `PAINT_INK`, on straight
  stretches of 8 m+ streets clear of junctions, sheared column by column to the street's slope,
  each name at most `PAINT_REPEAT` times; from the streets alone). The four looks: MICRO A,
  PAINTED B (default), PLATES C, HOVER D (`OfficeView.LABEL_STYLE`).
- `painter.gd` (`Painter`) - records one object's ops (POLY, WALL, RECT, TEX) with the mockup's
  primitives: `wall` (wall_pixels), `prism`, `face3d`, `pitched`, Bresenham `line`. POLY ops
  from `flat`/`face3d` carry each corner's ground depth, WALL ops their two ends' (depth pass).
  `ink_under(start)` puts a one-pixel ink silhouette under the ops since `start` (a sprite's
  ink copy carries a 4th element), so masses sharing one object still read apart.
- `world_shader.gd` (`WorldShader`) - the two shaders, generated with the palette's names: the
  facade shader (walls per pixel: apartment, office, house, tower, sky, plain, skeleton,
  scaffold, slab, cab, shed, ink; sprites from the atlas) and the ground shader.
- `depth_sort.gd` (`DepthSort`) - painter's order: separating axis between footprint hulls for
  every pair whose screen boxes overlap, then a topological sort (fixes long thin plots).
- `pal.gd` (`Pal`), `iso.gd` (`Iso`), `sprites.gd` (`Sprites`) - see "Style A".
- `docs/prototype/` - the Python prototype (Pillow + Shapely); its `block_raw_overpass.json` is
  the hand-made Eixample sample the fixture uses. Not shipped.

**Traffic** (moving cars over the office drawing; `docs/screenshots/traffic/`)
- `road_net.gd` (`RoadNet`) - the area's roads (pedestrian streets aside) as lanes: lines split
  where they cross or touch (`split_crossings`), junctions under `MERGE` (8 m) apart or whose
  boxes overlap merged;
  a two-way edge gets one lane each way (two on 18 m+ avenues), a one-way edge (`oneway`) one
  to three lanes its way, right-hand (left-hand for `Traffic.LEFT_HAND` countries); each lane
  is pulled back from its junctions until clear of every street meeting it at an angle
  (`_trim_at`). Junctions are crossed on **connectors**, cubic curves from lane end to lane
  start, bent round the lanes' corner, re-routed via the junction when they would leave the
  asphalt, made lazily (`connector(a, b)`); `conflict(c1, c2)` = they pass within 2.4 m (two
  from the same lane never conflict). `choose()` picks the next lane: no U-turn unless a dead
  end, no hairpins or "rough" curves, avenues and straight on preferred. A one-way street with
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
  standing along it (`_swept_clear`; while something does the car is `held` and the others do
  not give way to it), clear of every reserved conflicting connector, nobody free to go
  waiting longer for a conflicting one, room on the street beyond; when that street is too
  short to wait on, the next junction is reserved in the same go (`nxt2`). Safeguards (`_would_hit`, `_into_way`) keep footprints apart in odd
  geometry; who waits for whose junction decides who gives way, so it never deadlocks.
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
  radius after a level-up.
- `car_sprites.gd` (`CarSprites`) - the vehicles (5 car colours, taxi, 2 vans, bus) in 16
  headings, with and without brake lights, drawn once per session with Painter + the facade
  shader + ink outline like AreaBuilder's parked cars, read back to palette indices.
- AreaBuilder keeps static cars only parked at the kerb: both kerbs of 12-18 m streets (whose
  lanes sit at 0.22 of the width from the middle), one kerb of 8.5-10 m one-way streets (one
  lane down the middle); BlockBaker keeps each road's `oneway`.

## Style A (the look, and the rules that keep it)

The office view is the mockup's renderer ported to the GPU, pixel for pixel in spirit:
- **One palette** (`Pal`, 74 colours from `gen_battlegrounds.py`: Battlegrounds' slate/ink/gold/
  cyan/mint/red plus the city ramps CRM OCH SAL STN TER TIL TEAL GLS CON). Every pixel of the
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

## Save format (`tiny-realtor-save` v2, `user://save.json`)

Written through `save.json.tmp`, the previous file kept as `save.json.bak`.
`format`, `version` 2, `money`, `seen` (unix seconds paid up to; only grows), `created`,
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
godot --headless --path . --script res://tools/traffic_check.gd # 10 simulated min of traffic
godot --headless --path . --script res://tools/game_check.gd   # the game's rules, saves, bank
godot --headless --path . --script res://tools/econ_sim.gd     # pacing table + bank promises
bash tools/cloud/screenshot.sh docs/screenshots --fixture       # the whole flow on test data
bash tools/cloud/screenshot.sh docs/screenshots --fresh         # the whole flow on real downloads
godot --headless --path . --script res://tools/net_check.gd     # one small real download
```

`screenshot.sh [outdir] [args]` runs `tools/cloud/capture.gd` under
`xvfb-run -a -s "-screen 0 1280x1024x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy`
(mesa llvmpipe), because `--headless` renders nothing. The capture drives the real flow: city
list, Barcelona map, cursor, confirm, loading, office (x2, a hovered lot, a selected lot with
its card, then Esc must close it), then plays the game in it (`NN_game_*`: the HUD, the
office's pin pointed at, the office tab opened by clicking it (Esc closes it), a solar's buy
card, bought + undo toast, build card, works with a crane, the office tab from the level line
and the level-up in it, level 2, the bank, a loan sheet, the office tab at Nv 2 and its GERENTE
page, the welcome-back card, a fully grown area x1/x2, the 200 px window), x3 close-up, x1 far, the red
too-close cursor, offices in Tokyo and Warsaw, then the busy-server screen. Extra args: `--fixture`, `--fresh` (also re-download city maps;
offices are always wiped first), `--spot=city:lat:lon` (repeatable, replaces the places),
`--raw-cache=DIR`. Under Xvfb a `WARNING: Could not set V-Sync mode` line is normal.

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
`game_check.gd` drives the rules with a fake clock (buy, build, multi-tier, rent, level up and
the free manager, saves, time away and its cap, clock moved back and forth, a broken save, the
bank's limits and an adversarial max-loan + lost income + week away, managers, the builder, the
office's free lot built like any other and its income by level, a v1 save migrated on load).
`tools/cloud/skyline_sheet.gd -- --out=/abs/dir --file=/abs/office.json [--only=0,2]` (xvfb-run)
renders the four skyline layouts side by side (two lots as torres, rascacielos and works, and
the area fully grown at x2) into `skyline_options.png`; `tools/cloud/labels_sheet.gd --
--out=/abs/dir [--id=office] [--pan=x,y]` (xvfb-run, overwrites `user://save.json`) opens a
saved office grown in the real game and shoots the four street-name looks at x2 with traffic
(`labels_options.png`, `labels_final.png` = the look in use pointing at a street).
`docs/screenshots/skyline/` holds them for Valencia, plus `skyline_before_after.png` (the grown
area at x2, the old 170 px skyscrapers | the capped clusters) and `tiers_new.png`.
`econ_sim.gd [-- --file=/abs/office.json] [--days=N] [--only=ideal,widget,lazy,loans,abuser,absent]`
plays kinds of player and prints milestones and snapshots (fixture area by default); it exits 1
if any player ever has interest above the cap or debt that does not shrink with autopay. `docs/screenshots/style_a_side_by_side.png` is the mockup next to the
real Barcelona office.

Traffic: `traffic_check.gd [-- --file=/abs/office.json] [--minutes=10]` runs the three fixture
areas (and any saved office) headless with the window as the game opens it and fails when a
car leaves the street, two cars stand on each other (middles < 2 m), a car stands still over
120 s, the traffic hardly moves, or one seed plays differently twice (~25 s). The capture ends
with `NN_office_traffic` (the first office again at x3 on its cars).
`tools/cloud/traffic_frames.gd -- --file=/abs/office.json --out=/abs/dir` (xvfb-run) opens an
office in the real game with the traffic clock stopped and stepped by hand: `gif/NNN.png` at
x2 round the busiest junction near the office (one tick apart; its header has the ffmpeg line
that makes `traffic.gif`), `junction_sheet.png`, `hidden.png` (a car behind a building with
and without the depth test) and `BENCH` lines (sim ms per tick, frame times traffic off / on).

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
