@tool
class_name EndfieldDepthRimEffect
extends CompositorEffect

const RIM_SHADER: RDShaderFile = preload("res://shaders/endfield_depth_rim.glsl")

var _parameter_mutex := Mutex.new()
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _reported_shader_error := false

@export_category("Depth Rim")
@export var rim_color := Color(0.5, 0.68, 1.0, 1.0)
@export_range(0.0, 1.0, 0.01) var rim_strength := 0.2
@export_range(1.0, 4.0, 1.0) var rim_width := 2.0
@export_range(0.001, 0.25, 0.001) var depth_threshold := 0.018
@export_range(0.0, 1.0, 0.01) var directional_weight := 0.78
@export_range(0.1, 10.0, 0.1) var max_depth := 2.5
@export_range(0.1, 10.0, 0.1) var fade_start := 1.4
@export_range(0.1, 15.0, 0.1) var fade_end := 2.5
@export var rim_light_view := Vector3(-0.45, -0.35, 0.82)


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
	var spirv := RIM_SHADER.get_spirv()
	if not spirv or not spirv.compile_error_compute.is_empty():
		if not _reported_shader_error:
			push_error("Depth rim compute shader failed to compile: %s" % spirv.compile_error_compute)
			_reported_shader_error = true
		return false
	_shader = _rd.shader_create_from_spirv(spirv)
	_pipeline = _rd.compute_pipeline_create(_shader)
	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_NEAREST
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_sampler = _rd.sampler_create(sampler_state)
	return _pipeline.is_valid() and _sampler.is_valid()


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
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not buffers or not buffers.has_texture("forward_clustered", "normal_roughness"):
		return
	var size := buffers.get_internal_size()
	var scene_data := render_data.get_render_scene_data()
	if size.x <= 0 or size.y <= 0 or not scene_data:
		return

	_parameter_mutex.lock()
	var frame_color := rim_color
	var frame_strength := rim_strength
	var frame_width := rim_width
	var frame_threshold := depth_threshold
	var frame_directional := directional_weight
	var frame_max_depth := max_depth
	var frame_fade_start := fade_start
	var frame_fade_end := fade_end
	var frame_light := rim_light_view.normalized()
	_parameter_mutex.unlock()

	for view in range(buffers.get_view_count()):
		var push := _projection_to_floats(scene_data.get_view_projection(view).inverse())
		push.append_array(PackedFloat32Array([
			float(size.x), float(size.y), frame_width, frame_strength,
			frame_color.r, frame_color.g, frame_color.b, frame_color.a,
			frame_light.x, frame_light.y, frame_light.z, frame_max_depth,
			frame_threshold, frame_fade_start, frame_fade_end, frame_directional,
		]))

		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(buffers.get_color_layer(view))
		var depth_uniform := RDUniform.new()
		depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		depth_uniform.binding = 1
		depth_uniform.add_id(_sampler)
		depth_uniform.add_id(buffers.get_depth_layer(view))
		var normal_uniform := RDUniform.new()
		normal_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		normal_uniform.binding = 2
		normal_uniform.add_id(_sampler)
		normal_uniform.add_id(buffers.get_texture_slice(
			"forward_clustered", "normal_roughness", view, 0, 1, 1
		))

		var uniform_set := UniformSetCacheRD.get_cache(
			_shader, 0, [color_uniform, depth_uniform, normal_uniform]
		)
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push.to_byte_array(), push.size() * 4)
		_rd.compute_list_dispatch(
			compute_list, ceili(float(size.x) / 8.0), ceili(float(size.y) / 8.0), 1
		)
		_rd.compute_list_end()
