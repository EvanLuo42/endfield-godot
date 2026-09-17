#[compute]

#version 450

// One-sided, depth-derived character rim. It is drawn on the near side of a
// silhouette and gated by the key-light direction, so it stays thin and does
// not turn the entire character into an emissive sticker.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler2D normal_texture;

layout(push_constant, std430) uniform Params {
	mat4 inv_projection;
	vec2 raster_size;
	float rim_width;
	float rim_strength;
	vec4 rim_color;
	vec4 light_view_max_depth;
	float depth_threshold;
	float fade_start;
	float fade_end;
	float directional_weight;
} params;

const float SKY_DEPTH = 1e-6;
const float SKY_LINEAR = 1.0e6;

float raw_depth_at(ivec2 pixel, ivec2 size) {
	return texelFetch(depth_texture, clamp(pixel, ivec2(0), size - ivec2(1)), 0).r;
}

float linear_depth(float raw_depth, vec2 uv) {
	if (raw_depth <= SKY_DEPTH) {
		return SKY_LINEAR;
	}
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
	vec4 view = params.inv_projection * vec4(ndc, 1.0);
	return abs(view.z / max(abs(view.w), 1e-7));
}

vec3 view_normal_at(ivec2 pixel, ivec2 size) {
	vec4 packed = texelFetch(normal_texture, clamp(pixel, ivec2(0), size - ivec2(1)), 0);
	vec3 normal = packed.xyz * 2.0 - 1.0;
	float normal_length = length(normal);
	return normal_length > 1e-5 ? normal / normal_length : vec3(0.0, 0.0, 1.0);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	float raw_center = raw_depth_at(pixel, size);
	if (raw_center <= SKY_DEPTH) {
		return;
	}
	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.raster_size;
	float center_depth = linear_depth(raw_center, uv);
	if (center_depth > params.light_view_max_depth.w) {
		return;
	}

	vec3 normal = view_normal_at(pixel, size);
	vec3 light_view = normalize(params.light_view_max_depth.xyz);
	vec2 light_screen = light_view.xy;
	float light_screen_length = length(light_screen);
	light_screen = light_screen_length > 1e-5 ? light_screen / light_screen_length : vec2(-0.7, -0.7);

	int radius = max(int(params.rim_width + 0.5), 1);
	ivec2 offsets[8] = ivec2[](
		ivec2(radius, 0), ivec2(-radius, 0), ivec2(0, radius), ivec2(0, -radius),
		ivec2(radius, radius), ivec2(-radius, radius),
		ivec2(radius, -radius), ivec2(-radius, -radius)
	);

	float edge = 0.0;
	float relative_threshold = max(params.depth_threshold, center_depth * 0.006);
	for (int index = 0; index < 8; index++) {
		ivec2 sample_pixel = pixel + offsets[index];
		vec2 sample_uv = (vec2(sample_pixel) + vec2(0.5)) / params.raster_size;
		float sample_depth = linear_depth(raw_depth_at(sample_pixel, size), sample_uv);
		float behind = sample_depth - center_depth;
		float depth_edge = sample_depth >= SKY_LINEAR * 0.5
			? 1.0
			: smoothstep(relative_threshold, relative_threshold * 2.0, behind);
		vec2 outward = normalize(vec2(offsets[index]));
		float side = max(dot(outward, light_screen), 0.0);
		float side_gate = mix(1.0, side, clamp(params.directional_weight, 0.0, 1.0));
		edge = max(edge, depth_edge * side_gate);
	}

	float n_dot_l = dot(normal, light_view);
	float light_gate = mix(0.35, 1.0, smoothstep(-0.35, 0.55, n_dot_l));
	float distance_fade = 1.0 - smoothstep(
		params.fade_start,
		max(params.fade_end, params.fade_start + 1e-3),
		center_depth
	);
	float rim = clamp(edge * light_gate * distance_fade * params.rim_strength, 0.0, 1.0);
	if (rim <= 0.0001) {
		return;
	}

	vec4 source = imageLoad(color_image, pixel);
	vec3 color = source.rgb + params.rim_color.rgb * rim;
	imageStore(color_image, pixel, vec4(color, source.a));
}
