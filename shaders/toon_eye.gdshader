shader_type spatial;

// Endfield iris: UV parallax, concave sphere normal, matcap cornea, facing Z-offset.
// Reverse-engineered from Straw1997 眼睛流程图 + the character's iris_00_D / matcap.
render_mode depth_draw_opaque, cull_back, depth_prepass_alpha;

group_uniforms Textures;
uniform sampler2D iris_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D matcap_texture : source_color, filter_linear, repeat_disable;

group_uniforms Surface;
uniform vec4 iris_tint : source_color = vec4(1.0);
uniform float albedo_strength : hint_range(0.01, 4.0, 0.01) = 1.0;
uniform float bright_scale : hint_range(0.5, 3.0, 0.01) = 1.15;
uniform float alpha_scissor : hint_range(0.0, 1.0, 0.01) = 0.02;

group_uniforms Parallax;
// viewDirTS.xy * (1, 0.45) * irisMask. DistSq falloff is 0.25 → 0.05 in the dump.
uniform float parallax_strength : hint_range(0.0, 0.4, 0.001) = 0.08;
uniform vec2 parallax_aniso = vec2(1.0, 0.45);
uniform float iris_mask_inner : hint_range(0.0, 0.4, 0.001) = 0.05;
uniform float iris_mask_outer : hint_range(0.05, 0.8, 0.001) = 0.25;

group_uniforms SphereNormal;
// Invert XY so the reconstructed sphere is a concave iris cup.
uniform float bend_strength : hint_range(0.0, 2.0, 0.01) = 0.65;
uniform vec3 outside_normal_ts = vec3(-0.125, -0.125, 1.0);
uniform float flatten_outside : hint_range(0.0, 1.0, 0.01) = 1.0;

group_uniforms Matcap;
uniform float matcap_strength : hint_range(0.0, 3.0, 0.01) = 0.72;
uniform vec4 matcap_tint : source_color = vec4(1.0);
uniform float matcap_alpha_mix : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform float matcap_edge : hint_range(0.0, 0.08, 0.001) = 0.02;

group_uniforms ScatterRim;
uniform vec4 scatter_color : source_color = vec4(0.95, 0.55, 0.28, 1.0);
uniform float scatter_strength : hint_range(0.0, 2.0, 0.01) = 0.28;
uniform vec4 rim_color : source_color = vec4(1.0, 0.82, 0.62, 1.0);
uniform float rim_strength : hint_range(0.0, 3.0, 0.01) = 0.45;
uniform float rim_power : hint_range(0.5, 8.0, 0.1) = 2.4;
uniform float inner_rim_strength : hint_range(0.0, 2.0, 0.01) = 0.22;

group_uniforms Overlay;
// Clip-space depth bias only (no world push). Fade out with distance so the
// NDC offset does not swallow the whole head when the camera pulls back.
uniform float hair_punch_through : hint_range(0.0, 0.02, 0.0005) = 0.004;
uniform float overlay_near : hint_range(0.2, 8.0, 0.05) = 1.6;
uniform float overlay_far : hint_range(0.5, 20.0, 0.05) = 4.0;

group_uniforms Lighting;
uniform float diffuse_strength : hint_range(0.0, 2.0, 0.01) = 0.85;
uniform float specular_strength : hint_range(0.0, 4.0, 0.01) = 0.55;
uniform float cornea_roughness : hint_range(0.02, 1.0, 0.001) = 0.12;
uniform float cornea_f0 : hint_range(0.0, 0.16, 0.001) = 0.04;
uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.55;
uniform float shadow_floor : hint_range(0.0, 1.0, 0.01) = 0.62;


float iris_circle_mask(vec2 uv) {
	vec2 centered = fract(uv) - 0.5;
	float dist_sq = dot(centered, centered);
	return smoothstep(iris_mask_outer, iris_mask_inner, dist_sq);
}


vec3 reconstruct_sphere_ts(vec2 uv) {
	vec2 ndc = fract(uv) * 2.0 - 1.0;
	float r2 = clamp(dot(ndc, ndc), 0.0, 1.0);
	return vec3(ndc, sqrt(max(1.0 - r2, 0.0)));
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
	float iris_mask = iris_circle_mask(UV);

	vec3 view_ts = vec3(
		dot(TANGENT, VIEW),
		dot(BINORMAL, VIEW),
		dot(NORMAL, VIEW)
	);
	float view_len = length(view_ts);
	view_ts = view_len > 1e-5 ? view_ts / view_len : vec3(0.0, 0.0, 1.0);
	vec2 parallax_uv = UV - view_ts.xy * parallax_aniso * parallax_strength * iris_mask;

	vec4 iris_sample = texture(iris_texture, parallax_uv) * iris_tint;
	float alpha = iris_sample.a * mix(iris_mask, 1.0, 0.25);

	vec3 sphere_ts = reconstruct_sphere_ts(UV);
	vec3 bent_ts = vec3(sphere_ts.xy * (-bend_strength), max(sphere_ts.z, 1e-3));
	vec3 outside_ts = mix(vec3(0.0, 0.0, 1.0), outside_normal_ts, flatten_outside);
	vec3 n_ts = mix(normalize(bent_ts), normalize(outside_ts), 1.0 - iris_mask);
	vec3 bent_vs = normalize(TANGENT * n_ts.x + BINORMAL * n_ts.y + NORMAL * n_ts.z);
	NORMAL = bent_vs;

	vec2 matcap_uv = bent_vs.xy * (0.5 - matcap_edge) + 0.5;
	matcap_uv = clamp(matcap_uv, vec2(matcap_edge), vec2(1.0 - matcap_edge));
	vec4 matcap_sample = texture(matcap_texture, matcap_uv);
	vec3 matcap_contrib = matcap_sample.rgb * matcap_tint.rgb
		+ matcap_tint.rgb * matcap_sample.a * matcap_alpha_mix;

	vec3 albedo = pow(clamp(iris_sample.rgb, vec3(0.0), vec3(1.0)), vec3(albedo_strength));
	float luma = dot(albedo, vec3(0.2126, 0.7152, 0.0722));
	albedo = mix(vec3(luma), albedo, 1.05) * bright_scale;

	ALBEDO = albedo;
	EMISSION = matcap_contrib * matcap_strength * (0.35 + 0.65 * iris_mask);
	ROUGHNESS = mix(0.35, cornea_roughness, iris_mask);
	METALLIC = 0.0;
	SPECULAR = 0.0;
	ALPHA = alpha;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor;
}


void light() {
	vec3 normal = normalize(NORMAL);
	vec3 light_direction = normalize(LIGHT);
	vec3 view_direction = normalize(VIEW);

	float half_lambert = clamp(dot(normal, light_direction) * 0.5 + 0.5, 0.0, 1.0);
	float scene_shadow = LIGHT_IS_DIRECTIONAL ? clamp(ATTENUATION, 0.0, 1.0) : 1.0;
	float shadow_weight = mix(1.0, scene_shadow, shadow_strength);
	float light_attenuation = LIGHT_IS_DIRECTIONAL
		? mix(shadow_floor, 1.0, shadow_weight)
		: ATTENUATION;

	vec3 diffuse_brdf = ALBEDO * half_lambert * diffuse_strength / PI;
	DIFFUSE_LIGHT += diffuse_brdf * LIGHT_COLOR * light_attenuation;

	float ggx_term = stylized_ggx(normal, view_direction, light_direction, ROUGHNESS);
	SPECULAR_LIGHT += vec3(cornea_f0) * ggx_term
		* LIGHT_COLOR * light_attenuation * shadow_weight
		* SPECULAR_AMOUNT * specular_strength / PI;

	float n_dot_v = clamp(dot(normal, view_direction), 0.0, 1.0);
	float fresnel = pow(clamp(1.0 - n_dot_v, 0.0, 1.0), rim_power);
	float rim_mask = smoothstep(0.6, 0.8, 1.0 - n_dot_v);
	float rim_light = clamp(dot(light_direction, vec3(-normal.x, 0.0, -normal.z)), 0.0, 1.0);
	float wrap = clamp(0.5 + rim_light - 0.5 * rim_light * rim_light, 0.0, 1.0);
	float mask = iris_circle_mask(UV);
	SPECULAR_LIGHT += rim_color.rgb * fresnel * rim_mask * rim_strength
		* (0.35 + 0.65 * rim_light) * LIGHT_COLOR * light_attenuation / PI;
	SPECULAR_LIGHT += ALBEDO * mask * inner_rim_strength * fresnel
		* LIGHT_COLOR * light_attenuation / PI;
	SPECULAR_LIGHT += scatter_color.rgb * wrap * scatter_strength * mask
		* LIGHT_COLOR * light_attenuation / PI;
}
