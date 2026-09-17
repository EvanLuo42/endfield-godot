#[compute]

#version 450

// Endfield-style display transform for Godot's HDR scene color.
// The real game bakes its filmic curve and grade into a LogC-addressed LUT.
// This shader keeps the same pipeline shape and supplies a procedural fallback
// until an extracted/authored LUT is assigned to the CompositorEffect.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D color_lut;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float exposure_ev;
	float contrast;
	float saturation;
	float toe_strength;
	float white_point;
	float lut_strength;
	float lut_size;
	float dither_strength;
	float frame_index;
	float reserved;
} params;

const float LOGC_CUT = 0.011361;
const float LOGC_A = 5.555556;
const float LOGC_B = 0.047996;
const float LOGC_C = 0.244161;
const float LOGC_D = 0.386036;
const float LOGC_E = 5.301883;
const float LOGC_F = 0.092819;

float linear_to_logc_channel(float value) {
	if (value > LOGC_CUT) {
		return LOGC_C * log2(LOGC_A * value + LOGC_B) / log2(10.0) + LOGC_D;
	}
	return LOGC_E * value + LOGC_F;
}

vec3 linear_to_logc(vec3 value) {
	return vec3(
		linear_to_logc_channel(value.r),
		linear_to_logc_channel(value.g),
		linear_to_logc_channel(value.b)
	);
}

float logc_to_linear_channel(float value) {
	float breakpoint = LOGC_E * LOGC_CUT + LOGC_F;
	if (value > breakpoint) {
		return (pow(10.0, (value - LOGC_D) / LOGC_C) - LOGC_B) / LOGC_A;
	}
	return (value - LOGC_F) / LOGC_E;
}

vec3 logc_to_linear(vec3 value) {
	return vec3(
		logc_to_linear_channel(value.r),
		logc_to_linear_channel(value.g),
		logc_to_linear_channel(value.b)
	);
}

vec3 apply_log_grade(vec3 log_color) {
	float log_mid_gray = linear_to_logc_channel(0.18);
	log_color = (log_color - vec3(log_mid_gray)) * params.contrast + vec3(log_mid_gray);
	return log_color;
}

// Unity-style horizontal LUT strip: width = size * size, height = size.
// R runs within a slice, G vertically, and B selects adjacent slices.
vec3 sample_logc_lut(vec3 log_color) {
	float size = params.lut_size;
	float blue = clamp(log_color.b, 0.0, 1.0) * (size - 1.0);
	float blue_slice = floor(blue);
	float blue_mix = blue - blue_slice;
	vec2 texture_size = vec2(size * size, size);
	vec2 pixel = vec2(
		clamp(log_color.r, 0.0, 1.0) * (size - 1.0),
		clamp(log_color.g, 0.0, 1.0) * (size - 1.0)
	);
	vec2 uv0 = (pixel + vec2(blue_slice * size, 0.0) + vec2(0.5)) / texture_size;
	vec2 uv1 = (pixel + vec2(min(blue_slice + 1.0, size - 1.0) * size, 0.0) + vec2(0.5)) / texture_size;
	return mix(texture(color_lut, uv0).rgb, texture(color_lut, uv1).rgb, blue_mix);
}

// A compact custom filmic response. It is applied by the maximum channel so
// saturated highlights retain their hue instead of drifting channel-by-channel.
float filmic_peak(float value) {
	value = max(value, 0.0);
	value = pow(value, 1.0 + 0.35 * params.toe_strength);
	float white = max(params.white_point, 1.0);
	float mapped = value * (1.0 + value / (white * white)) / (1.0 + value);
	return clamp(mapped, 0.0, 1.0);
}

vec3 procedural_tonemap(vec3 scene_color) {
	float peak = max(scene_color.r, max(scene_color.g, scene_color.b));
	if (peak <= 0.000001) {
		return vec3(0.0);
	}
	float mapped_peak = filmic_peak(peak);
	vec3 display_color = scene_color * (mapped_peak / peak);
	float luminance = dot(display_color, vec3(0.2126729, 0.7151522, 0.0721750));
	display_color = mix(vec3(luminance), display_color, params.saturation);
	return clamp(display_color, 0.0, 1.0);
}

vec3 linear_to_srgb(vec3 value) {
	vec3 low = value * 12.92;
	vec3 high = 1.055 * pow(max(value, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
	return mix(high, low, lessThanEqual(value, vec3(0.0031308)));
}

vec3 srgb_to_linear(vec3 value) {
	vec3 low = value / 12.92;
	vec3 high = pow((max(value, vec3(0.0)) + 0.055) / 1.055, vec3(2.4));
	return mix(high, low, lessThanEqual(value, vec3(0.04045)));
}

float interleaved_gradient_noise(vec2 pixel, float frame) {
	vec2 animated_pixel = pixel + vec2(47.0, 17.0) * frame;
	return fract(52.9829189 * fract(dot(animated_pixel, vec2(0.06711056, 0.00583715))));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec4 source = imageLoad(color_image, pixel);
	vec3 exposed = max(source.rgb, vec3(0.0)) * exp2(params.exposure_ev);
	vec3 graded_logc = apply_log_grade(linear_to_logc(exposed));
	vec3 graded_linear = max(logc_to_linear(graded_logc), vec3(0.0));
	vec3 display_color = procedural_tonemap(graded_linear);

	if (params.lut_strength > 0.0001 && params.lut_size >= 2.0) {
		// Imported LUT RGB is expected to represent display-referred output.
		// With a normal sRGB texture import Godot decodes it back to linear here.
		vec3 lut_color = sample_logc_lut(graded_logc);
		display_color = mix(display_color, lut_color, clamp(params.lut_strength, 0.0, 1.0));
	}

	// Dither in sRGB code-value space, then return to linear. Godot performs the
	// actual output transfer after this compositor pass, so gamma is not doubled.
	if (params.dither_strength > 0.0001) {
		vec3 srgb = linear_to_srgb(clamp(display_color, 0.0, 1.0));
		float noise = interleaved_gradient_noise(vec2(pixel), params.frame_index) - 0.5;
		srgb = clamp(srgb + vec3(noise * params.dither_strength / 255.0), 0.0, 1.0);
		display_color = srgb_to_linear(srgb);
	}

	imageStore(color_image, pixel, vec4(display_color, source.a));
}
