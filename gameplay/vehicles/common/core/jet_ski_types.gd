class_name JetSkiTypes
extends RefCounted

enum NavigationState {
	IN_WATER,
	PARTIALLY_SUBMERGED,
	AIRBORNE,
	LANDING,
	DEEP_SUBMERGED,
}

enum LandingEntryType {
	FRONT,
	REAR,
	LEFT,
	RIGHT,
	FLAT,
	DIAGONAL,
	SINGLE_POINT,
	UNKNOWN,
}

enum RiderStuntWaterMode {
	NORMAL,
	SUBMARINE_DIVE,
}

enum TrickPreloadState {
	IDLE,
	CHARGING,
	REVERSAL_ARMED,
	RELEASE_ACTIVE,
}

enum RiderTrickLaunchType {
	NONE,
	BARREL_LEFT,
	BARREL_RIGHT,
	BACKFLIP,
	FRONTFLIP,
	COMBINED,
}
