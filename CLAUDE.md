# Tiny Realty (working title)

An idle real-estate tycoon that lives in a small always-on-top desktop widget, same format as the
owner's other game Tiny Battlegrounds. You open real-estate offices (oficinas inmobiliarias) in
real neighbourhoods, buy plots around them, earn rent and build up from empty lots to skyscrapers.
The map is REAL data from OpenStreetMap, drawn as procedural isometric pixel art made with maths.

- Engine: **Godot 4.7.1**, GL Compatibility renderer, GDScript only, no autoloads, no addons.
- Window: 600x600 logical canvas, borderless, always on top, not resizable, stretch mode
  `canvas_items`, nearest texture filter, max 60 fps.
- Main scene `res://main.tscn` (one node running `scripts/main.gd`).
- **Current state: skeleton only.** No gameplay, no save, no network. The one scene proves the
  data -> isometric pipeline on a hand-made sample block.

## Design (decided so far)

Full text, in Spanish, in `docs/DESIGN.md` (it wins over the older `docs/FEASIBILITY.md`).

- World map (pixel art from Natural Earth coastlines, later) -> pick a city from a shipped
  GeoNames list (no live geocoding: Nominatim forbids autocomplete) -> city map (neighbourhood
  names + main avenues from Overpass, a few KB) -> click to place an office.
- Placing an office downloads, ONCE, everything within its max radius (~500 m) from the public
  Overpass API (no own server; polite User-Agent, retry + mirror fallback, "server busy" message),
  bakes it into plots and saves it locally forever (~200-500 KB). It never updates.
- Office level grows the active radius (e.g. 150 m at level 1) inside the downloaded one, so
  levelling never needs the network. Offices are >= 2x max radius + margin apart (~1.5 km), so
  each is a self-contained island; never stitch snapshots taken at different dates.
- Plots: buy, rent per minute (offline too, capped), tiers Solar -> Casa -> Urbanizacion (merge
  2-4 plots) -> Bloque de pisos -> Torre -> Rascacielos. Real plot size and neighbourhood height
  cap building; rezoning (recalificacion) is a goal. Value modifiers from real data (parks, metro,
  schools, shops, corners, full block). One-click events, prestige ("salir a bolsa"), day/night.
- Licence: ODbL. "© OpenStreetMap contributors" must stay visible on screen (the HUD reserves it).

## The user

The owner is **Oscar**. He speaks **Spanish** and **does not read code**. Talk to him in Spanish,
in terms of what he can see and do in the game, never in terms of functions or files. Show, don't
describe: in the cloud, render screenshots (below) and look at / share the PNGs.

## Architecture map

- `scripts/main.gd` - root of `main.tscn`. Builds a SubViewport the size of the whole block,
  renders `BlockView` into it once (`UPDATE_ONCE`), shows it through a Sprite2D scaled x2
  (nearest), draws the HUD (title bar, OSM credit line). Right-drag pans (`pan_to`), left-drag
  moves the OS window, Esc quits.
- `scripts/block_view.gd` (`BlockView`) - loads a baked block JSON and draws it in `_draw()`:
  earth slab, paving, roads (quads from centre line + width), lane dashes, greens, empty lots with
  a for-sale sign, cast shadows, then buildings sorted far-to-near and extruded (viewer-facing
  walls shaded by facing, window grid with a few lit, roof with parapet, rooftop huts).
  Projection: `u = x, v = -y`, screen `((u - v) * SCALE, (u + v) * SCALE / 2 - z * RISE)`.
- `data/sample_block.json` - format `tiny-realestate-block` v1 (from the prototype's
  `bake_block.py`): `roads[] {name, kind, width, line}`, `greens[] {kind, poly}`,
  `plots[] {id, cat, osm_type, levels, height_m, area_m2, poly, owned, tier}`, and a 4 m `grid`.
  Metres, x east / y north, already rotated so streets follow the axes. Hand-made, NOT OSM data.
- `docs/prototype/` - the Python prototype (Pillow + Shapely) the sample came from; not shipped.

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
bash tools/cloud/screenshot.sh                    # PNGs of the game into docs/screenshots/
```

`screenshot.sh` runs `tools/cloud/capture.gd` under
`xvfb-run -a -s "-screen 0 1280x1024x24" godot --path . --rendering-driver opengl3 --audio-driver Dummy`
(mesa llvmpipe), because `--headless` renders nothing. It writes `01_block.png` (opening view),
`02_block_panned.png` and `03_block_whole.png` (the whole block texture x2). Under Xvfb a
`WARNING: Could not set V-Sync mode` line is normal.

**What "fail" means**: any `SCRIPT ERROR`, any line starting `ERROR:`, a `Parse Error`, or a
non-zero exit. Fix it, never commit it. Note `draw_colored_polygon` errors on shapes it cannot
triangulate; `BlockView._fill` checks first, keep using it.

## Git rules

- **Cloud session**: develop and commit on the branch the session was assigned (e.g.
  `ccr-...`), push with `git push -u origin <that branch>`. Never push to `main` from the cloud.
- There is no remote yet; the owner will create one.
- Verify (import + headless run + screenshot) before every commit.
