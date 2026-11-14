# Natural Earth (world map data)

The world map (`assets/world/world_0.png` .. `world_3.png`) is drawn from **Natural Earth**
vector data, 1:50m scale:

- `ne_50m_land` (land polygons)
- `ne_50m_lakes` (lakes, cut back out of the land)
- `ne_50m_admin_0_boundary_lines_land` (country borders, drawn dotted)

Source: <https://www.naturalearthdata.com>, GeoJSON copies from
<https://github.com/nvkelso/natural-earth-vector> (`geojson/`). About 3.3 MB downloaded once at
dev time with `tools/fetch_natural_earth.sh`, baked by `tools/build_world.gd` into the four PNGs
(about 265 KB together, palette colours only). The game never downloads them.

**Licence: public domain.** Natural Earth's terms of use: "All versions of Natural Earth raster
+ vector map data found on this website are in the public domain. You may use the maps in any
manner, including modifying the content and design, electronic dissemination, and offset
printing." No permission is needed and no credit is required; we credit it anyway: "Made with
Natural Earth. Free vector and raster map data @ naturalearthdata.com." The world map's footer
says NATURAL EARTH next to the OpenStreetMap credit.

Country borders are Natural Earth's de facto lines and are shown only as faint dots for
orientation; they are not a statement about any border.

---

*En español:* el mapamundi sale de los datos de **Natural Earth** (escala 1:50m: tierras, lagos y
fronteras), que son de **dominio público**: se pueden usar y cambiar sin pedir permiso. Se
descargan una sola vez al preparar el juego y se convierten en cuatro imágenes de pixel art
(una por nivel de zoom); el juego no descarga nada para el mapamundi. Aun así lo citamos en el
pie del mapa.
