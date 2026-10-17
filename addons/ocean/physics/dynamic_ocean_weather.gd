extends RefCounted
## Opt-in runtime weather adapter. Does not alter gameplay or authoring setters.
## One worker prepares the same Production H0, latest request wins. The FFT
## publisher interpolates immutable endpoints at its explicit simulation time.
const SpectrumState = preload("res://addons/ocean/fft/ocean_spectrum_state.gd")

var _worker := Thread.new()
var _mutex := Mutex.new()
var _wake := Semaphore.new()
var _stop := false
var _initialized := false
var _pending: Dictionary = {}
var _ready: Dictionary = {}
var _serial := 0
var _native: Object
var _fft: Node
var _weather_active := false
var _active_target: Object
var _latest_spectra: Array = []
var _last_uploaded_version := -1
var _last_uploaded_alpha := -1

func _init(native: Object, fft: Node) -> void:
	_native = native; _fft = fft
	# Generic spectral-array setters do not carry Production wind/choppiness
	# metadata. Reject that setup before it could upload an incorrect first
	# weather frame. Runtime mirrors must import authoritative Production bytes.
	var cpu: Array = _native.call("get_dynamic_snapshot_spectrum")
	var production: Array = _fft.call("get_phys2_band_spectrum_snapshots")
	if cpu.size() != 3 or production.size() != 3:
		push_error("Runtime weather requires set_production_spectrum and a started FFT mirror")
		return
	for band in 3:
		if cpu[band].h0_rgba32f != production[band].h0_rgba32f \
				or cpu[band].resolution != production[band].resolution \
				or cpu[band].domain_size_m != production[band].domain_size_m \
				or cpu[band].gravity_mps2 != production[band].gravity_mps2 \
				or cpu[band].choppiness != production[band].choppiness \
				or cpu[band].wind_speed_mps != production[band].wind_speed_mps \
				or not (cpu[band].wind_direction as Vector2).is_equal_approx((production[band].wind_direction as Vector2).normalized()):
			push_error("Runtime weather initial CPU/Production spectrum mismatch; import with set_production_spectrum")
			return
	_initialized = true
	_worker.start(_work)

func request(configs: Array, parameters: Dictionary, duration: float) -> int:
	if not _initialized: return -1
	# Called on the main thread. The worker only touches private Resources and
	# private native references, never Nodes or the RenderingDevice.
	var source: Array = _fft.call("get_phys2_band_spectrum_snapshots")
	var job := parameters.duplicate(true)
	job["configs"] = configs.map(func(c): return c.call("copy_runtime_config"))
	job["source"] = source
	job["duration"] = maxf(duration, 0.0)
	job["source_native"] = ClassDB.instantiate("OceanQueryNative")
	job["target_native"] = ClassDB.instantiate("OceanQueryNative")
	_mutex.lock()
	_serial += 1
	job["serial"] = _serial
	_pending = job
	_mutex.unlock()
	_wake.post()
	return _serial

func poll(wave_time: float) -> Dictionary:
	if not _initialized: return {"ok": false, "error": "runtime weather was not initialized"}
	var info: PackedInt64Array = _native.call("get_dynamic_snapshot_info")
	var needs_upload := info.size() >= 6 and (int(info[3]) != _last_uploaded_version or int(info[5]) != _last_uploaded_alpha)
	if _weather_active and needs_upload:
		_latest_spectra = _native.call("get_dynamic_snapshot_spectrum", false)
	var active_spectra := _latest_spectra
	_mutex.lock()
	var result := _ready
	var newest := _serial
	# Intentional weather transitions finish before the newest queued target.
	# Never restart from a stale source captured while preparing that target.
	var transitioning := _weather_active and (active_spectra.size() != 3 or float(active_spectra[0].get("weather_alpha", 0.0)) < 1.0)
	if not transitioning: _ready = {}
	_mutex.unlock()
	if transitioning: result = {}
	if not result.is_empty() and int(result["serial"]) == newest and bool(result.get("ok", false)):
		var source: Object = _active_target if _weather_active else result["source_native"]
		if bool(_native.call("transition_dynamic_spectrum", source, result["target_native"], wave_time, result["duration"])):
			_weather_active = true
			_active_target = result["target_native"]
			_fft.call("reserve_runtime_wave_bounds", result["target_bounds"])
			result["started_at_wave_time"] = wave_time
		else:
			result["ok"] = false
	if _weather_active:
		if needs_upload:
			var spectra: Array = active_spectra if not active_spectra.is_empty() else _native.call("get_dynamic_snapshot_spectrum", false)
			if spectra.size() == 3 and float(spectra[0].get("weather_alpha", 0.0)) >= 0.0:
				if bool(_fft.call("queue_dynamic_spectrum", _native, spectra)):
					_last_uploaded_version = int(info[3])
					_last_uploaded_alpha = int(info[5])
					_latest_spectra = spectra
	return result

func shutdown() -> void:
	_mutex.lock(); _stop = true; _mutex.unlock()
	_wake.post()
	if _worker.is_started(): _worker.wait_to_finish()

func _work() -> void:
	while true:
		_wake.wait()
		_mutex.lock()
		var stopping := _stop
		var job := _pending
		_pending = {}
		_mutex.unlock()
		if stopping: return
		if job.is_empty(): continue
		var started := Time.get_ticks_usec()
		var source: Object = job["source_native"]
		var target: Object = job["target_native"]
		var prepared := SpectrumState.build(job["configs"], int(job["seed"]), float(job["overall_hs"]),
			float(job["profile_hs"]), float(job["wave_height_scale"]), job["band_scales"], float(job["mid_fill"]), 7, target)
		var ok := not prepared.is_empty() and bool(source.call("prepare_production_spectrum", job["source"])) \
			and bool(target.call("prepare_production_spectrum", prepared.get("bands", [])))
		job["prepare_ms"] = (Time.get_ticks_usec() - started) / 1000.0
		job["ok"] = ok
		job["target_spectrum"] = prepared.get("bands", [])
		job["target_bounds"] = prepared.get("bounds", Vector3.ZERO)
		_mutex.lock()
		if int(job["serial"]) == _serial: _ready = job
		_mutex.unlock()
