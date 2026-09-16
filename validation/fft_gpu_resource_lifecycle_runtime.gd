extends SceneTree
## Automated H0 runtime stress test. It intentionally performs rebuilds and
## Crest toggles without waiting on the render thread.

const CYCLES := 12
const STABILIZATION_FRAMES := 45
const MAX_STARTUP_FRAMES := 180

var _scene: Node
var _ocean: Ocean
var _crest_profile: Resource
var _cycle := 0
var _phase := 0
var _stable_frames := 0
var _frame := 0
var _failed := false
var _failure := ""


func _initialize() -> void:
	_scene = load("res://validation/p0_open_ocean.tscn").instantiate()
	root.add_child(_scene)
	_ocean = _scene.get_node("Ocean")
	_crest_profile = load("res://validation/profiles/p0_crest_foam_profile.tres")


func _process(_delta: float) -> bool:
	_frame += 1
	if _failed:
		return false
	if _ocean == null:
		_fail("Ocean no encontrado")
		return false

	var open_ocean = _ocean.get("_open_ocean")
	if open_ocean == null:
		if _frame > MAX_STARTUP_FRAMES:
			_fail("OpenOceanFFT no apareció durante el arranque")
		return false

	if _cycle < CYCLES:
		_run_stress_step(open_ocean)
		_check_transient_state(open_ocean)
		return false

	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not _validate_state(state, true):
		return false
	_stable_frames += 1
	if _stable_frames >= STABILIZATION_FRAMES:
		print("FFT_GPU_RESOURCE_LIFECYCLE_PASS cycles=%d generation=%d" % [CYCLES, state.generation])
		quit(0)
	return false


func _run_stress_step(open_ocean: Node) -> void:
	match _phase:
		0:
			open_ocean.set_crest_foam(false)
			_phase = 1
		1:
			open_ocean.set_crest_foam(true)
			_ocean.crest_foam_profile = _crest_profile
			_phase = 2
		2:
			# Rebuild immediately after the enable/profile commands. The old
			# generation still has queued render-thread callbacks at this point.
			_ocean.shutdown()
			if not _ocean.initialize():
				_fail("Ocean.initialize() falló en ciclo %d" % _cycle)
			_phase = 3
		3:
			var replacement = _ocean.get("_open_ocean")
			if replacement == null:
				_fail("OpenOceanFFT perdido después del rebuild %d" % _cycle)
				return
			replacement.set_crest_foam(_cycle % 2 == 0)
			replacement.set_crest_foam(true)
			_cycle += 1
			_phase = 0


func _check_transient_state(open_ocean: Node) -> void:
	var state: Dictionary = open_ocean.get_fft_resource_lifecycle_state()
	if not _validate_state(state, false):
		return
	if not state.generation_active:
		_fail("Generación inactiva expuesta mientras OpenOceanFFT está publicado")


func _validate_state(state: Dictionary, require_ready: bool) -> bool:
	if not state.generation_active:
		if require_ready: _fail("Generación no activa tras estabilización")
		return false
	if state.generation < 0:
		_fail("Generación inválida: %s" % state.generation)
		return false
	if not state.neutral_ready:
		if require_ready: _fail("Neutrales FFT/Crest no listos tras estabilización: gen=%s error=%s state=%s" % [state.generation, state.neutral_error, state])
		return false
	if state.published_generation != state.generation:
		if require_ready: _fail("Generación antigua o no vigente publicada: %s -> %s" % [state.published_generation, state.generation])
		return false
	if not state.surface_initialized:
		if require_ready: _fail("Surface no inicializada tras estabilización")
		return false
	if require_ready and (not state.surface_foam_ready or not String(state.surface_foam_error).is_empty()):
		_fail("Surface Foam no listo o con error de lifecycle: %s" % state.surface_foam_error)
		return false
	for band in state.bands:
		if not band.displacement_valid or not band.normal_valid or not band.crest_valid:
			if require_ready: _fail("RID publicado inválido en banda: %s" % band)
			return false
		if band.published_displacement != band.displacement_rid or band.published_normal != band.normal_rid or band.published_crest != band.crest_rid:
			_fail("Estado inconsistente entre solver y Texture2DRD")
			return false
		var expected_displacement = band.solver_displacement_rid if band.solver_ready else state.neutral_displacement_rid
		var expected_normal = band.solver_normal_rid if band.solver_ready else state.neutral_normal_rid
		var expected_crest = band.solver_crest_rid if band.crest_ready and state.crest_requested else state.neutral_crest_rid
		if band.displacement_rid != expected_displacement or band.normal_rid != expected_normal or band.crest_rid != expected_crest:
			_fail("RID de generación antigua publicado sobre Texture2DRD")
			return false
		if band.solver_ready and band.solver_generation != state.generation:
			_fail("Solver de generación antigua expuesto: %s != %s" % [band.solver_generation, state.generation])
			return false
		if band.solver_ready and (not band.displacement_valid or not band.normal_valid):
			_fail("Solver listo con textura FFT inválida")
			return false
		if require_ready and not String(band.solver_error).is_empty():
			_fail("Error de lifecycle FFT: %s" % band.solver_error)
			return false
	return true


func _fail(reason: String) -> void:
	if _failed:
		return
	_failed = true
	_failure = reason
	push_error("FFT_GPU_RESOURCE_LIFECYCLE_FAIL: " + reason)
	quit(1)
