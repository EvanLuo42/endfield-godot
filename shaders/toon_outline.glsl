#[compute]

#version 450

// Screen-space toon outline. Silhouettes stay at any distance; inner
// creases (normals / small depth) fade once a pixel covers too much
// world-space detail, which is what made the full-body view look dirty.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(set = 0, binding = 2) uniform sampler2D normal_texture;

layout(push_constant, std430) uniform Params {
	mat4 inv_projection;
	vec2 raster_size;
	float edge_width;
	float depth_threshold;
	float normal_threshold;
	float depth_weight;
	float normal_weight;
	float strength;
	vec4 outline_color;
	float fade_start;
	float fade_end;
	float inner_near;
	float inner_far;
} params;

const float SKY_DEPTH = 1e-6;
const float SKY_LINEAR = 1.0e6;
// World-space gap, in pixel footprints, that counts as a true silhouette.
const float SILHOUETTE_PIXELS = 52.0;
const float INNER_GAP_PIXELS = 10.0;

vec4 normal_roughness_compatibility(vec4 packed_nr) {
	float roughness = packed_nr.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	return vec4(normalize(packed_nr.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

float raw_depth_at(ivec2 pixel, ivec2 size) {
	ivec2 clamped = clamp(pixel, ivec2(0), size - ivec2(1));
	return texelFetch(depth_texture, clamped, 0).r;
}

vec3 view_normal_at(ivec2 pixel, ivec2 size) {
	ivec2 clamped = clamp(pixel, ivec2(0), size - ivec2(1));
	vec4 packed_nr = texelFetch(normal_texture, clamped, 0);
	vec3 encoded = normal_roughness_compatibility(packed_nr).xyz;
	vec3 n = encoded * 2.0 - 1.0;
	float n_len = length(n);
	return n_len > 1e-5 ? n / n_len : vec3(0.0, 0.0, 1.0);
}

float linear_depth(float raw_depth, vec2 uv) {
	if (raw_depth <= SKY_DEPTH) {
		return SKY_LINEAR;
	}
	vec3 ndc = vec3(uv * 2.0 - 1.0, raw_depth);
	vec4 view = params.inv_projection * vec4(ndc, 1.0);
	float w = view.w;
	if (abs(w) < 1e-8) {
		return SKY_LINEAR;
	}
	return abs(view.z / w);
}

float pixel_world_size(float raw_depth, vec2 uv) {
	vec2 texel_ndc = vec2(2.0) / params.raster_size;
	vec3 ndc0 = vec3(uv * 2.0 - 1.0, raw_depth);
	vec3 ndc1 = vec3(ndc0.xy + vec2(0.0, texel_ndc.y), raw_depth);
	vec4 v0 = params.inv_projection * vec4(ndc0, 1.0);
	vec4 v1 = params.inv_projection * vec4(ndc1, 1.0);
	if (abs(v0.w) < 1e-8 || abs(v1.w) < 1e-8) {
		return 1.0;
	}
	return max(length(v1.xyz / v1.w - v0.xyz / v0.w), 1e-6);
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.raster_size);
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}

	vec4 source = imageLoad(color_image, pixel);
	float raw_center = raw_depth_at(pixel, size);
	if (raw_center <= SKY_DEPTH) {
		return;
	}

	vec2 uv_center = (vec2(pixel) + vec2(0.5)) / params.raster_size;
	float depth_center = linear_depth(raw_center, uv_center);
	vec3 normal_center = view_normal_at(pixel, size);
	float pixel_world = pixel_world_size(raw_center, uv_center);

	float inner_keep = 1.0 - smoothstep(
		params.inner_near,
		max(params.inner_far, params.inner_near + 1e-3),
		depth_center
	);
	float far_fade = 1.0 - smoothstep(
		params.fade_start,
		max(params.fade_end, params.fade_start + 1e-3),
		depth_center
	);

	float sil_gap = pixel_world * SILHOUETTE_PIXELS * max(params.depth_threshold / 0.035, 0.25);
	float inner_gap = pixel_world * INNER_GAP_PIXELS;

	int radius = max(int(params.edge_width + 0.25), 1);
	ivec2 offsets[4] = ivec2[](
		ivec2(radius, 0), ivec2(-radius, 0),
		ivec2(0, radius), ivec2(0, -radius)
	);

	float silhouette = 0.0;
	float inner_depth = 0.0;
	float inner_normal = 0.0;
	for (int i = 0; i < 4; i++) {
		ivec2 sample_pixel = pixel + offsets[i];
		vec2 sample_uv = (vec2(sample_pixel) + vec2(0.5)) / params.raster_size;
		float sample_depth = linear_depth(raw_depth_at(sample_pixel, size), sample_uv);
		// Only the near pixel of a depth jump, so the line is 1px instead of both sides.
		float behind = sample_depth - depth_center;

		float sil = sample_depth >= SKY_LINEAR * 0.5
			? 1.0
			: smoothstep(sil_gap * 0.85, sil_gap, behind);
		silhouette = max(silhouette, sil);

		if (inner_keep > 0.001) {
			inner_depth = max(inner_depth, smoothstep(inner_gap, inner_gap * 2.2, behind));
			vec3 sample_normal = view_normal_at(sample_pixel, size);
			inner_normal = max(inner_normal, 1.0 - dot(normal_center, sample_normal));
		}
	}

	float depth_line = silhouette * params.depth_weight;
	float inner_line = 0.0;
	if (inner_keep > 0.001) {
		float normal_line = smoothstep(
			params.normal_threshold,
			params.normal_threshold * 1.5 + 1e-4,
			inner_normal
		);
		inner_line = inner_keep * max(inner_depth * 0.65, normal_line * params.normal_weight);
	}

	float edge = clamp(max(depth_line, inner_line) * far_fade * params.strength, 0.0, 1.0);
	if (edge < 0.001) {
		return;
	}

	vec3 outlined = mix(source.rgb, params.outline_color.rgb, edge);
	imageStore(color_image, pixel, vec4(outlined, source.a));
}
