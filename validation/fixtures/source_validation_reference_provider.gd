extends "res://addons/ocean/physics/water/cpu_fft_water_provider.gd"
## Frozen source validation before PERF-SCALING-2. Retains PERF-CONTACT-1.
func _perf2_is_water_source_current() -> bool:
	var source := _read_ocean_source_state()
	var status := str(source.get("status", "ERROR"))
	if status != "OK":
		_invalidate_water_sync(status, "Ocean source unavailable or rebuilding")
		return false
	var key := "%d:%d:%d" % [int(source.get("fft_instance_id", -1)),
		int(source.get("revision", -1)), int(source.get("spectrum_version", -1))]
	if key == _failed_spectrum_key:
		_invalidate_water_sync("ERROR", "CPU Lite could not import spectrum " + key)
		return false
	if int(source.get("fft_instance_id", -1)) != _synced_fft_instance_id \
			or int(source.get("revision", -1)) != _synced_ocean_revision \
			or int(source.get("spectrum_version", -1)) != _last_fft_spectrum_generation:
		_invalidate_water_sync("UPDATING", "Waiting for CPU Lite spectrum synchronization")
		return false
	if not _ocean_space_is_valid(source):
		_invalidate_water_sync("ERROR", "Invalid Ocean Space contract")
		return false
	if not _ocean_space_matches(source):
		if water_sync_status != "UPDATING":
			_clear_sync_contact_caches()
		water_sync_status = "UPDATING"
		water_sync_reason = "Waiting for CPU Lite Ocean Space synchronization"
		return false
	return field_ready and is_instance_valid(fft) and is_instance_valid(native)
