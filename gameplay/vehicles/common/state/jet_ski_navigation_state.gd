class_name JetSkiNavigationState
extends RefCounted

var navigation_state: JetSkiTypes.NavigationState = (
	JetSkiTypes.NavigationState.PARTIALLY_SUBMERGED
)

var current_contact_mask: int = 0
var previous_contact_mask: int = 0
var new_contact_mask: int = 0
var lost_contact_mask: int = 0

var dry_contact_time: float = 0.0

var has_water_support: bool = false
var has_solid_support: bool = false
var has_any_support: bool = false
var previous_has_any_support: bool = false
var true_takeoff_this_tick: bool = false

var solid_support_contact_count: int = 0
var physical_contact_count: int = 0
var physical_contact_delta_velocity: float = 0.0
var physical_contact_position: Vector3 = Vector3.ZERO

var current_airtime: float = 0.0
var last_airtime: float = 0.0
var maximum_recorded_airtime: float = 0.0

var takeoff_position: Vector3 = Vector3.ZERO
var takeoff_linear_velocity: Vector3 = Vector3.ZERO

var landing_state_time_remaining: float = 0.0

var last_landing_position: Vector3 = Vector3.ZERO
var last_landing_normal_speed: float = 0.0
var last_landing_intensity: float = 0.0
var last_landing_contact_mask: int = 0
var last_landing_contact_count: int = 0
var last_landing_entry_type: JetSkiTypes.LandingEntryType = (
	JetSkiTypes.LandingEntryType.UNKNOWN
)

var has_ever_contacted_water: bool = false
var has_confirmed_airborne: bool = false
var deep_submersion_latched: bool = false

var water_entry_count: int = 0
var water_exit_count: int = 0
var hard_landing_count: int = 0
var deep_submersion_count: int = 0

var navigation_initialized: bool = false
var support_state_initialized: bool = false


func reset_runtime_state() -> void:
	navigation_state = JetSkiTypes.NavigationState.PARTIALLY_SUBMERGED
	current_contact_mask = 0
	previous_contact_mask = 0
	new_contact_mask = 0
	lost_contact_mask = 0
	dry_contact_time = 0.0
	has_water_support = false
	has_solid_support = false
	has_any_support = false
	previous_has_any_support = false
	true_takeoff_this_tick = false
	solid_support_contact_count = 0
	physical_contact_count = 0
	physical_contact_delta_velocity = 0.0
	physical_contact_position = Vector3.ZERO
	current_airtime = 0.0
	takeoff_position = Vector3.ZERO
	takeoff_linear_velocity = Vector3.ZERO
	landing_state_time_remaining = 0.0
	has_ever_contacted_water = false
	has_confirmed_airborne = false
	deep_submersion_latched = false
	navigation_initialized = false
	support_state_initialized = false


func clear_statistics() -> void:
	last_airtime = 0.0
	maximum_recorded_airtime = 0.0
	last_landing_position = Vector3.ZERO
	last_landing_normal_speed = 0.0
	last_landing_intensity = 0.0
	last_landing_contact_mask = 0
	last_landing_contact_count = 0
	last_landing_entry_type = JetSkiTypes.LandingEntryType.UNKNOWN
	water_entry_count = 0
	water_exit_count = 0
	hard_landing_count = 0
	deep_submersion_count = 0
