class_name OceanWaterContactContext
extends RefCounted
## Consumer-only data. No native object, spectrum, grids or FFT clock.
## Inactive contexts hold state; active values are moved to the provider. Clearing
## slots after loading avoids PackedArray COW copies in the existing query code.
const LocalContacts = preload("res://addons/ocean/physics/water/local_surface_contact_state.gd")
var provider_id: int = 0
var wave_owner_id: int = 0
var reset_epoch: int = 0
var mode_epoch: int = 0
var _contact_positions: Variant = PackedVector3Array()
var _selected_contact_cache: Variant = _empty_samples()
var _comparison_contact_cache: Variant = _empty_samples()
var _contact_cache_cursor: Variant = 0
var _contact_cache_waiting_for_comparison: Variant = false
var _local_contacts: Variant = LocalContacts.new()
var _local_patch_center: Variant = Vector3.ZERO
var _local_geometry_rows: Variant = PackedFloat64Array()
var _contact_delta_s: Variant = 1.0 / 60.0
var local_surface_last_build_us: Variant = 0
var local_surface_last_query_us: Variant = 0
var local_surface_contact_query_us: Variant = 0
var local_surface_fallback_count: Variant = 0
var local_surface_branch_jump_count: Variant = 0
var local_surface_build_count: Variant = 0
var local_surface_failure_reason: Variant = ""
var local_surface_build_tick: Variant = -1
var local_surface_patch_summary: Variant = {}
var local_surface_missed_queries: Variant = 0
var local_surface_multi_hit_queries: Variant = 0
var _local_query_debug_rows: Variant = _empty_rows()
var _warm_q_by_position: Variant = PackedVector3Array()
var _contact_previous_world: Variant = PackedVector2Array()
var _contact_previous_heights: Variant = PackedFloat32Array()
var _contact_seed_pending: Variant = true
var contact_oracle_seed_count: Variant = 0
var contact_oracle_seed_failures: Variant = 0
var contact_oracle_seeded_contacts: Variant = 0
var _contact_seed_retry_after_ms: Variant = 0
var _contact_seed_last_ms: Variant = -1000000
var _tracked_contact_failure_ticks: Variant = PackedInt32Array()
var _tracked_contact_last_height: Variant = PackedFloat32Array()
var _tracked_contact_last_velocity: Variant = PackedFloat32Array()
var _tracked_contact_last_normal: Variant = PackedVector3Array()
var _query_debug_rows: Variant = _empty_rows()

static func _empty_samples() -> Array[WaterSample3D]:
	return []
static func _empty_rows() -> Array[Dictionary]:
	return []
