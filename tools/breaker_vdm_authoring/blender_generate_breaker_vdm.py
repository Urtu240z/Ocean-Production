"""Offline authoring tool for the entirely synthetic P7 2C2 breaker VDM.

Run with Blender, for example:
    blender -b --python tools/breaker_vdm_authoring/blender_generate_breaker_vdm.py
"""

import math
import os
import sys

import bpy


WIDTH = 512
HEIGHT = 256
OUTPUT = "addons/ocean/breakers/assets/breaker_plunging_test_v01.exr"

SECTION_A = ((-6.00, 0.00), (-4.50, 0.00), (-2.30, 0.65), (-0.80, 1.80))
SECTION_B = ((-0.80, 1.80), (0.35, 2.85), (1.85, 3.75), (2.85, 3.20))
SECTION_C = ((2.85, 3.20), (3.45, 2.75), (3.00, 1.55), (1.60, 0.95))
SECTION_D = ((1.60, 0.95), (1.20, 0.65), (3.20, 0.15), (6.00, 0.00))


def smoothstep(edge0, edge1, value):
    t = max(0.0, min(1.0, (value - edge0) / max(edge1 - edge0, 1.0e-6)))
    return t * t * (3.0 - 2.0 * t)


def bezier(points, t):
    one_minus_t = 1.0 - t
    return tuple(
        one_minus_t ** 3 * points[0][axis]
        + 3.0 * one_minus_t ** 2 * t * points[1][axis]
        + 3.0 * one_minus_t * t ** 2 * points[2][axis]
        + t ** 3 * points[3][axis]
        for axis in range(2)
    )


def sample_profile(v):
    v = max(0.0, min(1.0, v))
    if v < 0.40:
        return bezier(SECTION_A, v / 0.40)
    if v < 0.65:
        return bezier(SECTION_B, (v - 0.40) / 0.25)
    if v < 0.84:
        return bezier(SECTION_C, (v - 0.65) / 0.19)
    return bezier(SECTION_D, (v - 0.84) / 0.16)


def generate():
    pixels = [0.0] * (WIDTH * HEIGHT * 4)
    min_values = [float("inf")] * 4
    max_values = [float("-inf")] * 4
    for y in range(HEIGHT):
        v = (y + 0.5) / HEIGHT
        source_s = (v - 0.5) * 12.0
        for x in range(WIDTH):
            u = (x + 0.5) / WIDTH
            lateral = u * 2.0 - 1.0
            phase_shift = 0.035 * math.sin(lateral * math.pi * 1.5) + 0.015 * math.sin(lateral * math.pi * 3.0 + 0.4)
            shaped_v = max(0.0, min(1.0, v + phase_shift))
            target_s, target_y = sample_profile(shaped_v)
            crest_scale = 1.0 + 0.10 * math.sin(lateral * math.pi * 1.5 + 0.8)
            crest_influence = smoothstep(1.0, 2.0, target_y)
            target_y = target_y * (1.0 + (crest_scale - 1.0) * crest_influence)
            nose_weight = math.exp(-((shaped_v - 0.72) / 0.14) ** 2)
            curl_weight = smoothstep(0.68, 0.90, shaped_v) * (1.0 - smoothstep(0.90, 1.0, shaped_v))
            target_s += 0.35 * math.sin(lateral * math.pi * 1.25 + 0.2) * nose_weight
            target_s += 0.22 * math.sin(lateral * math.pi * 2.0 + 1.1) * curl_weight
            rear_end = 0.08 + 0.018 * math.sin(lateral * math.pi * 2.0 + 0.3)
            front_start = 0.96 + 0.018 * math.sin(lateral * math.pi * 2.0 + 1.0)
            rear_boundary = smoothstep(0.0, rear_end, v)
            front_boundary = 1.0 - smoothstep(front_start, 1.0, v)
            lateral_authority = 1.0 - smoothstep(0.82, 1.0, abs(lateral))
            authority = lateral_authority * rear_boundary * front_boundary
            tangent = 0.30 * math.sin(lateral * math.pi * 1.25 + 0.5) * lateral_authority
            values = (tangent * authority, target_y * authority, (target_s - source_s) * authority, authority)
            base = (y * WIDTH + x) * 4
            pixels[base:base + 4] = values
            for channel, value in enumerate(values):
                min_values[channel] = min(min_values[channel], value)
                max_values[channel] = max(max_values[channel], value)
    image = bpy.data.images.new("breaker_plunging_test_v01", width=WIDTH, height=HEIGHT, alpha=True, float_buffer=True)
    image.pixels = pixels
    try:
        image.colorspace_settings.name = "Linear"
    except Exception:
        pass
    image.filepath_raw = os.path.abspath(OUTPUT)
    os.makedirs(os.path.dirname(image.filepath_raw), exist_ok=True)
    image.file_format = "OPEN_EXR"
    image.color_mode = "RGBA"
    image.color_depth = "16"
    image.save()
    print("P7 2C2 VDM | output=%s | size=%dx%d | depth=16-bit half-float" % (image.filepath_raw, WIDTH, HEIGHT))
    print("P7 2C2 VDM | min=%s | max=%s" % (min_values, max_values))


if __name__ == "__main__":
    generate()
