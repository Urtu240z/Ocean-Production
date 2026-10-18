@tool
extends RefCounted
## One immutable-shaped parameter snapshot shared by CPU, surface and waterline.
var center_radius := Vector4.ZERO
var shape := Vector4(30,90,35,65)
var motion := Vector4(0,0,0.25,0)

func clear() -> void:
	center_radius.w=0.0
	motion.x=0.0
	motion.y=0.0

func sample(point: Vector2) -> Vector4:
	if center_radius.w<=0.0: return Vector4.ZERO
	var radial:=point-Vector2(center_radius.x,center_radius.y)
	var r:=radial.length()
	var q:=r-center_radius.z
	var width:=maxf(shape.x if q<0 else shape.y,0.1)
	var g:=exp(-q*q/(width*width))
	var tq:=q+shape.w
	var tw:=maxf(shape.z,0.1)
	var trough:=exp(-tq*tq/(tw*tw))
	var f:=g-motion.z*trough
	var derivative:=center_radius.w*(-2*q*g/(width*width)+motion.z*2*tq*trough/(tw*tw))
	var direction:=radial/maxf(r,0.001)
	return Vector4(center_radius.w*f,derivative*direction.x,derivative*direction.y,motion.y*f-motion.x*derivative)

func apply(samples: Array,points: PackedVector3Array) -> void:
	if center_radius.w<=0.0: return
	for i in mini(samples.size(),points.size()):
		var sample=samples[i]
		if not sample.valid: continue
		var w:=self.sample(Vector2(points[i].x,points[i].z))
		sample.surface_position.y+=w.x
		sample.signed_depth=sample.surface_position.y-points[i].y
		sample.normal=(sample.normal-Vector3(w.y,0,w.z)*sample.normal.y).normalized()
		sample.velocity.y+=w.w

func shader_parameters() -> Dictionary:
	return {&"tsunami_center_radius":center_radius,&"tsunami_shape":shape,&"tsunami_motion":motion}

func packed() -> PackedFloat32Array:
	return PackedFloat32Array([center_radius.x,center_radius.y,center_radius.z,center_radius.w,
		shape.x,shape.y,shape.z,shape.w,motion.x,motion.y,motion.z,motion.w])

func height_bound() -> float:
	return absf(center_radius.w)*(1.0+absf(motion.z))
