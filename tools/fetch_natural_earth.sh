#!/usr/bin/env bash
# Dev only: downloads the three Natural Earth 1:50m layers the world map is baked from
# (public domain, https://www.naturalearthdata.com; GeoJSON copies from the nvkelso/natural-earth-vector
# repository) into a folder OUTSIDE the repo. Then run tools/build_world.gd on it.
#
#   bash tools/fetch_natural_earth.sh /abs/ne
set -euo pipefail
DIR="${1:?usage: fetch_natural_earth.sh /abs/dir}"
BASE="https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson"
mkdir -p "$DIR"
for f in ne_50m_land ne_50m_lakes ne_50m_admin_0_boundary_lines_land; do
	curl -sSfL -o "$DIR/$f.geojson" "$BASE/$f.geojson"
	echo "$f.geojson $(wc -c < "$DIR/$f.geojson") B"
done
