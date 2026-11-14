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
- **Current state: map prototype.** Pick a city, see its real map, place offices, download and
  bake each office's area once from OpenStreetMap, view it in isometric pixel art. No gameplay
  yet (no money, buying or building).
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
- `office_view.gd` (`OfficeView`) - one saved office: shows `BlockView.texture` (drawn once, a
  frame or two after opening; `is_drawn()`) at x1/x2/x3 (x2 = the mockup), with the mockup's HUD:
  back + neighbourhood, "1 / N tuyas" (lots owned / lots), level bar with the active/max radius,
  "+$" pops over owned roofs, street names sheared along their streets in the pixel font.
  Lots are pointed at through BlockView's pick image (`lot_under`): hover = a cyan outline of
  everything the lot shows (grey when outside the active radius, still selectable), click =
  `select` (gold outline, slid up out from under the card) and a card (street, zone + tier,
  m2 / frontage / corner, placeholder price, En venta / Tuyo / Fuera de tu radio, X button).
  Esc / back closes the card before leaving. A saved v2 area is upgraded to v3 on open
  (`BlockBaker.upgrade`) and written back.

**Data and rules**
- `city_db.gd` (`CityDb`) - the shipped cities (id, Spanish name, country, map-box centre).
- `rules.gd` (`Rules`) - `MAX_RADIUS` (500 m), `ACTIVE_RADIUS` per level (150 m at level 1),
  `MIN_SEPARATION` (1.5 km), nearest office / too-close checks (great-circle distance).
- `store.gd` (`Store`) - everything under `user://`: `cities/<city>.json`,
  `offices/index.json`, `offices/<id>.json`. Writes go through a temp file. Offices and city maps
  made of fixture data are kept apart from real ones (never shown together).

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
  `garden`, pre-built tiers, then the office's lot. `upgrade()` re-parcels a v2 file from its
  saved blocks and roads (same result as a fresh bake).
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
  `street_labels()` gives label spots for the overlay; `pops` the roofs income pops rise from.
  A fourth pass, **depth**, replays every object in painter's order with each pixel's ground
  depth (x - y, bigger = nearer; `depth_code()`: `(d + 1024) * 16` in r + g * 256, 0 = bare
  ground, 65535 = price tags) as `depth_tex`, kept with the shadow mask (`shade_tex`) for
  Traffic.
- `area_builder.gd` (`AreaBuilder`) - a v3 area -> ops: the ground (pavement, asphalt, pedestrian
  paving, rails, parks, water, gardens, lane dashes, zebra crossings at junctions), shadows, the
  earth slab, the dashed gold ring, and each lot as a development of its tier, laid out at draw
  time from the lot's polygon, `fronts`, tier, levels, zone and owned flag (so a lot can be
  rebuilt at any tier without touching the file), with the mockup's recipes: 0 dirt lot with
  fence posts, weed patches, bushes and a "$" sign (in the radius); 1 a row of houses with
  hedged gardens (`Plotter.sites`, `SITE_DEPTH/FRONT`); 2 bigger houses with pools; 3
  apartment blocks of mixed heights and facades round a courtyard garden; 4 one to three towers
  (`_spots`: axis-aligned squares well inside the lot) on a paved plaza; 5 a skyscraper with a
  gold crown on a podium on a plaza; industrial 1-2 = sheds in a yard. The office's lot is
  tier-3 blocks with the REALTOR building on the site nearest the clicked point. Owned = teal
  roofs + cyan flags. Every object records its `lot`; buildings fade per lot (`lots[i].active`
  = centroid inside the radius). Trees (gardens, parks, street trees), lamps and people inside
  the active radius, cars, price tags (`price_tag`, `price_of`) on the nearest signed lots. All
  placement by stable hashes.
- `painter.gd` (`Painter`) - records one object's ops (POLY, WALL, RECT, TEX) with the mockup's
  primitives: `wall` (wall_pixels), `prism`, `face3d`, `pitched`, Bresenham `line`. POLY ops
  from `flat`/`face3d` carry each corner's ground depth, WALL ops their two ends' (depth pass).
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
  where they cross or touch (`_split_crossings`), junctions under `MERGE` (8 m) apart or whose
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
  `frozen` + `run(n)` let tools step it.
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
- Placeholders until there is an economy: price tags = area x `AreaBuilder.PRICE_M2`, "+$" pops
  without amounts, only the office lot is owned (data's `owned` is honoured).

## Office area format (`tiny-realestate-block` v3)

Metres, x east / y north, already turned by `rotation_deg` so streets follow the axes; origin =
the office. Top level: `format`, `format_version` 3, `source`, `attribution`, `center {lat, lon}`,
`rotation_deg`, `radius_m`, `seed`, `fetched`, `data_source` (`osm` | `fixture`), `stats`,
`office_plot` (lot id or ""), `office` (the meta also kept in the index: id, city, name, lat,
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
bash tools/cloud/screenshot.sh docs/screenshots --fixture       # the whole flow on test data
bash tools/cloud/screenshot.sh docs/screenshots --fresh         # the whole flow on real downloads
godot --headless --path . --script res://tools/net_check.gd     # one small real download
```

`screenshot.sh [outdir] [args]` runs `tools/cloud/capture.gd` under
`xvfb-run -a -s "-screen 0 1280x1024x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy`
(mesa llvmpipe), because `--headless` renders nothing. The capture drives the real flow: city
list, Barcelona map, cursor, confirm, loading, office (x2, a hovered lot, a selected lot with
its card, then Esc must close it; x3 close-up, x1 far), the red
too-close cursor, offices in Tokyo and Warsaw, then the busy-server screen. Extra args: `--fixture`, `--fresh` (also re-download city maps;
offices are always wiped first), `--spot=city:lat:lon` (repeatable, replaces the places),
`--raw-cache=DIR`. Under Xvfb a `WARNING: Could not set V-Sync mode` line is normal.

Other tools: `bake_check.gd -- --raw=/abs/answer.json --lat= --lon= [--city]` bakes a saved raw
Overpass answer (checks: polygons, every lot faces a street, 20..600 lots per 500 m area, an
office lot); `bake_check.gd -- --upgrade=/abs/office_v2.json` checks the v2 -> v3 upgrade;
`seed_cache.gd` files a raw answer under the name `--raw-cache` looks for;
`tools/cloud/render_office.gd -- --out=/abs/dir [--file=/abs/office.json] [--tiers]` (under
xvfb-run like the capture) renders saved offices alone (whole drawing + x2 crop; v2 files are
upgraded in memory) in seconds and fails on any pixel off the palette; `--tiers` adds
`<id>_tiers.png`, lots near the office rebuilt at each tier (+ sheds and the office lot), each
outlined in gold and labelled (`docs/screenshots/tiers_valencia.png`). `docs/screenshots/style_a_side_by_side.png` is the mockup next to the
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
