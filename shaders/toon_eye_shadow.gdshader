shader_type spatial;

// Eyelid contact overlay (面-4). FBX albedo is black with no map; the
// authored falloff is T_actor_common_eyeshadow_01_M, a vertical 1D ramp
// in R (G/B stay 1). UV.y on this mesh is high at the lid, low toward the iris.
render_mode unshaded, blend_mul, depth_draw_never, cull_disabled, shadows_disabled;

group_uniforms Textures;
uniform sampler2D shadow_ramp : filter_linear, repeat_disable;

group_uniforms Surface;
uniform vec4 shadow_color : source_color = vec4(0.28, 0.12, 0.14, 1.0);
uniform float shadow_strength : hint_range(0.0, 1.0, 0.01) = 0.7;
uniform bool invert_v = true;
uniform float facing_gate : hint_range(0.0, 0.5, 0.01) = 0.08;

group_uniforms Overlay;
uniform float hair_punch_through : hint_range(0.0, 0.02, 0.0005) = 0.004;
uniform float overlay_near : hint_range(0.2, 8.0, 0.05) = 1.6;
uniform float overlay_far : hint_range(0.5, 20.0, 0.05) = 4.0;

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
	float v = invert_v ? 1.0 - UV.y : UV.y;
	float lightness = texture(shadow_ramp, vec2(0.5, clamp(v, 0.0, 1.0))).r;
	float n_dot_v = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float facing = smoothstep(0.0, facing_gate, n_dot_v);
	float amount = clamp((1.0 - lightness) * shadow_strength * facing, 0.0, 1.0);
	ALBEDO = mix(vec3(1.0), shadow_color.rgb, amount);
	ALPHA = 1.0;
}
