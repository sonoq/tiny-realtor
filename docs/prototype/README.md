# Prototipo del estudio de viabilidad

Scripts de Python (Pillow + Shapely) e imágenes del estudio de `docs/FEASIBILITY.md`. No forman parte del juego.

**Los datos son una muestra hecha a mano**, no datos reales: en aquella sesión en la nube la API de Overpass (OpenStreetMap) estaba bloqueada. `tools/make_sample.py` inventa un trozo con forma de Eixample (manzanas de 113 m con chaflanes, calles de 20 m, giro de 45°) en el mismo formato que devuelve Overpass.

- `tools/make_sample.py` → `data/block_raw_overpass.json` (la muestra con formato de Overpass)
- `tools/bake_block.py` → `data/block_saved.json` (parcelas, alturas y rejilla de 4 m ya calculadas; es el fichero que usa el juego como `data/sample_block.json`)
- `tools/render_iso.py` → `iso_overview.png`, `iso_window_600.png` (el dibujo isométrico)
- `tools/plot_map.py` → `plots_map.png` (las parcelas vistas desde arriba)
