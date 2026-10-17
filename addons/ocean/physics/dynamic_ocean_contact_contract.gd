extends RefCounted
## Caller-owned contact history for OceanQueryNative.sample_dynamic_contact*.
## One row per contact; reset VALID on loss, teleport or a new ocean instance.
const STRIDE := 27
const VALID := 0
const RESIDUAL := 13
const ITERATIONS := 14
const QX := 15
const QZ := 16
const STATUS := 17
const WORLD_X := 18
const WORLD_Z := 19
const FIELD_TIME := 20
const CONFIG_VERSION := 21
const GENERATION := 22
const SEARCH_RADIUS := 23
const MATERIAL_DELTA := 24
const HORIZONTAL_DETERMINANT := 25
const PATH_STEPS := 26
enum Status { CONTINUED, REACQUIRED_LOCAL, REACQUIRED_GLOBAL, FAILED }

static func invalidate(rows: PackedFloat64Array, contact_index: int) -> PackedFloat64Array:
	# Packed arrays are values: explicitly assign the returned state at the caller.
	var offset := contact_index * STRIDE
	if offset >= 0 and offset + STRIDE <= rows.size(): rows[offset + VALID] = 0.0
	return rows
