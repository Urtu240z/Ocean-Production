extends RefCounted
## Application-host guard for transient tiny embedded viewports. Godot's
## screen-mipmap/SSR paths cannot safely render an internal 1x1 image.
## Keep 2D/UI alive and resume 3D automatically when the view has usable pixels.
const MIN_INTERNAL_AXIS := 16
var _viewport: Viewport
var _tree: SceneTree
var _original_disabled := false
var _paused := false
var pauses := 0
var resumes := 0

func _init(viewport: Viewport) -> void:
	_viewport = viewport
	_original_disabled = viewport.disable_3d
	_tree = viewport.get_tree()
	viewport.size_changed.connect(_sync)
	# Scaling changes need not change the logical viewport rectangle.
	_tree.process_frame.connect(_sync)
	_sync()

func _sync() -> void:
	if not is_instance_valid(_viewport): return
	var pixels := _viewport.get_visible_rect().size * _viewport.scaling_3d_scale
	var too_small := minf(pixels.x, pixels.y) < MIN_INTERNAL_AXIS
	if too_small and not _original_disabled and not _paused:
		_paused = true
		pauses += 1
		_viewport.disable_3d = true
	elif not too_small and _paused:
		_paused = false
		resumes += 1
		_viewport.disable_3d = _original_disabled

func release() -> void:
	if is_instance_valid(_tree) and _tree.process_frame.is_connected(_sync): _tree.process_frame.disconnect(_sync)
	if is_instance_valid(_viewport):
		if _viewport.size_changed.is_connected(_sync): _viewport.size_changed.disconnect(_sync)
		if _paused: _viewport.disable_3d = _original_disabled
	_paused = false
	_viewport = null
	_tree = null
