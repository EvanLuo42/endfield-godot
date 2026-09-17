shader_type spatial;

// Inverted hull. Expands along the mesh's smooth vertex normals in view
// space, then culls front faces so only the silhouette rim remains.
render_mode unshaded, cull_front, shadows_disabled, ambient_light_disabled,
		fog_disabled, specular_disabled, depth_draw_opaque;

group_uniforms Outline;
uniform vec4 outline_color : source_color = vec4(0.035, 0.02, 0.028, 1.0);
// Screen-space thickness in pixels at the current view depth.
uniform float outline_width : hint_range(0.0, 8.0, 0.05) = 1.8;
// Keep some view-normal Z so the hull has volume; lower = flatter, fewer inner lines.
uniform float normal_z_keep : hint_range(0.0, 1.0, 0.01) = 0.35;
// Clip-space push away from the camera, in NDC-like units * w.
uniform float z_bias : hint_range(0.0, 0.02, 0.0001) = 0.0015;

group_uniforms Clip;
uniform sampler2D clip_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_alpha_clip = false;
uniform float alpha_scissor : hint_range(0.0, 1.0, 0.01) = 0.35;


void vertex() {
	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 view_n = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	view_n.z *= normal_z_keep;
	float n_len = length(view_n);
	view_n = n_len > 1e-5 ? view_n / n_len : vec3(0.0, 0.0, 1.0);

	float view_per_pixel = (2.0 * abs(view_pos.z))
			/ max(PROJECTION_MATRIX[1][1], 1e-5)
			/ max(VIEWPORT_SIZE.y, 1.0);
	view_pos.xyz += view_n * outline_width * view_per_pixel;

	POSITION = PROJECTION_MATRIX * view_pos;
	// Reverse-Z (Forward+): smaller z is farther. OpenGL: larger z is farther.
	float farther = CLIP_SPACE_FAR == 0.0 ? -1.0 : 1.0;
	POSITION.z += farther * z_bias * POSITION.w;
}


void fragment() {
	if (use_alpha_clip) {
		float clip_a = texture(clip_texture, UV).a;
		if (clip_a < alpha_scissor) {
			discard;
		}
	}
	ALBEDO = outline_color.rgb;
}
