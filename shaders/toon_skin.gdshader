shader_type spatial;

// Skin is opaque. Its environment specular is disabled in fragment(), while
// the authored direct lobe is evaluated explicitly in light().
render_mode depth_draw_opaque, cull_back;

group_uniforms Textures;
uniform sampler2D diffuse_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// RGB = authored hue ramp, A = authored diffuse transition.
// RD ramp is data; source_color would sRGB-decode and crush the terminator.
uniform sampler2D rd_texture : filter_linear, repeat_disable;
uniform sampler2D diffuse_lut_texture : source_color, filter_linear, repeat_disable;

group_uniforms Surface;
uniform vec4 diffuse_tint : source_color = vec4(1.0);
uniform float normal_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform bool flip_normal_y = false;
uniform float albedo_strength : hint_range(0.01, 4.0, 0.01) = 1.0;
uniform float albedo_dark_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float albedo_dark_saturation : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float darkest_layer_strength : hint_range(0.0, 1.0, 0.01) = 0.65;
uniform bool apply_lut_enabled = true;
uniform float lut_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float ramp_tint_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float view_darkening_strength : hint_range(0.0, 1.0, 0.01) = 0.25;

group_uniforms Skin;
uniform vec4 sss_color : source_color = vec4(1.0, 0.42, 0.36, 1.0);
uniform float sss_strength : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float sss_area : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float skin_roughness : hint_range(0.05, 1.0, 0.01) = 0.55;
uniform float skin_reflectivity : hint_range(0.0, 2.0, 0.01) = 1.0;

group_uniforms Lighting;
uniform float diffuse_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float specular_strength : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform vec4 rim_color : source_color = vec4(1.0, 0.45, 0.38, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0, 0.01) = 0.12;
uniform float rim_power : hint_range(0.5, 8.0, 0.1) = 3.0;
uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.9;
uniform float shadow_floor : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float shadow_center : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float shadow_softness : hint_range(0.01, 0.5, 0.01) = 0.2;

varying vec3 dark_to_light_ratio;
varying vec3 darkest_to_light_ratio;
varying float surface_ao;


vec3 linear_to_srgb(vec3 color) {
	color = max(color, vec3(0.0));
	vec3 low = color * 12.92;
	vec3 high = 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055;
	return mix(low, high, step(vec3(0.0031308), color));
}


vec3 sample_diffuse_lut(vec3 linear_color) {
	vec3 lut_color = clamp(linear_to_srgb(linear_color), vec3(0.0), vec3(1.0));
	vec2 dimensions = vec2(textureSize(diffuse_lut_texture, 0));
	float lut_size = dimensions.y;
	float max_index = lut_size - 1.0;

	float blue_index = lut_color.b * max_index;
	float blue_low = floor(blue_index);
	float blue_high = min(blue_low + 1.0, max_index);
	float blue_blend = fract(blue_index);
	float red_texel = lut_color.r * max_index + 0.5;
	float green_texel = (1.0 - lut_color.g) * max_index + 0.5;

	vec2 uv_low = vec2(
		(blue_low * lut_size + red_texel) / dimensions.x,
		green_texel / dimensions.y
	);
	vec2 uv_high = vec2(
		(blue_high * lut_size + red_texel) / dimensions.x,
		green_texel / dimensions.y
	);
	vec3 color_low = textureLod(diffuse_lut_texture, uv_low, 0.0).rgb;
	vec3 color_high = textureLod(diffuse_lut_texture, uv_high, 0.0).rgb;
	return mix(color_low, color_high, blue_blend);
}


vec3 ramp_hue_effect(vec3 ramp_color) {
	float chroma = max(ramp_color.r, max(ramp_color.g, ramp_color.b))
		- min(ramp_color.r, min(ramp_color.g, ramp_color.b));
	return mix(vec3(1.0), ramp_color, chroma * ramp_tint_strength);
}


// Godot view space: +Z faces the camera. Endfield camFwd is look-into-scene = -Z.
vec4 sample_diff_ramp(sampler2D ramp, float u) {
	vec2 sz = vec2(textureSize(ramp, 0));
	float half_texel = 0.5 / max(sz.x, 1.0);
	return texture(ramp, vec2(clamp(u, half_texel, 1.0 - half_texel), 0.5));
}


float stylized_ggx(vec3 normal, vec3 view_direction, vec3 light_direction, float perceptual_roughness) {
	vec3 cam_fwd_mod = normalize(vec3(0.0, light_direction.y, -1.0));
	vec3 half_direction = normalize(view_direction * 3.0 + light_direction + cam_fwd_mod * 2.0);
	float n_dot_h = max(dot(normal, half_direction), 0.0);
	float n_dot_v = max(dot(normal, view_direction), 1e-4);
	float alpha = max(perceptual_roughness * perceptual_roughness, 0.0078125);
	float alpha4 = alpha * alpha;
	float d = (n_dot_h * alpha4 - n_dot_h) * n_dot_h + 1.0;
	float distribution = min(alpha4 / max(d * d, 1e-7), 2048.0);
	return clamp(distribution * 0.5 / (n_dot_v * 2.0 + alpha + 1e-4), 0.0, 20.0);
}


vec3 wrap_subsurface(
	vec3 normal, vec3 view_direction, vec3 light_direction, vec3 albedo, float mask
) {
	float light_xz_len = length(light_direction.xz);
	float n_dot_l_xz = light_xz_len > 1e-5
		? dot(vec3(light_direction.x, 0.0, light_direction.z) / light_xz_len, normal)
		: 0.0;
	float wrap = clamp(0.5 + n_dot_l_xz - 0.5 * n_dot_l_xz * n_dot_l_xz, 0.0, 1.0);
	float edge_t = clamp((-abs(dot(view_direction, normal)) + 0.4) * 5.0, 0.0, 1.0);
	float luma = dot(albedo, vec3(0.2126729, 0.7151522, 0.0721750));
	float bright_t = clamp((0.1 - luma) * 16.666, 0.0, 1.0);
	float cam_light = light_xz_len > 1e-5 ? clamp(light_direction.z / light_xz_len, 0.0, 1.0) : 0.0;
	float gate = bright_t * bright_t * (3.0 - 2.0 * bright_t)
		* edge_t * edge_t * (3.0 - 2.0 * edge_t);
	return gate * mask * cam_light * wrap * max(albedo, vec3(0.15));
}


void fragment() {
	vec4 diffuse_sample = texture(diffuse_texture, UV) * diffuse_tint;

	vec2 normal_xy = texture(normal_texture, UV).rg * 2.0 - 1.0;
	if (flip_normal_y) {
		normal_xy.y = -normal_xy.y;
	}
	normal_xy *= normal_strength;
	float normal_z = sqrt(max(1.0 - dot(normal_xy, normal_xy), 0.0));
	vec3 tangent_normal = normalize(vec3(normal_xy, normal_z));
	NORMAL = normalize(
		TANGENT * tangent_normal.x
		+ BINORMAL * tangent_normal.y
		+ NORMAL * tangent_normal.z
	);

	vec3 base_color = clamp(diffuse_sample.rgb, vec3(0.0), vec3(1.0));
	float n_dot_v = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float sss_no_v = n_dot_v * 0.85 + 0.15;
	float sss_weight = clamp(sss_area * (1.0 - sss_no_v), 0.0, 1.0) * sss_strength;
	base_color *= mix(vec3(1.0), sss_color.rgb, sss_weight);

	vec3 light_color = pow(base_color, vec3(albedo_strength));
	vec3 dark_color = light_color * albedo_dark_strength;
	if (apply_lut_enabled) {
		vec3 lut_dark = sample_diffuse_lut(base_color) * albedo_dark_strength;
		dark_color = mix(dark_color, lut_dark, lut_strength);
	}
	float dark_luma = dot(dark_color, vec3(0.2126, 0.7152, 0.0722));
	dark_color = mix(vec3(dark_luma), dark_color, albedo_dark_saturation);
	vec3 darkest_color = dark_color * darkest_layer_strength;

	ALBEDO = light_color;
	dark_to_light_ratio = dark_color / max(light_color, vec3(0.001));
	darkest_to_light_ratio = darkest_color / max(light_color, vec3(0.001));
	surface_ao = clamp(diffuse_sample.a, 0.0, 1.0);
	AO = surface_ao;
	AO_LIGHT_AFFECT = 0.0;
	METALLIC = 0.0;
	ROUGHNESS = skin_roughness;
	// Disable the generic environment lobe without disabling custom direct specular.
	SPECULAR = 0.0;
}


void light() {
	vec3 normal = normalize(NORMAL);
	vec3 light_direction = normalize(LIGHT);
	vec3 view_direction = normalize(VIEW);
	float half_lambert = clamp(dot(normal, light_direction) * 0.5 + 0.5, 0.0, 1.0);
	vec4 ramp = sample_diff_ramp(rd_texture, half_lambert);
	float n_dot_camera_forward = dot(normal, vec3(0.0, 0.0, -1.0));
	float nof_coordinate = clamp(n_dot_camera_forward * 0.5 + 0.5, 0.0, 1.0);
	float nof_ramp = sample_diff_ramp(rd_texture, nof_coordinate).a;
	float nof_weight = mix(1.0, nof_ramp, view_darkening_strength);

	float raw_scene_shadow = LIGHT_IS_DIRECTIONAL ? clamp(ATTENUATION, 0.0, 1.0) : 1.0;
	float scene_shadow = smoothstep(
		shadow_center - shadow_softness,
		shadow_center + shadow_softness,
		raw_scene_shadow
	);
	float shadow_weight = mix(1.0, scene_shadow, shadow_strength);
	float light_attenuation = LIGHT_IS_DIRECTIONAL
		? mix(shadow_floor, 1.0, shadow_weight)
		: ATTENUATION;
	float lit_weight = min(surface_ao, min(shadow_weight, ramp.a));
	float dark_weight = min(surface_ao, min(nof_weight, shadow_weight));
	vec3 albedo_ratio = mix(darkest_to_light_ratio, dark_to_light_ratio, dark_weight);
	albedo_ratio = mix(albedo_ratio, vec3(1.0), lit_weight);

	vec3 diffuse_brdf = albedo_ratio * ramp_hue_effect(ramp.rgb)
		* 0.96 * diffuse_strength / PI;
	DIFFUSE_LIGHT += diffuse_brdf * LIGHT_COLOR * light_attenuation;

	vec3 spec_color = vec3(0.04 * skin_reflectivity);
	float ggx_term = stylized_ggx(normal, view_direction, light_direction, ROUGHNESS);
	float specular_occlusion = min(surface_ao, shadow_weight);
	SPECULAR_LIGHT += spec_color * ggx_term
		* LIGHT_COLOR * light_attenuation * specular_occlusion
		* SPECULAR_AMOUNT * specular_strength / PI;

	SPECULAR_LIGHT += wrap_subsurface(
		normal, view_direction, light_direction, ALBEDO, specular_occlusion
	) * LIGHT_COLOR * light_attenuation / PI;

	float n_dot_v = clamp(dot(normal, view_direction), 0.0, 1.0);
	float rim_fresnel = pow(clamp(1.0 - n_dot_v, 0.0, 1.0), rim_power);
	float rim_light = smoothstep(-0.35, 0.65, dot(normal, light_direction));
	float rim = rim_fresnel * mix(0.3, 1.0, rim_light) * rim_strength;
	SPECULAR_LIGHT += rim_color.rgb * rim * LIGHT_COLOR * light_attenuation
		* specular_occlusion / PI;
}
