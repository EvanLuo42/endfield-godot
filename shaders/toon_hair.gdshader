shader_type spatial;

// Hair volume stays opaque so it writes depth and casts shadows with the head.
render_mode depth_draw_opaque, cull_back;

group_uniforms Textures;
uniform sampler2D base_color_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
// Hair normal (HN): tangent-space X/Y in R/G, same packing as the other character maps.
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
// R = metallic, G = specular intensity, B = AO, A = smoothness.
uniform sampler2D packed_texture : filter_linear_mipmap_anisotropic, repeat_enable;
// RGB = authored hue ramp, A = authored diffuse transition.
// RD/RS ramps are data (Endfield samples them as non-sRGB).
uniform sampler2D diffuse_ramp_texture : filter_linear, repeat_disable;
uniform sampler2D specular_ramp_texture : filter_linear, repeat_disable;
uniform sampler2D shift_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D jitter_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D hairline_texture : filter_linear_mipmap_anisotropic, repeat_enable;

group_uniforms Surface;
uniform vec4 base_color_tint : source_color = vec4(1.0);
uniform float normal_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform bool flip_normal_y = false;
uniform float albedo_strength : hint_range(0.01, 4.0, 0.01) = 1.0;
uniform float albedo_dark_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float albedo_dark_saturation : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float darkest_layer_strength : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float ramp_tint_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float view_darkening_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float minimum_roughness : hint_range(0.02, 1.0, 0.001) = 0.55;
uniform float alpha_scissor : hint_range(0.0, 1.0, 0.01) = 0.01;

group_uniforms Anisotropy;
uniform bool use_tangent_as_fiber = false;
uniform float primary_shift : hint_range(-1.0, 1.0, 0.01) = 0.1;
uniform float secondary_shift : hint_range(-1.0, 1.0, 0.01) = 0.3;
uniform float shift_strength : hint_range(0.0, 2.0, 0.01) = 0.5;
uniform float jitter_strength : hint_range(0.0, 2.0, 0.01) = 0.2;
uniform float jitter_tiling : hint_range(0.25, 32.0, 0.25) = 4.0;
uniform float hairline_strength : hint_range(0.0, 1.0, 0.01) = 0.25;
uniform float hairline_tiling : hint_range(0.25, 32.0, 0.25) = 8.0;
// HN maps pack diffuse XY in RG and spec XY in BA. Regular _N maps leave this off.
uniform bool use_split_spec_normal = true;
uniform float spec_ramp_mix : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float primary_exponent : hint_range(4.0, 256.0, 1.0) = 80.0;
uniform float secondary_exponent : hint_range(4.0, 128.0, 1.0) = 20.0;
uniform float primary_intensity : hint_range(0.0, 8.0, 0.01) = 1.6;
uniform float secondary_intensity : hint_range(0.0, 8.0, 0.01) = 0.5;
uniform vec4 specular_color : source_color = vec4(1.0, 0.95, 0.86, 1.0);

group_uniforms Lighting;
uniform float diffuse_strength : hint_range(0.0, 2.0, 0.01) = 0.9;
uniform float specular_strength : hint_range(0.0, 8.0, 0.01) = 1.8;
uniform float reflectivity_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.9;
uniform float shadow_floor : hint_range(0.0, 1.0, 0.01) = 0.18;
uniform float shadow_center : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float shadow_softness : hint_range(0.01, 0.5, 0.01) = 0.16;
uniform vec4 rim_color : source_color = vec4(0.55, 0.7, 1.0, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0, 0.01) = 0.18;
uniform float rim_power : hint_range(0.5, 8.0, 0.1) = 2.8;

varying vec3 dark_to_light_ratio;
varying vec3 darkest_to_light_ratio;
varying vec3 hair_fiber;
varying vec3 spec_normal;
varying float surface_ao;
varying float spec_scale;
varying float tangent_shift;
varying float hairline_mask;


vec3 ramp_hue_effect(vec3 ramp_color) {
	float chroma = max(ramp_color.r, max(ramp_color.g, ramp_color.b))
		- min(ramp_color.r, min(ramp_color.g, ramp_color.b));
	return mix(vec3(1.0), ramp_color, chroma * ramp_tint_strength);
}


vec3 shift_tangent(vec3 tangent, vec3 normal, float shift) {
	return normalize(tangent + normal * shift);
}


vec4 sample_diff_ramp(sampler2D ramp, float u) {
	vec2 sz = vec2(textureSize(ramp, 0));
	float half_texel = 0.5 / max(sz.x, 1.0);
	return texture(ramp, vec2(clamp(u, half_texel, 1.0 - half_texel), 0.5));
}


vec3 map_tangent_normal(vec3 geom_normal, vec3 tangent, vec3 binormal, vec2 xy) {
	float z = sqrt(max(1.0 - dot(xy, xy), 0.0));
	return normalize(tangent * xy.x + binormal * xy.y + geom_normal * z);
}


// Scheuermann / ATI HairRendering: spec = dirAtten * sin(T,H)^exponent
float strand_specular(vec3 tangent, vec3 view_direction, vec3 light_direction, float exponent) {
	vec3 half_direction = normalize(light_direction + view_direction);
	float t_dot_h = dot(tangent, half_direction);
	float sin_th = sqrt(max(1.0 - t_dot_h * t_dot_h, 0.0));
	float dir_atten = smoothstep(-1.0, 0.0, t_dot_h);
	return dir_atten * pow(sin_th, exponent);
}


vec3 sample_spec_ramp(float sin_th, float t_dot_h, float edge_fade) {
	// Sharp U so the lookup jumps black → gold and skips the cyan mid-band.
	// Packed G (spec_scale) is intensity only — putting it in U pulled highlights
	// into U 0.61-0.74, which is authored cyan.
	float strand = exp2(log2(max(sin_th, 1e-4)) * 200.0);
	vec2 ramp_size = vec2(textureSize(specular_ramp_texture, 0));
	vec2 half_texel = 0.5 / max(ramp_size, vec2(1.0));
	// Unity V=0 is the image bottom (orange); Godot V=0 is the top (gold).
	float v_unity = edge_fade * edge_fade * float(t_dot_h > 0.0);
	vec2 ramp_uv = vec2(clamp(strand, 0.0, 1.0), 1.0 - v_unity);
	ramp_uv = clamp(ramp_uv, half_texel, vec2(1.0) - half_texel);
	return textureLod(specular_ramp_texture, ramp_uv, 0.0).rgb;
}


void fragment() {
	vec4 base_sample = texture(base_color_texture, UV) * base_color_tint;
	vec4 packed_sample = texture(packed_texture, UV);

	vec3 geom_normal = normalize(NORMAL);
	vec4 hn_sample = texture(normal_texture, UV);
	vec2 diffuse_xy = hn_sample.rg * 2.0 - 1.0;
	if (flip_normal_y) {
		diffuse_xy.y = -diffuse_xy.y;
	}
	diffuse_xy *= normal_strength;
	NORMAL = map_tangent_normal(geom_normal, TANGENT, BINORMAL, diffuse_xy);

	if (use_split_spec_normal) {
		vec2 spec_xy = hn_sample.ba * 2.0 - 1.0;
		if (flip_normal_y) {
			spec_xy.y = -spec_xy.y;
		}
		spec_xy *= normal_strength;
		spec_normal = map_tangent_normal(geom_normal, TANGENT, BINORMAL, spec_xy);
	} else {
		spec_normal = NORMAL;
	}

	hair_fiber = normalize(use_tangent_as_fiber ? TANGENT : BINORMAL);

	float shift_map = texture(shift_texture, UV).r - 0.5;
	float jitter_map = texture(jitter_texture, vec2(UV.x * jitter_tiling, UV.y)).r - 0.5;
	tangent_shift = shift_map * shift_strength + jitter_map * jitter_strength;
	hairline_mask = texture(hairline_texture, vec2(UV.x * hairline_tiling, UV.y)).r;

	vec3 base_color = clamp(base_sample.rgb, vec3(0.0), vec3(1.0));
	vec3 light_color = pow(base_color, vec3(albedo_strength));
	vec3 dark_color = light_color * albedo_dark_strength;
	float dark_luma = dot(dark_color, vec3(0.2126, 0.7152, 0.0722));
	dark_color = mix(vec3(dark_luma), dark_color, albedo_dark_saturation);
	vec3 darkest_color = dark_color * darkest_layer_strength;

	ALBEDO = light_color;
	dark_to_light_ratio = dark_color / max(light_color, vec3(0.001));
	darkest_to_light_ratio = darkest_color / max(light_color, vec3(0.001));

	METALLIC = 0.0;
	ROUGHNESS = max(1.0 - packed_sample.a, minimum_roughness);
	surface_ao = clamp(packed_sample.b, 0.0, 1.0);
	spec_scale = clamp(packed_sample.g * reflectivity_strength, 0.0, 2.0);
	AO = surface_ao;
	AO_LIGHT_AFFECT = 0.0;
	SPECULAR = 0.0;
	ALPHA = base_sample.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
}


void light() {
	vec3 normal = normalize(NORMAL);
	vec3 aniso_normal = normalize(spec_normal);
	vec3 light_direction = normalize(LIGHT);
	vec3 view_direction = normalize(VIEW);
	vec3 fiber = normalize(hair_fiber);

	float half_lambert = clamp(dot(normal, light_direction) * 0.5 + 0.5, 0.0, 1.0);
	vec4 ramp = sample_diff_ramp(diffuse_ramp_texture, half_lambert);

	float n_dot_camera_forward = dot(normal, vec3(0.0, 0.0, -1.0));
	float nof_coordinate = clamp(n_dot_camera_forward * 0.5 + 0.5, 0.0, 1.0);
	float nof_ramp = sample_diff_ramp(diffuse_ramp_texture, nof_coordinate).a;
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
	vec3 diffuse_brdf = albedo_ratio
		* ramp_hue_effect(ramp.rgb)
		* 0.96
		* diffuse_strength / PI;
	DIFFUSE_LIGHT += diffuse_brdf * LIGHT_COLOR * light_attenuation;

	vec3 primary_tangent = shift_tangent(fiber, aniso_normal, primary_shift + tangent_shift);
	vec3 secondary_tangent = shift_tangent(fiber, aniso_normal, secondary_shift + tangent_shift);
	float strand_break = mix(1.0, hairline_mask, hairline_strength);
	float primary_spec = strand_specular(
		primary_tangent, view_direction, light_direction, primary_exponent
	) * primary_intensity * strand_break * spec_scale;
	float secondary_spec = strand_specular(
		secondary_tangent, view_direction, light_direction, secondary_exponent
	) * secondary_intensity * strand_break * spec_scale;

	vec3 half_direction = normalize(light_direction + view_direction);
	float t_dot_h = dot(primary_tangent, half_direction);
	float sin_th = sqrt(max(1.0 - t_dot_h * t_dot_h, 0.0));
	vec2 n_xz = normalize(aniso_normal.xz);
	vec2 v_xz = normalize(view_direction.xz);
	float edge_fade = exp2(log2(max(clamp(dot(n_xz, v_xz), 0.0, 1.0), 1e-4)) * 1.0);
	vec3 ramp_spec = sample_spec_ramp(sin_th, t_dot_h, edge_fade);
	vec3 primary_color = mix(specular_color.rgb, ramp_spec, spec_ramp_mix);

	vec3 anisotropic_spec = primary_spec * primary_color
		+ secondary_spec * mix(primary_color, ALBEDO, 0.55);

	float spec_visibility = mix(0.4, 1.0, half_lambert);
	float specular_occlusion = min(surface_ao, shadow_weight);
	SPECULAR_LIGHT += anisotropic_spec
		* LIGHT_COLOR
		* light_attenuation
		* specular_occlusion
		* spec_visibility
		* SPECULAR_AMOUNT
		* specular_strength;

	float n_dot_v = clamp(dot(normal, view_direction), 0.0, 1.0);
	float rim_fresnel = pow(clamp(1.0 - n_dot_v, 0.0, 1.0), rim_power);
	float rim_light = smoothstep(-0.4, 0.65, dot(normal, light_direction));
	float rim = rim_fresnel * mix(0.35, 1.0, rim_light) * rim_strength;
	SPECULAR_LIGHT += rim_color.rgb * rim * LIGHT_COLOR * light_attenuation
		* specular_occlusion / PI;
}
