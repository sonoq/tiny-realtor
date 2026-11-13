class_name Rules
extends RefCounted

# The office numbers from docs/DESIGN.md, in one place.

# everything within this many metres of an office is downloaded once, when it is placed
const MAX_RADIUS := 500.0
# the radius the office can use at each level (level 1 first); levelling never needs the network
const ACTIVE_RADIUS: Array[float] = [150.0, 225.0, 300.0, 400.0, 500.0]
# offices stay this far apart (2 x MAX_RADIUS + a margin), so each one is a self-contained
# island and two snapshots taken on different dates never have to be stitched together
const MIN_SEPARATION := 1500.0


static func active_radius(level: int) -> float:
	return ACTIVE_RADIUS[clampi(level, 1, ACTIVE_RADIUS.size()) - 1]


# the nearest office to a point (any city), with its distance in metres; {} when there are none
static func nearest_office(lat: float, lon: float) -> Dictionary:
	var best := {}
	var best_d := INF
	for o in Store.offices():
		var d := Geo.distance(lat, lon, o["lat"], o["lon"])
		if d < best_d:
			best_d = d
			best = {"office": o, "distance": d}
	return best


static func too_close(lat: float, lon: float) -> bool:
	var near := nearest_office(lat, lon)
	return not near.is_empty() and float(near["distance"]) < MIN_SEPARATION
