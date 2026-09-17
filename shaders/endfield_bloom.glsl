#[compute]

#version 450

// Endfield-style HDR bloom pyramid + rounded-rect vignette.
// Bloom is extracted and composited in linear HDR before the LogC tonemap.
// Prefilter matches the game's 13-tap Karis / quadratic-knee threshold.
// Vignette matches the uberpost independent-axis 1-dot(q,q) falloff.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D src_texture;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
layout(rgba16f, set = 0, binding = 2) uniform restrict image2D dest_image;

layout(push_constant, std430) uniform Params {
	vec2 src_size;
	vec2 dst_size;
	float mode;
	float threshold;
	float knee;
	float intensity;
	float vignette_strength;
	float vignette_intensity;
	float vignette_power;
	float vignette_roundness;
	vec4 vignette_color;
	float anamorphic_ratio;
	float bloom_scatter;
	vec2 reserved;
} params;

const float MODE_PREFILTER = 0.0;
const float MODE_DOWNSAMPLE = 1.0;
const float MODE_UPSAMPLE = 2.0;
const float MODE_COMPOSITE = 3.0;
const float SKY_DEPTH = 1e-6;

vec3 sample_src(vec2 uv) {
	return max(textureLod(src_texture, uv, 0.0).rgb, vec3(0.0));
}

float luma(vec3 color) {
	return dot(color, vec3(0.2126729, 0.7151522, 0.0721750));
}

float quadratic_threshold(float brightness) {
	float threshold = max(params.threshold, 0.0);
	float knee = max(params.knee * threshold, 1e-5);
	float soft_start = threshold - knee;
	float rq = clamp(brightness - soft_start, 0.0, knee * 2.0);
	rq = (0.25 / knee) * rq * rq;
	return max(rq, brightness - threshold) / max(brightness, 1e-4);
}

vec3 apply_threshold(vec3 color) {
	return color * quadratic_threshold(max(color.r, max(color.g, color.b)));
}

// Weighted 13-tap, Karis-normalized to kill fireflies. Same tap set as Endfield.
vec3 filter_13(vec2 uv, vec2 texel, bool threshold_taps) {
	const vec3 taps[13] = vec3[](
		vec3( 0.0,  0.0, 4.0),
		vec3(-2.0, -2.0, 1.0),
		vec3( 2.0, -2.0, 1.0),
		vec3( 2.0,  2.0, 1.0),
		vec3(-2.0,  2.0, 1.0),
		vec3(-2.0,  0.0, 2.0),
		vec3( 2.0,  0.0, 2.0),
		vec3( 0.0,  2.0, 2.0),
		vec3( 0.0, -2.0, 2.0),
		vec3(-1.0,  1.0, 4.0),
		vec3( 1.0,  1.0, 4.0),
		vec3(-1.0, -1.0, 4.0),
		vec3( 1.0, -1.0, 4.0)
	);

	vec3 accum = vec3(0.0);
	float weight_sum = 0.0;
	for (int i = 0; i < 13; i++) {
		vec3 color = sample_src(uv + taps[i].xy * texel);
		if (threshold_taps) {
			color = apply_threshold(color);
		}
		float weight = taps[i].z / (1.0 + luma(color));
		accum += color * weight;
		weight_sum += weight;
	}
	return accum / max(weight_sum, 1e-5);
}

vec3 tent_upsample(vec2 uv, vec2 texel) {
	vec3 color = vec3(0.0);
	color += sample_src(uv + vec2(-texel.x, -texel.y)) * 1.0;
	color += sample_src(uv + vec2( 0.0,     -texel.y)) * 2.0;
	color += sample_src(uv + vec2( texel.x, -texel.y)) * 1.0;
	color += sample_src(uv + vec2(-texel.x,  0.0)) * 2.0;
	color += sample_src(uv) * 4.0;
	color += sample_src(uv + vec2( texel.x,  0.0)) * 2.0;
	color += sample_src(uv + vec2(-texel.x,  texel.y)) * 1.0;
	color += sample_src(uv + vec2( 0.0,      texel.y)) * 2.0;
	color += sample_src(uv + vec2( texel.x,  texel.y)) * 1.0;
	return color / 16.0;
}

vec3 apply_vignette(vec3 color, vec2 uv) {
	if (params.vignette_strength <= 0.0001) {
		return color;
	}

	float aspect = params.dst_size.x / max(params.dst_size.y, 1.0);
	vec2 offset = uv - vec2(0.5);
	vec2 q = abs(offset) * params.vignette_intensity * 2.0;
	q.x *= mix(1.0, aspect, 0.35);
	q = clamp(q, vec2(0.0), vec2(1.0));
	q = pow(q, vec2(max(params.vignette_power, 0.01)));
	float falloff = 1.0 - dot(q, q);
	falloff = pow(max(falloff, 0.0), max(params.vignette_roundness, 0.01));
	vec3 tinted = mix(params.vignette_color.rgb, vec3(1.0), falloff);
	return color * mix(vec3(1.0), tinted, clamp(params.vignette_strength, 0.0, 1.0));
}

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 dst_size = ivec2(params.dst_size);
	if (pixel.x >= dst_size.x || pixel.y >= dst_size.y) {
		return;
	}

	vec2 uv = (vec2(pixel) + vec2(0.5)) / params.dst_size;
	vec2 src_texel = vec2(1.0) / max(params.src_size, vec2(1.0));
	float horizontal_stretch = mix(1.0, 4.0, clamp(params.anamorphic_ratio, 0.0, 1.0));
	src_texel *= vec2(horizontal_stretch, 1.0) * max(params.bloom_scatter, 0.25);

	if (params.mode < 0.5) {
		if (textureLod(depth_texture, uv, 0.0).r <= SKY_DEPTH) {
			imageStore(dest_image, pixel, vec4(0.0));
			return;
		}
		vec3 bloom = filter_13(uv, src_texel, true);
		imageStore(dest_image, pixel, vec4(bloom, 1.0));
		return;
	}

	if (params.mode < 1.5) {
		vec3 bloom = filter_13(uv, src_texel, false);
		imageStore(dest_image, pixel, vec4(bloom, 1.0));
		return;
	}

	if (params.mode < 2.5) {
		vec3 current = max(imageLoad(dest_image, pixel).rgb, vec3(0.0));
		vec3 upsampled = tent_upsample(uv, src_texel);
		imageStore(dest_image, pixel, vec4(current + upsampled, 1.0));
		return;
	}

	vec4 source = imageLoad(dest_image, pixel);
	vec3 color = max(source.rgb, vec3(0.0));
	if (params.intensity > 0.0001) {
		color += sample_src(uv) * params.intensity;
	}
	color = apply_vignette(color, uv);
	imageStore(dest_image, pixel, vec4(color, source.a));
}
