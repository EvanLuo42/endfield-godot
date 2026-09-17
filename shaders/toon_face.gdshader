shader_type spatial;

// Endfield face: SDF terminator, 3-band ramp, LUT, flattened spec.
// Reverse-engineered from Straw1997 ttt.glsl notes + this character's maps.
render_mode depth_draw_opaque, cull_back;

group_uniforms Textures;
uniform sampler2D diffuse_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
// R = half-face shadow SDF, G = rembrandt / nose field, B = flattened lighting field.
uniform sampler2D sdf_texture : filter_linear, repeat_disable;
// R = skin vs eyes/mouth, G = eyeshadow / lid, B = inner openings.
uniform sampler2D feature_texture : filter_linear, repeat_disable;
// R = face-center weight, G/B = outside-face, A = rim + lip diamond.
uniform sampler2D color_mask_texture : filter_linear, repeat_disable;
uniform sampler2D highlight_texture : filter_linear, repeat_disable;
uniform sampler2D rd_texture : filter_linear, repeat_disable;
uniform sampler2D diffuse_lut_texture : source_color, filter_linear, repeat_disable;
uniform sampler2D emotion_atlas_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D eyeshadow_texture : filter_linear, repeat_disable;
uniform sampler2D hairshadow_texture : filter_linear, repeat_disable;
uniform sampler2D matcap_texture : source_color, filter_linear, repeat_disable;

group_uniforms Surface;
uniform vec4 diffuse_tint : source_color = vec4(1.0);
uniform float albedo_strength : hint_range(0.01, 4.0, 0.01) = 1.0;
uniform float albedo_dark_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float albedo_dark_saturation : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float darkest_layer_strength : hint_range(0.0, 1.0, 0.01) = 0.62;
uniform bool apply_lut_enabled = true;
uniform float lut_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float ramp_tint_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float view_darkening_strength : hint_range(0.0, 1.0, 0.01) = 0.18;

group_uniforms Head;
// Object-space head basis. Rossi / Unity FBX faces +Z in Godot.
uniform vec3 head_forward_os = vec3(0.0, 0.0, 1.0);
uniform vec3 head_right_os = vec3(1.0, 0.0, 0.0);
uniform vec3 key_light_dir_ws = vec3(0.3, 0.4, 0.86);
uniform vec2 sdf_uv_offset = vec2(0.0);
uniform vec2 sdf_uv_scale = vec2(1.0);
uniform bool flip_sdf_uv = false;

group_uniforms SDF;
uniform float sdf_strength : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float sdf_softness : hint_range(0.001, 0.25, 0.001) = 0.045;
uniform float sdf_threshold_bias : hint_range(-0.5, 0.5, 0.01) = 0.0;
uniform float sdf_front_fill : hint_range(0.0, 1.0, 0.01) = 1.0;
uniform float sdf_toon_amount : hint_range(0.0, 1.0, 0.01) = 0.72;
uniform float rembrandt_strength : hint_range(0.0, 1.0, 0.01) = 0.35;
uniform float flatten_specular : hint_range(0.0, 1.0, 0.01) = 0.65;

group_uniforms Face;
uniform vec4 sss_color : source_color = vec4(1.0, 0.42, 0.36, 1.0);
uniform float sss_strength : hint_range(0.0, 1.0, 0.01) = 0.16;
uniform float sss_area : hint_range(0.0, 4.0, 0.01) = 1.0;
uniform float skin_roughness : hint_range(0.05, 1.0, 0.01) = 0.52;
uniform float skin_reflectivity : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform vec4 eyeshadow_color : source_color = vec4(0.55, 0.32, 0.34, 1.0);
uniform float eyeshadow_strength : hint_range(0.0, 1.0, 0.01) = 0.12;
uniform int emotion_index : hint_range(0, 3, 1) = 0;
uniform float emotion_strength : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform float hair_shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.0;
uniform float hair_shadow_offset : hint_range(-1.0, 1.0, 0.01) = 0.0;
uniform float hair_shadow_light_influence : hint_range(0.0, 0.25, 0.005) = 0.08;
uniform float face_normal_flatten : hint_range(0.0, 1.0, 0.01) = 0.32;
uniform float face_detail_shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.22;
uniform vec4 lip_emission_color : source_color = vec4(0.85, 0.28, 0.32, 1.0);
uniform float lip_emission_strength : hint_range(0.0, 4.0, 0.01) = 0.45;
uniform float matcap_strength : hint_range(0.0, 2.0, 0.01) = 0.12;

group_uniforms Lighting;
uniform float diffuse_strength : hint_range(0.0, 2.0, 0.01) = 0.95;
uniform float specular_strength : hint_range(0.0, 2.0, 0.01) = 0.28;
uniform vec4 rim_color : source_color = vec4(1.0, 0.48, 0.4, 1.0);
uniform float rim_strength : hint_range(0.0, 2.0, 0.01) = 0.16;
uniform float rim_power : hint_range(0.5, 8.0, 0.1) = 3.2;
uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.85;
uniform float shadow_floor : hint_range(0.0, 1.0, 0.01) = 0.24;
uniform float shadow_center : hint_range(0.0, 1.0, 0.01) = 0.5;
uniform float shadow_softness : hint_range(0.01, 0.5, 0.01) = 0.22;

group_uniforms Overlay;
// Lashes only. Clip-space depth bias, faded with camera distance.
uniform float hair_punch_through : hint_range(0.0, 0.02, 0.0005) = 0.0;
uniform float overlay_near : hint_range(0.2, 8.0, 0.05) = 1.6;
uniform float overlay_far : hint_range(0.5, 20.0, 0.05) = 4.0;

varying vec3 dark_to_light_ratio;
varying vec3 darkest_to_light_ratio;
varying vec3 head_forward_ws;
varying vec3 head_right_ws;
varying vec3 spec_normal_view;
varying float surface_ao;
varying float face_mask;
varying float skin_mask;
varying float lip_mask;
varying float rim_mask;
varying float hair_shadow;
varying float lip_highlight;


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


vec2 face_atlas_uv(vec2 uv, int index) {
	int tile = clamp(index, 0, 3);
	vec2 origin = vec2(float(tile % 2), float(tile / 2)) * 0.5;
	return origin + fract(uv) * 0.5;
}


vec2 sdf_uv(vec2 uv, bool mirror) {
	vec2 mapped = uv * sdf_uv_scale + sdf_uv_offset;
	if (flip_sdf_uv) {
		mapped.x = 1.0 - mapped.x;
	}
	if (mirror) {
		mapped.x = 1.0 - mapped.x;
	}
	return mapped;
}


float face_sdf_lit(vec3 light_ws, vec2 uv) {
	vec2 light_h = light_ws.xz;
	vec2 forward_h = head_forward_ws.xz;
	vec2 right_h = head_right_ws.xz;
	float light_len = length(light_h);
	float forward_len = length(forward_h);
	float right_len = length(right_h);
	if (light_len < 1e-5 || forward_len < 1e-5 || right_len < 1e-5) {
		return 1.0;
	}
	light_h /= light_len;
	forward_h /= forward_len;
	right_h /= right_len;

	float f_dot_l = clamp(dot(forward_h, light_h), -1.0, 1.0);
	float r_dot_l = dot(right_h, light_h);
	bool mirror = r_dot_l > 0.0;
	vec4 sdf = texture(sdf_texture, sdf_uv(uv, mirror));

	float thresh = clamp(1.0 - (f_dot_l * 0.5 + 0.5) + sdf_threshold_bias, 0.0, 1.0);
	float softness = max(sdf_softness, 1e-4);
	float hard_lit = smoothstep(thresh - softness, thresh + softness, sdf.r + softness * 0.35);
	float soft_lit = sdf.b;
	float rembrandt = smoothstep(thresh - softness, thresh + softness, sdf.g);
	float combined = mix(soft_lit, hard_lit, sdf_toon_amount);
	combined = mix(combined, max(combined, rembrandt), rembrandt_strength);
	float front = clamp(f_dot_l, 0.0, 1.0);
	combined = max(combined, front * front * sdf_front_fill);
	return clamp(combined, 0.0, 1.0);
}


void vertex() {
	vec3 world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	vec3 world_vertex = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 to_camera = INV_VIEW_MATRIX[3].xyz - world_vertex;
	float cam_dist = length(to_camera);
	to_camera = cam_dist > 1e-5 ? to_camera / cam_dist : vec3(0.0, 0.0, 1.0);
	float facing = clamp(dot(world_normal, to_camera), 0.0, 1.0);
	facing *= facing;
	float dist_fade = 1.0 - smoothstep(overlay_near, max(overlay_far, overlay_near + 1e-3), cam_dist);
	POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float closer = CLIP_SPACE_FAR == 0.0 ? 1.0 : -1.0;
	POSITION.z += closer * hair_punch_through * facing * dist_fade * POSITION.w;
}


void fragment() {
	vec4 diffuse_sample = texture(diffuse_texture, UV) * diffuse_tint;
	vec4 feature = texture(feature_texture, UV);
	vec4 color_mask = texture(color_mask_texture, UV);
	float highlight = texture(highlight_texture, UV).r;

	head_forward_ws = normalize((MODEL_MATRIX * vec4(head_forward_os, 0.0)).xyz);
	head_right_ws = normalize((MODEL_MATRIX * vec4(head_right_os, 0.0)).xyz);

	vec3 geom_normal = normalize(NORMAL);
	vec3 head_forward_view = normalize((VIEW_MATRIX * vec4(head_forward_ws, 0.0)).xyz);
	spec_normal_view = normalize(mix(geom_normal, head_forward_view, flatten_specular));

	skin_mask = clamp(feature.r, 0.0, 1.0);
	face_mask = clamp(1.0 - color_mask.g, 0.0, 1.0) * skin_mask;
	rim_mask = clamp(color_mask.a, 0.0, 1.0);
	lip_highlight = highlight;
	lip_mask = clamp(highlight * 8.0, 0.0, 1.0);
	NORMAL = normalize(mix(geom_normal, head_forward_view, face_normal_flatten * face_mask));

	vec3 base_color = clamp(diffuse_sample.rgb, vec3(0.0), vec3(1.0));

	vec4 emotion = texture(emotion_atlas_texture, face_atlas_uv(UV, emotion_index));
	base_color = mix(base_color, emotion.rgb, clamp(emotion.a * emotion_strength, 0.0, 1.0));

	float lid = clamp(feature.g, 0.0, 1.0);
	// Eyeshadow/hairshadow ramps are vertical in R (Unity V). Godot V=0 is the top.
	float es_ramp = texture(eyeshadow_texture, vec2(0.5, 1.0 - lid)).r;
	base_color = mix(base_color, mix(base_color, eyeshadow_color.rgb, es_ramp), lid * eyeshadow_strength);

	float n_dot_v = clamp(dot(geom_normal, normalize(VIEW)), 0.0, 1.0);
	float sss_no_v = n_dot_v * 0.85 + 0.15;
	float sss_weight = clamp(sss_area * (1.0 - sss_no_v), 0.0, 1.0) * sss_strength * face_mask;
	base_color *= mix(vec3(1.0), sss_color.rgb, sss_weight);

	float light_elevation = clamp(key_light_dir_ws.y, -1.0, 1.0);
	float directional_hair_offset = (0.35 - light_elevation) * hair_shadow_light_influence;
	float hs_u = clamp(1.0 - UV.y + hair_shadow_offset + directional_hair_offset, 0.0, 1.0);
	hair_shadow = mix(1.0, texture(hairshadow_texture, vec2(0.5, hs_u)).r, hair_shadow_strength * face_mask);

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
	surface_ao = clamp(mix(1.0, color_mask.r, 0.12 * face_mask), 0.15, 1.0);
	AO = surface_ao;
	AO_LIGHT_AFFECT = 0.0;
	METALLIC = 0.0;
	ROUGHNESS = mix(skin_roughness, 0.28, lip_mask);
	SPECULAR = 0.0;
	EMISSION = lip_emission_color.rgb * lip_highlight * lip_emission_strength;
}


void light() {
	vec3 normal = normalize(NORMAL);
	vec3 spec_normal = normalize(spec_normal_view);
	vec3 light_direction = normalize(LIGHT);
	vec3 view_direction = normalize(VIEW);
	vec3 light_ws = normalize((INV_VIEW_MATRIX * vec4(light_direction, 0.0)).xyz);

	float half_lambert = clamp(dot(normal, light_direction) * 0.5 + 0.5, 0.0, 1.0);
	float sdf_lit = face_sdf_lit(light_ws, UV);
	float shading = LIGHT_IS_DIRECTIONAL
		? mix(half_lambert, sdf_lit, face_mask * sdf_strength)
		: half_lambert;
	float detail_lit = smoothstep(0.34, 0.66, half_lambert);
	shading *= mix(1.0, mix(0.72, 1.0, detail_lit), face_detail_shadow_strength * face_mask);
	shading *= hair_shadow;

	vec4 ramp = sample_diff_ramp(rd_texture, shading);
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
	spec_color = mix(spec_color, vec3(0.18, 0.08, 0.08), lip_mask);
	float ggx_term = stylized_ggx(spec_normal, view_direction, light_direction, ROUGHNESS);
	float specular_occlusion = min(surface_ao, shadow_weight);
	float lip_spec = lip_highlight * 6.0 + lip_mask * 0.35;
	SPECULAR_LIGHT += spec_color * (ggx_term + lip_spec)
		* LIGHT_COLOR * light_attenuation * specular_occlusion
		* SPECULAR_AMOUNT * specular_strength / PI;

	SPECULAR_LIGHT += wrap_subsurface(
		normal, view_direction, light_direction, ALBEDO, specular_occlusion * face_mask
	) * LIGHT_COLOR * light_attenuation / PI;

	float fresnel = pow(clamp(1.0 - max(dot(normal, view_direction), 0.0), 0.0, 1.0), rim_power);
	float rim = fresnel * mix(0.25, 1.0, rim_mask) * rim_strength * face_mask;
	float rim_light = smoothstep(-0.35, 0.65, dot(normal, light_direction));
	SPECULAR_LIGHT += rim_color.rgb * rim * mix(0.3, 1.0, rim_light)
		* LIGHT_COLOR * light_attenuation * specular_occlusion / PI;

	if (matcap_strength > 0.0 && LIGHT_IS_DIRECTIONAL) {
		vec2 matcap_uv = spec_normal.xy * 0.5 + 0.5;
		vec3 matcap = texture(matcap_texture, clamp(matcap_uv, vec2(0.02), vec2(0.98))).rgb;
		SPECULAR_LIGHT += matcap * matcap_strength * (0.25 + 0.75 * lip_mask)
			* LIGHT_COLOR * light_attenuation * specular_occlusion / PI;
	}
}
