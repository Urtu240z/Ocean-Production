@tool
class_name OceanSpindriftProfile
extends Resource
## Authoring profile for the optional Ocean V4 wind-blown crest spray.
## The controller owns the GPU particles; this resource only owns tunable values.

@export_group("Source")
@export_range(0.0, 1.0, 0.01) var breaking_trigger_threshold := 0.72:
	set(value):
		breaking_trigger_threshold = clampf(value, 0.0, 1.0)
		if breaking_rearm_threshold >= breaking_trigger_threshold:
			breaking_rearm_threshold = maxf(0.0, breaking_trigger_threshold - 0.01)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var breaking_rearm_threshold := 0.28:
	set(value):
		breaking_rearm_threshold = clampf(value, 0.0, 1.0)
		if breaking_rearm_threshold >= breaking_trigger_threshold:
			breaking_rearm_threshold = maxf(0.0, breaking_trigger_threshold - 0.01)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var emission_density := 0.72:
	set(value):
		emission_density = clampf(value, 0.0, 2.0)
		emit_changed()

@export_group("Storm / Wind")
@export_range(0.0, 1.0, 0.01) var storm_strength := 0.85:
	set(value):
		storm_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var wind_velocity_multiplier := 1.0:
	set(value):
		wind_velocity_multiplier = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var crest_kick := 0.42:
	set(value):
		crest_kick = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var horizontal_spread := 0.30:
	set(value):
		horizontal_spread = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var vertical_spread := 0.10:
	set(value):
		vertical_spread = maxf(value, 0.0)
		emit_changed()
@export_range(0.0, 2.0, 0.01) var turbulence_strength := 0.45:
	set(value):
		turbulence_strength = maxf(value, 0.0)
		emit_changed()
@export_range(0.01, 4.0, 0.01) var turbulence_scale := 0.16:
	set(value):
		turbulence_scale = maxf(value, 0.01)
		emit_changed()
@export_range(0.0, 4.0, 0.01) var turbulence_speed := 1.35:
	set(value):
		turbulence_speed = maxf(value, 0.0)
		emit_changed()

@export_group("Region / LOD")
@export_range(8.0, 120.0, 1.0, "suffix:m") var spindrift_radius := 48.0:
	set(value):
		spindrift_radius = maxf(value, 8.0)
		emit_changed()
@export_range(1.0, 100.0, 1.0, "suffix:m") var chunks_lod_end_m := 22.0:
	set(value):
		chunks_lod_end_m = maxf(value, 1.0)
		emit_changed()
@export_range(1.0, 150.0, 1.0, "suffix:m") var streaks_lod_end_m := 55.0:
	set(value):
		streaks_lod_end_m = maxf(value, 1.0)
		emit_changed()
@export_range(1.0, 150.0, 1.0, "suffix:m") var mist_lod_end_m := 46.0:
	set(value):
		mist_lod_end_m = maxf(value, 1.0)
		emit_changed()

@export_group("Particle Budget")
@export_range(32, 1024, 32) var chunks_amount := 256:
	set(value):
		chunks_amount = maxi(value, 32)
		emit_changed()
@export_range(64, 2048, 64) var streaks_amount := 768:
	set(value):
		streaks_amount = maxi(value, 64)
		emit_changed()
@export_range(64, 2048, 64) var mist_amount := 512:
	set(value):
		mist_amount = maxi(value, 64)
		emit_changed()
@export_range(0.1, 2.0, 0.01, "suffix:s") var chunks_lifetime := 0.65:
	set(value):
		chunks_lifetime = maxf(value, 0.1)
		emit_changed()
@export_range(0.1, 3.0, 0.01, "suffix:s") var streaks_lifetime := 0.95:
	set(value):
		streaks_lifetime = maxf(value, 0.1)
		emit_changed()
@export_range(0.1, 3.0, 0.01, "suffix:s") var mist_lifetime := 1.15:
	set(value):
		mist_lifetime = maxf(value, 0.1)
		emit_changed()

@export_group("Art / Life Fade")
## Normalized lifetime fractions. A newborn particle fades in from zero over
## fade_in_fraction and fades out to zero at normalized age 1.0, starting at
## fade_out_start_fraction. Values are clamped so the two intervals can never
## reverse or collapse into a zero-width smoothstep.
@export_range(0.0, 0.5, 0.01) var chunks_fade_in_fraction := 0.07:
	set(value):
		chunks_fade_in_fraction = clampf(value, 0.0, 0.5)
		chunks_fade_out_start_fraction = maxf(chunks_fade_out_start_fraction, chunks_fade_in_fraction)
		emit_changed()
@export_range(0.0, 0.5, 0.01) var streaks_fade_in_fraction := 0.05:
	set(value):
		streaks_fade_in_fraction = clampf(value, 0.0, 0.5)
		streaks_fade_out_start_fraction = maxf(streaks_fade_out_start_fraction, streaks_fade_in_fraction)
		emit_changed()
@export_range(0.0, 0.5, 0.01) var mist_fade_in_fraction := 0.10:
	set(value):
		mist_fade_in_fraction = clampf(value, 0.0, 0.5)
		mist_fade_out_start_fraction = maxf(mist_fade_out_start_fraction, mist_fade_in_fraction)
		emit_changed()
@export_range(0.3, 1.0, 0.01) var chunks_fade_out_start_fraction := 0.70:
	set(value):
		chunks_fade_out_start_fraction = clampf(value, chunks_fade_in_fraction, 1.0)
		emit_changed()
@export_range(0.3, 1.0, 0.01) var streaks_fade_out_start_fraction := 0.72:
	set(value):
		streaks_fade_out_start_fraction = clampf(value, streaks_fade_in_fraction, 1.0)
		emit_changed()
@export_range(0.3, 1.0, 0.01) var mist_fade_out_start_fraction := 0.58:
	set(value):
		mist_fade_out_start_fraction = clampf(value, mist_fade_in_fraction, 1.0)
		emit_changed()

@export_group("Art / Water Contact")
## Height above sea level where the water fade reaches full contribution. At sea
## level the spray is invisible; it never needs collision, FFT reads or raycasts.
@export_range(0.01, 2.0, 0.01, "suffix:m") var chunks_water_fade_height_m := 0.35:
	set(value):
		chunks_water_fade_height_m = clampf(value, 0.01, 2.0)
		emit_changed()
@export_range(0.01, 2.0, 0.01, "suffix:m") var streaks_water_fade_height_m := 0.45:
	set(value):
		streaks_water_fade_height_m = clampf(value, 0.01, 2.0)
		emit_changed()
@export_range(0.01, 2.0, 0.01, "suffix:m") var mist_water_fade_height_m := 0.65:
	set(value):
		mist_water_fade_height_m = clampf(value, 0.01, 2.0)
		emit_changed()
## A detached child that falls this far below sea level releases its GPU slot
## immediately. This is a cheap sea-level cleanup, not a water collision.
@export_range(0.0, 1.0, 0.01, "suffix:m") var water_kill_depth_m := 0.10:
	set(value):
		water_kill_depth_m = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Art / Motion")
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var chunks_gravity_mps2 := 9.0:
	set(value):
		chunks_gravity_mps2 = clampf(value, 0.0, 20.0)
		emit_changed()
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var streaks_gravity_mps2 := 6.0:
	set(value):
		streaks_gravity_mps2 = clampf(value, 0.0, 20.0)
		emit_changed()
@export_range(0.0, 20.0, 0.1, "suffix:m/s²") var mist_gravity_mps2 := 2.5:
	set(value):
		mist_gravity_mps2 = clampf(value, 0.0, 20.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var chunks_wind_drag := 0.30:
	set(value):
		chunks_wind_drag = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var streaks_wind_drag := 0.42:
	set(value):
		streaks_wind_drag = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var mist_wind_drag := 0.75:
	set(value):
		mist_wind_drag = clampf(value, 0.0, 3.0)
		emit_changed()
## Layer weight on the shared global turbulence_strength. The turbulence system
## itself stays global: only the per-layer amount changes.
@export_range(0.0, 3.0, 0.01) var chunks_turbulence_multiplier := 0.65:
	set(value):
		chunks_turbulence_multiplier = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var streaks_turbulence_multiplier := 1.0:
	set(value):
		streaks_turbulence_multiplier = clampf(value, 0.0, 3.0)
		emit_changed()
@export_range(0.0, 3.0, 0.01) var mist_turbulence_multiplier := 1.45:
	set(value):
		mist_turbulence_multiplier = clampf(value, 0.0, 3.0)
		emit_changed()

@export_group("Art / Visual Scale")
## Scales the generated billboard/patch dimensions only. The particle world
## transform, the emission footprint and the LOD distances are untouched.
@export_range(0.1, 3.0, 0.01) var chunks_visual_scale := 1.0:
	set(value):
		chunks_visual_scale = clampf(value, 0.1, 3.0)
		emit_changed()
@export_range(0.1, 3.0, 0.01) var streaks_visual_scale := 1.0:
	set(value):
		streaks_visual_scale = clampf(value, 0.1, 3.0)
		emit_changed()
@export_range(0.1, 3.0, 0.01) var mist_visual_scale := 1.0:
	set(value):
		mist_visual_scale = clampf(value, 0.1, 3.0)
		emit_changed()

@export_group("Art / Shape")
## Silhouette pass. Width/length reshape the generated billboard only: the
## particle world transform, emission footprint and LOD distances are untouched.
@export_range(0.20, 3.0, 0.01) var chunks_width_scale := 1.10:
	set(value):
		chunks_width_scale = clampf(value, 0.20, 3.0)
		emit_changed()
@export_range(0.20, 3.0, 0.01) var streaks_width_scale := 0.65:
	set(value):
		streaks_width_scale = clampf(value, 0.20, 3.0)
		emit_changed()
@export_range(0.20, 3.0, 0.01) var mist_width_scale := 1.25:
	set(value):
		mist_width_scale = clampf(value, 0.20, 3.0)
		emit_changed()
@export_range(0.20, 4.0, 0.01) var chunks_length_scale := 0.90:
	set(value):
		chunks_length_scale = clampf(value, 0.20, 4.0)
		emit_changed()
@export_range(0.20, 4.0, 0.01) var streaks_length_scale := 1.55:
	set(value):
		streaks_length_scale = clampf(value, 0.20, 4.0)
		emit_changed()
@export_range(0.20, 4.0, 0.01) var mist_length_scale := 1.10:
	set(value):
		mist_length_scale = clampf(value, 0.20, 4.0)
		emit_changed()
## Procedural alpha-edge softness. Low values give a hard torn edge, high values
## a diffuse one.
@export_range(0.01, 0.50, 0.01) var chunks_edge_softness := 0.12:
	set(value):
		chunks_edge_softness = clampf(value, 0.01, 0.50)
		emit_changed()
@export_range(0.01, 0.50, 0.01) var streaks_edge_softness := 0.08:
	set(value):
		streaks_edge_softness = clampf(value, 0.01, 0.50)
		emit_changed()
@export_range(0.01, 0.50, 0.01) var mist_edge_softness := 0.22:
	set(value):
		mist_edge_softness = clampf(value, 0.01, 0.50)
		emit_changed()
## Silhouette fragmentation. 0 keeps a continuous shape, 1 bites hard into the
## edges. The centre is protected by core_strength, so it never becomes noise.
@export_range(0.0, 1.0, 0.01) var chunks_breakup_strength := 0.38:
	set(value):
		chunks_breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_breakup_strength := 0.48:
	set(value):
		streaks_breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_breakup_strength := 0.22:
	set(value):
		mist_breakup_strength = clampf(value, 0.0, 1.0)
		emit_changed()
## Internal density variation. Never erases the whole particle.
@export_range(0.0, 1.0, 0.01) var chunks_mottle_strength := 0.20:
	set(value):
		chunks_mottle_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_mottle_strength := 0.16:
	set(value):
		streaks_mottle_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_mottle_strength := 0.30:
	set(value):
		mist_mottle_strength = clampf(value, 0.0, 1.0)
		emit_changed()
## End-of-life visual shrink, reaching this fraction at normalized age 1.0.
@export_range(0.1, 1.0, 0.01) var chunks_terminal_scale := 0.65:
	set(value):
		chunks_terminal_scale = clampf(value, 0.1, 1.0)
		emit_changed()
@export_range(0.1, 1.0, 0.01) var streaks_terminal_scale := 0.52:
	set(value):
		streaks_terminal_scale = clampf(value, 0.1, 1.0)
		emit_changed()
@export_range(0.1, 1.0, 0.01) var mist_terminal_scale := 0.78:
	set(value):
		mist_terminal_scale = clampf(value, 0.1, 1.0)
		emit_changed()
## How much a coherent opaque centre survives the fragmentation. High keeps a
## defined core, low gives a diffuse cloud.
@export_range(0.0, 1.0, 0.01) var chunks_core_strength := 0.75:
	set(value):
		chunks_core_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_core_strength := 0.58:
	set(value):
		streaks_core_strength = clampf(value, 0.0, 1.0)
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_core_strength := 0.35:
	set(value):
		mist_core_strength = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Appearance")
@export_color_no_alpha var chunks_color := Color(0.82, 0.86, 0.86):
	set(value):
		chunks_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var chunks_alpha := 0.82:
	set(value):
		chunks_alpha = clampf(value, 0.0, 1.0)
		emit_changed()
@export_color_no_alpha var streaks_color := Color(0.72, 0.78, 0.78):
	set(value):
		streaks_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var streaks_alpha := 0.58:
	set(value):
		streaks_alpha = clampf(value, 0.0, 1.0)
		emit_changed()
@export_color_no_alpha var mist_color := Color(0.66, 0.73, 0.74):
	set(value):
		mist_color = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var mist_alpha := 0.22:
	set(value):
		mist_alpha = clampf(value, 0.0, 1.0)
		emit_changed()

@export_group("Volumetric Spindrift")
## H4.33 PERSISTENT volumetric sea mist: a GPU Eulerian aerosol field that
## survives after its crest disappears. This is an optional PARALLEL rendering
## path. It consumes the same Crest G breaking activity as the particle spindrift
## (as an INJECTION source only) but never reads, restarts or alters sensors,
## detached pools, emission, lifetime, LOD or the spray artwork.
##
## DIVISION OF RESPONSIBILITY (H4.35)
##   * The compute simulation owns WHERE aerosol exists in 3D. It injects against
##     the displaced water surface (sea_level + Ocean-Space-scaled LONG
##     displacement), advects it, and stores it in the persistent RG16F volume.
##   * The FogVolume render shader owns only opacity: it multiplies the stored
##     density by the local volume boundary feather and the droplet
##     microstructure. It applies NO height envelope and no water-surface model,
##     so a parcel sitting on a +6 m crest renders at full strength.
##
## Everything here is OFF by default so loading an existing scene keeps its
## exact visuals and its exact runtime cost.
@export var volumetric_enabled := false:
	set(value):
		volumetric_enabled = value
		emit_changed()
## Master opacity of the persistent field. The fog shader multiplies it by the
## simulated density mass, so this is the same per-metre density scale H4.32
## used: ~0.05 reads as thin mist, ~0.3 as dense spray.
@export_range(0.0, 2.0, 0.005) var volumetric_density := 0.08:
	set(value):
		volumetric_density = clampf(value, 0.0, 2.0)
		emit_changed()
## Crest activity below this value injects no mass. Volumetric-only: it can never
## reach the particle trigger threshold or any breaker logic.
@export_range(0.0, 1.0, 0.01) var volumetric_source_threshold := 0.55:
	set(value):
		volumetric_source_threshold = clampf(value, 0.0, 1.0)
		emit_changed()
## Injection multiplier applied after the threshold, again volumetric-only.
@export_range(0.0, 4.0, 0.01) var volumetric_source_gain := 1.0:
	set(value):
		volumetric_source_gain = clampf(value, 0.0, 4.0)
		emit_changed()
## Half-width of the local persistent volume. Deliberately independent of
## spindrift_radius: the simulation box is small and cheap even when the particle
## footprint is large.
@export_range(8.0, 160.0, 1.0, "suffix:m") var volumetric_sim_radius_m := 48.0:
	set(value):
		volumetric_sim_radius_m = clampf(value, 8.0, 160.0)
		emit_changed()
## Fixed simulation cadence. The persistent field does not need to advance at
## render FPS.
@export_range(10.0, 60.0, 1.0, "suffix:Hz") var volumetric_simulation_hz := 30.0:
	set(value):
		volumetric_simulation_hz = clampf(value, 10.0, 60.0)
		emit_changed()
## Exponential density decay in 1/s. This is the slow one: it decides how long
## aerosol survives after its crest is gone. Below ~0.12 the injector keeps
## filling at a floor rate, so lowering it lengthens persistence and raises the
## peak mass instead of producing a dead volume.
@export_range(0.0, 4.0, 0.005, "suffix:1/s") var volumetric_density_decay := 0.12:
	set(value):
		volumetric_density_decay = clampf(value, 0.0, 4.0)
		emit_changed()
## Exponential decay of the wave/source-coupled memory in 1/s. Keep it clearly
## faster than the density decay: that gap is what turns wave-driven spray into
## free wind-driven mist, and it is the age proxy the velocity field reads.
@export_range(0.0, 8.0, 0.01, "suffix:1/s") var volumetric_wave_memory_decay := 1.60:
	set(value):
		volumetric_wave_memory_decay = clampf(value, 0.0, 8.0)
		emit_changed()
## Speed at which wave-coupled aerosol is pushed along the local LONG wave
## propagation direction. Reuses the H4.31 propagation semantics; atmospheric
## wind is never substituted for it.
@export_range(0.0, 8.0, 0.01, "suffix:m/s") var volumetric_wave_push := 0.80:
	set(value):
		volumetric_wave_push = clampf(value, 0.0, 8.0)
		emit_changed()
## Fraction of the real wind speed imparted to aerosol as advection. Newborn,
## wave-coupled spray only receives a reduced share of it.
@export_range(0.0, 0.5, 0.005) var volumetric_wind_advection := 0.08:
	set(value):
		volumetric_wind_advection = clampf(value, 0.0, 0.5)
		emit_changed()
## Subtle vertical aerosol lift in m/s. This is droplet separation from the
## water surface, NOT smoke buoyancy, so it stays small by design.
@export_range(0.0, 2.0, 0.005, "suffix:m/s") var volumetric_lift_strength := 0.12:
	set(value):
		volumetric_lift_strength = clampf(value, 0.0, 2.0)
		emit_changed()
## Strength of the 3D divergence-free curl field. This one property has two
## honest, documented consumers:
##   * COMPUTE: used directly as advection velocity in m/s. This is what rolls,
##     folds and tears the mist.
##   * RENDER: the microstructure reuses the same authored number but NORMALISES
##     it against a 2 m/s reference to drive a dimensionless 0..1 response, then
##     scales a warp whose length is capped at 2 m. So the render-side spatial
##     warp can never exceed 2 m no matter how high this value is set.
## 0 disables curling entirely in both.
@export_range(0.0, 8.0, 0.01, "suffix:m/s") var volumetric_curl_strength := 1.0:
	set(value):
		volumetric_curl_strength = clampf(value, 0.0, 8.0)
		emit_changed()
## Spatial frequency of the curl field, in 1/m.
@export_range(0.002, 0.30, 0.001) var volumetric_curl_scale := 0.03:
	set(value):
		volumetric_curl_scale = clampf(value, 0.002, 0.30)
		emit_changed()
## Rate at which the curl pattern itself evolves, independent of advection.
@export_range(0.0, 2.0, 0.01) var volumetric_curl_speed := 0.12:
	set(value):
		volumetric_curl_speed = clampf(value, 0.0, 2.0)
		emit_changed()
## How strongly neighbouring regions disagree about wind, curl and lift. This is
## what makes one part of the mist get caught by the wind while the parcel beside
## it is still riding the wave. 0 makes the whole volume respond uniformly.
@export_range(0.0, 1.0, 0.01) var volumetric_flow_variation_strength := 0.45:
	set(value):
		volumetric_flow_variation_strength = clampf(value, 0.0, 1.0)
		emit_changed()
## Spatial frequency of the coherent flow variation, in 1/m. Low by design: the
## variation must be a large-scale, slowly evolving preference, never flicker.
@export_range(0.001, 0.20, 0.001) var volumetric_flow_variation_scale := 0.012:
	set(value):
		volumetric_flow_variation_scale = clampf(value, 0.001, 0.20)
		emit_changed()
## How hard the SUB-MICRO droplet mask erodes the persistent micro density. This
## is density-only erosion of the fine droplet field: it never introduces colour
## variation, and the moving mass it breaks up comes from the persistent micro
## simulation, not from this noise. It can never create density on its own.
@export_range(0.0, 1.0, 0.01) var volumetric_granule_strength := 0.60:
	set(value):
		volumetric_granule_strength = clampf(value, 0.0, 1.0)
		emit_changed()
## Spatial frequency of the sub-micro droplet mask, in 1/m. High values approach
## the simulated voxel size; this is render-side breakup, so it may legitimately
## be finer than either simulation grid.
@export_range(0.02, 4.0, 0.005) var volumetric_granule_scale := 0.45:
	set(value):
		volumetric_granule_scale = clampf(value, 0.02, 4.0)
		emit_changed()
## How fast the sub-micro mask is carried by the flow. Slightly different from the
## simulated fields on purpose: that difference is the internal motion of the
## spray detail. The persistent micro field provides the real motion.
@export_range(0.0, 2.0, 0.01) var volumetric_granule_speed := 0.35:
	set(value):
		volumetric_granule_speed = clampf(value, 0.0, 2.0)
		emit_changed()
## Sub-micro mask threshold. Low keeps a continuous droplet veil that is merely
## textured; high bites deep and leaves islands, holes and filaments.
@export_range(0.0, 0.95, 0.01) var volumetric_granule_threshold := 0.42:
	set(value):
		volumetric_granule_threshold = clampf(value, 0.0, 0.95)
		emit_changed()
## HORIZONTAL edge fade only: the fraction of the local volume radius over which
## density fades to zero, so the box's XZ boundary is never a visible cut. The
## vertical boundary uses a small fixed feather instead, because the vertical
## extent is a sampling-box limit rather than an art control.
@export_range(0.02, 0.95, 0.01) var volumetric_edge_fade := 0.30:
	set(value):
		volumetric_edge_fade = clampf(value, 0.02, 0.95)
		emit_changed()

@export_subgroup("Micro Aerosol")
## H4.36: a SECOND persistent field at 128 x 32 x 128 over the same world extent.
## It holds the fine droplet clusters as simulated matter with their own history
## and their own faster dynamics. It is NOT render-side noise, and it is allowed
## to exist where the macro mist body is absent, because spray detaches.
##
## The compute pass injects micro aerosol from the same Crest G authority as
## macro but through a thinner band and a patchy coherent source pattern, then
## advects it independently. It does not read macro state in this version.
## Master opacity of the fine droplet scale. 0 disables the micro contribution
## while leaving macro volumetric spindrift fully active.
@export_range(0.0, 2.0, 0.005) var volumetric_micro_density := 0.35:
	set(value):
		volumetric_micro_density = clampf(value, 0.0, 2.0)
		emit_changed()
## Micro injection multiplier, applied after the shared Crest G threshold.
@export_range(0.0, 4.0, 0.01) var volumetric_micro_source_gain := 1.0:
	set(value):
		volumetric_micro_source_gain = clampf(value, 0.0, 4.0)
		emit_changed()
## Micro density decay in 1/s. This is the FAST one: fine droplets disappear
## significantly sooner than the macro mist body.
@export_range(0.0, 6.0, 0.01, "suffix:1/s") var volumetric_micro_density_decay := 0.65:
	set(value):
		volumetric_micro_density_decay = clampf(value, 0.0, 6.0)
		emit_changed()
## Micro wave-memory decay in 1/s. Must stay above volumetric_micro_density_decay:
## that gap is what turns wave-borne droplets into free wind-driven aerosol and
## then into nothing.
@export_range(0.0, 12.0, 0.01, "suffix:1/s") var volumetric_micro_wave_memory_decay := 2.80:
	set(value):
		volumetric_micro_wave_memory_decay = clampf(value, 0.0, 12.0)
		emit_changed()
## How much more wind-responsive fine droplets are than macro mist.
@export_range(0.0, 4.0, 0.01) var volumetric_micro_wind_multiplier := 1.5:
	set(value):
		volumetric_micro_wind_multiplier = clampf(value, 0.0, 4.0)
		emit_changed()
## How much stronger the micro curl is than the macro curl. The spatial scale is
## additionally multiplied by a fixed 2.0 inside the simulation.
@export_range(0.0, 4.0, 0.01) var volumetric_micro_curl_multiplier := 1.8:
	set(value):
		volumetric_micro_curl_multiplier = clampf(value, 0.0, 4.0)
		emit_changed()
## Spatial frequency of the patchy micro source pattern, in 1/m. Higher values
## break the injected spray into smaller, more separated droplet clusters.
@export_range(0.05, 4.0, 0.005) var volumetric_micro_seed_scale := 0.80:
	set(value):
		volumetric_micro_seed_scale = clampf(value, 0.05, 4.0)
		emit_changed()
## Mist albedo. Water mist, not smoke: keep it near white and let Godot
## volumetric lighting do the shading. The microstructure is density-only, so
## this stays a single flat colour.
@export_color_no_alpha var volumetric_albedo := Color(0.92, 0.95, 0.98):
	set(value):
		volumetric_albedo = value
		emit_changed()
## Fake brightness. Deliberately zero by default so the global Sun and the
## environment exposure stay authoritative.
@export_range(0.0, 0.5, 0.001) var volumetric_emission := 0.0:
	set(value):
		volumetric_emission = clampf(value, 0.0, 0.5)
		emit_changed()
## Comparison switch for the user art gate. When ON it hides only the visible
## streak render layer so the volumetric mist can be judged beside the chunks and
## mist layers. Sensors, emission, pooling, chunks and the streak simulation are
## all untouched.
@export var volumetric_hide_legacy_streaks := false:
	set(value):
		volumetric_hide_legacy_streaks = value
		emit_changed()
