@tool
class_name ToonOutlineEffect
extends CompositorEffect

var _parameter_mutex := Mutex.new()
var _rd: RenderingDevice
var _shader_file: RDShaderFile
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _reported_shader_error := false

@export_category("Outline")
@export var outline_color := Color(0.035, 0.02, 0.028, 1.0)
@export_range(0.0, 1.0, 0.01) var strength := 0.72
@export_range(1.0, 3.0, 1.0) var edge_width := 1.0

@export_category("Detection")
@export_range(0.0, 1.0, 0.005) var depth_threshold := 0.035
@export_range(0.0, 1.0, 0.005) var normal_threshold := 0.34
@export_range(0.0, 2.0, 0.01) var depth_weight := 1.0
@export_range(0.0, 2.0, 0.01) var normal_weight := 0.7
@export_range(0.1, 20.0, 0.1) var fade_start := 3.5
@export_range(0.1, 40.0, 0.1) var fade_end := 10.0
@export_range(0.1, 4.0, 0.05) var inner_near := 0.4
@export_range(0.1, 4.0, 0.05) var inner_far := 0.9


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
	needs_normal_roughness = true
	_rd = RenderingServer.get_rendering_device()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or not _rd:
		return
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()
		_pipeline = RID()
	if _sampler.is_valid():
		_rd.free_rid(_sampler)
		_sampler = RID()


func _ensure_pipeline() -> bool:
	if not _rd:
		return false
	if _pipeline.is_valid():
		return true

	if _shader_file == null:
		_shader_file = load("res://shaders/toon_outline.glsl") as RDShaderFile
	if _shader_file == null:
		if not _reported_shader_error:
			push_error("Toon outline compute shader missing: res://shaders/toon_outline.glsl")
			_reported_shader_error = true
		return false

	var spirv := _shader_file.get_spirv()
	if not spirv or not spirv.compile_error_compute.is_empty():
		if not _reported_shader_error:
			var compile_error := ""
			if spirv:
				compile_error = spirv.compile_error_compute
			push_error("Toon outline compute shader failed to compile: %s" % compile_error)
			_reported_shader_error = true
		return false

	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		return false

	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	return _sampler.is_valid()


func _projection_to_floats(projection: Projection) -> PackedFloat32Array:
	return PackedFloat32Array([
		projection.x.x, projection.x.y, projection.x.z, projection.x.w,
		projection.y.x, projection.y.y, projection.y.z, projection.y.w,
		projection.z.x, projection.z.y, projection.z.z, projection.z.w,
		projection.w.x, projection.w.y, projection.w.z, projection.w.w,
	])


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or not _ensure_pipeline():
		return

	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not render_scene_buffers:
		return
	if not render_scene_buffers.has_texture("forward_clustered", "normal_roughness"):
		return

	var size := render_scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	var scene_data := render_data.get_render_scene_data()
	if scene_data == null:
		return

	_parameter_mutex.lock()
	var frame_color := outline_color
	var frame_strength := strength
	var frame_width := edge_width
	var frame_depth_threshold := depth_threshold
	var frame_normal_threshold := normal_threshold
	var frame_depth_weight := depth_weight
	var frame_normal_weight := normal_weight
	var frame_fade_start := fade_start
	var frame_fade_end := fade_end
	var frame_inner_near := inner_near
	var frame_inner_far := inner_far
	_parameter_mutex.unlock()

	var groups_x := ceili(float(size.x) / 8.0)
	var groups_y := ceili(float(size.y) / 8.0)
	var view_count := render_scene_buffers.get_view_count()
	for view in range(view_count):
		var inv_projection := scene_data.get_view_projection(view).inverse()
		var push_constant := _projection_to_floats(inv_projection)
		push_constant.append_array(PackedFloat32Array([
			float(size.x), float(size.y), frame_width, frame_depth_threshold,
			frame_normal_threshold, frame_depth_weight, frame_normal_weight, frame_strength,
			frame_color.r, frame_color.g, frame_color.b, frame_color.a,
			frame_fade_start, frame_fade_end, frame_inner_near, frame_inner_far,
		]))

		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(render_scene_buffers.get_color_layer(view))

		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 1
		depth_uniform.add_id(_sampler)
		depth_uniform.add_id(render_scene_buffers.get_depth_layer(view))

		var normal_uniform := RDUniform.new()
		normal_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		normal_uniform.binding = 2
		normal_uniform.add_id(_sampler)
		normal_uniform.add_id(render_scene_buffers.get_texture_slice(
			"forward_clustered", "normal_roughness", view, 0, 1, 1
		))

		var uniform_set := UniformSetCacheRD.get_cache(
			_shader, 0, [color_uniform, depth_uniform, normal_uniform]
		)
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(
			compute_list, push_constant.to_byte_array(), push_constant.size() * 4
		)
		_rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
		_rd.compute_list_end()
