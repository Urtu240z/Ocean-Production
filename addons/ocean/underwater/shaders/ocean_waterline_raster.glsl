#[vertex]
#version 450
#define WAVE_AREA_BINDING 14
#define LOCAL_FFT_BINDING 15
#include "res://addons/ocean/areas/wave_area_math.gdshaderinc"
#include "res://addons/ocean/events/tsunami_math.gdshaderinc"
#include "res://addons/ocean/areas/wave_area_buffer.gdshaderinc"
#include "res://addons/ocean/shaders/coastal_coverage.gdshaderinc"
#include "res://addons/ocean/underwater/shaders/ocean_waterline_raster_uniforms.gdshaderinc"
#include "res://addons/ocean/surface/foam2d/hull_wave_sampling.gdshaderinc"
#include "res://addons/ocean/underwater/shaders/ocean_hull_wave_waterline.gdshaderinc"
#include "res://addons/ocean/underwater/shaders/ocean_waterline_raster_body.gdshaderinc"

#[fragment]
#version 450
#include "res://addons/ocean/underwater/shaders/ocean_waterline_fragment.gdshaderinc"
