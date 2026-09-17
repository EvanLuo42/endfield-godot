shader_type spatial;

// Endfield PC outline: extra inverted-hull pass, not screen-space Sobel.
// Previous hull filled the viewport because VIEWPORT_SIZE is 0/1 in shadow
// and some editor passes, so a "pixel" became the whole frustum.
// This version inflates in clip XY (Genshin/Endfield style), ignores ortho
// cameras, and clamps both the viewport used for pixel size and the NDC offset.
render_mode unshaded, cull_front, shadows_disabled, ambient_light_disabled,
		fog_disabled, specular_disabled, depth_draw_opaque;

group_uniforms Outline;
uniform vec4 outline_color : source_color = vec4(0.035, 0.02, 0.028, 1.0);
// Screen-space thickness in pixels at the current view.
uniform float outline_width : hint_range(0.0, 6.0, 0.05) = 1.6;
// Flatten view-normal Z so the shell is a silhouette, not inner creases.
uniform float normal_z_keep : hint_range(0.0, 1.0, 0.01) = 0.35;
// Clip-space push away from the camera, in NDC units * w.
uniform float z_bias : hint_range(0.0, 0.02, 0.0001) = 0.0015;
// Hard cap so a bad viewport can never cover the screen.
uniform float max_ndc_offset : hint_range(0.001, 0.08, 0.001) = 0.012;
// The importer stores averaged object-space normals in vertex color RGB.
uniform bool use_baked_smooth_normals = true;

group_uniforms Clip;
uniform sampler2D clip_texture : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_alpha_clip = false;
uniform float alpha_scissor : hint_range(0.0, 1.0, 0.01) = 0.35;

group_uniforms WidthMask;
uniform sampler2D width_mask_texture : filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_width_mask = false;
// 0=R 1=G 2=B 3=A. Cloth ST stores hide-islands in R (green blocks = 0).
uniform int width_mask_channel : hint_range(0, 3, 1) = 0;
uniform bool invert_width_mask = false;

varying float skip_outline;
varying float width_scale;


float mask_channel(vec4 value, int channel) {
	if (channel <= 0) {
		return value.r;
	}
	if (channel == 1) {
		return value.g;
	}
	if (channel == 2) {
		return value.b;
	}
	return value.a;
}


void vertex() {
	// Ortho = shadow cascades / probes. Backface-only unexpanded geometry
	// would paint the character black, so skip those cameras entirely.
	bool is_ortho = PROJECTION_MATRIX[3][3] > 0.5;
	skip_outline = is_ortho ? 1.0 : 0.0;

	width_scale = 1.0;
	if (use_width_mask) {
		float mask = mask_channel(texture(width_mask_texture, UV), width_mask_channel);
		if (invert_width_mask) {
			mask = 1.0 - mask;
		}
		width_scale = clamp(mask, 0.0, 1.0);
	}

	vec4 view_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec3 baked_normal = COLOR.rgb * 2.0 - 1.0;
	bool baked_normal_valid = dot(baked_normal, baked_normal) > 0.25;
	vec3 outline_normal = use_baked_smooth_normals && baked_normal_valid
		? normalize(baked_normal)
		: NORMAL;
	vec3 view_n = normalize(MODELVIEW_NORMAL_MATRIX * outline_normal);
	view_n.z *= normal_z_keep;
	float n_len = length(view_n);
	view_n = n_len > 1e-5 ? view_n / n_len : vec3(0.0, 0.0, -1.0);

	vec4 clip = PROJECTION_MATRIX * view_pos;
	if (!is_ortho && outline_width > 0.0 && width_scale > 0.001) {
		vec2 viewport = max(VIEWPORT_SIZE, vec2(64.0));
		vec2 n_xy = view_n.xy;
		float xy_len = length(n_xy);
		vec2 n_dir = xy_len > 1e-5 ? n_xy / xy_len : vec2(0.0);
		vec2 n_pixel = n_dir * viewport;
		float n_pixel_len = length(n_pixel);
		n_pixel = n_pixel_len > 1e-5 ? n_pixel / n_pixel_len : vec2(0.0);
		vec2 pixel_ndc = vec2(2.0) / viewport;
		float width_px = outline_width * width_scale;
		vec2 ndc_offset = n_pixel * width_px * pixel_ndc;
		float ndc_len = length(ndc_offset);
		if (ndc_len > max_ndc_offset && ndc_len > 1e-8) {
			ndc_offset *= max_ndc_offset / ndc_len;
		}
		clip.xy += ndc_offset * clip.w;
	}

	POSITION = clip;
	float farther = CLIP_SPACE_FAR == 0.0 ? -1.0 : 1.0;
	POSITION.z += farther * z_bias * POSITION.w;
}


void fragment() {
	if (skip_outline > 0.5 || width_scale < 0.001) {
		discard;
	}
	if (use_alpha_clip) {
		float clip_a = texture(clip_texture, UV).a;
		if (clip_a < alpha_scissor) {
			discard;
		}
	}
	ALBEDO = outline_color.rgb;
}
