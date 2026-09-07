class_name OceanCascadeState
extends RefCounted
## Single authority for requested/effective FFT cascade availability.

const LONG := 1
const MID := 2
const SHORT := 4
const FULL := LONG | MID | SHORT

var requested_mask := FULL
var effective_mask := FULL


func configure(mask: int) -> void:
	requested_mask = clampi(mask, 0, FULL) & FULL
	effective_mask = requested_mask


func is_active(band: int) -> bool:
	return bool(effective_mask & band)


func requested_is_active(band: int) -> bool:
	return bool(requested_mask & band)


func mode_name() -> String:
	match requested_mask:
		0: return "ALL_OFF"
		MID: return "MID_ONLY"
		SHORT: return "SHORT_ONLY"
		FULL: return "FULL"
		LONG | MID: return "NO_SHORT"
		LONG: return "LONG_ONLY"
		LONG | SHORT: return "NO_MID"
		MID | SHORT: return "MID_SHORT"
		_: return "MASK_%d" % requested_mask
