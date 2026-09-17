shader_type spatial;

// Bangs projection. Endfield duplicates the front hair, offsets it along the
// light, and multiply-blends onto the face. This pass runs on 面-7 (the real
// hair), not the 面-8 proxy card.
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, shadows_disabled;

group_uniforms Textures;
uniform sampler2D base_color_texture : source_color, filter_linear_mipmap_anisotropic, repeat_disable;

group_uniforms Surface;
uniform vec4 shadow_color : source_color = vec4(0.38, 0.22, 0.22, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.45;
uniform float alpha_scissor : hint_range(0.0, 1.0, 0.01) = 0.35;

group_uniforms Projection;
// Scene DirectionalLight -Z, matching scene.tscn.
uniform vec3 light_dir_ws = vec3(-0.743, -0.491, -0.455);
uniform float offset_xy : hint_range(0.0, 0.08, 0.0005) = 0.01;
uniform float offset_z : hint_range(0.0, 0.08, 0.0005) = 0.006;

void vertex() {
	vec3 light_view = normalize((VIEW_MATRIX * vec4(normalize(light_dir_ws), 0.0)).xyz);
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	view_pos.xy += -light_view.xy * offset_xy;
	view_pos.z -= offset_z;
	POSITION = PROJECTION_MATRIX * view_pos;
}

void fragment() {
	float hair_a = texture(base_color_texture, UV).a;
	if (hair_a < alpha_scissor) {
		discard;
	}
	float n_dot_v = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float facing = smoothstep(0.05, 0.35, n_dot_v);
	float amount = shadow_strength * facing * hair_a;
	ALBEDO = mix(vec3(1.0), shadow_color.rgb, amount);
	ALPHA = 1.0;
}
