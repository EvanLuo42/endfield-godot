#[compute]

#version 450

// Conservative post-TAA contrast-adaptive sharpen. Pass 0 writes to a private
// full-resolution buffer; pass 1 copies it back, avoiding in-place neighbor races.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(set = 0, binding = 0) uniform sampler2D src_texture;
layout(rgba16f, set = 0, binding = 1) uniform restrict image2D dest_image;

layout(push_constant, std430) uniform Params {
	vec2 raster_size;
	float mode;
	float strength;
	float clamp_strength;
	float highlight_suppression;
	vec2 reserved;
} params;

vec3 fetch_color(ivec2 pixel, ivec2 size) {
	return max(texelFetch(src_texture, clamp(pixel, ivec2(0), size - ivec2(1)), 0).rgb, vec3(0.0));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	vec4 source = texelFetch(src_texture, pixel, 0);
	if (params.mode > 0.5) {
		imageStore(dest_image, pixel, source);
		return;
	}

	vec3 center = max(source.rgb, vec3(0.0));
	vec3 north = fetch_color(pixel + ivec2(0, -1), size);
	vec3 south = fetch_color(pixel + ivec2(0, 1), size);
	vec3 east = fetch_color(pixel + ivec2(1, 0), size);
	vec3 west = fetch_color(pixel + ivec2(-1, 0), size);
	vec3 blur = (north + south + east + west) * 0.25;
	vec3 local_min = min(center, min(min(north, south), min(east, west)));
	vec3 local_max = max(center, max(max(north, south), max(east, west)));
	float peak = max(center.r, max(center.g, center.b));
	float highlight_gate = 1.0 - smoothstep(
		params.highlight_suppression,
		params.highlight_suppression * 2.0 + 1e-4,
		peak
	);
	vec3 sharpened = center + (center - blur) * params.strength * mix(0.35, 1.0, highlight_gate);
	vec3 margin = (local_max - local_min) * params.clamp_strength + vec3(1.0 / 1024.0);
	sharpened = clamp(sharpened, local_min - margin, local_max + margin);
	imageStore(dest_image, pixel, vec4(max(sharpened, vec3(0.0)), source.a));
}
