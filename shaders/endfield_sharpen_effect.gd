@tool
class_name EndfieldSharpenEffect
extends CompositorEffect

const SHARPEN_SHADER: RDShaderFile = preload("res://shaders/endfield_sharpen.glsl")
const CONTEXT := &"EndfieldSharpen"
const BUFFER := &"color"

var _parameter_mutex := Mutex.new()
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _buffer_size := Vector2i.ZERO
var _buffer_views := 0
var _reported_shader_error := false

@export_category("Post-TAA Sharpen")
@export_range(0.0, 1.0, 0.01) var strength := 0.24
@export_range(0.0, 1.0, 0.01) var clamp_strength := 0.18
@export_range(0.5, 8.0, 0.1) var highlight_suppression := 1.6


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
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
	var spirv := SHARPEN_SHADER.get_spirv()
	if not spirv or not spirv.compile_error_compute.is_empty():
		if not _reported_shader_error:
			push_error("Sharpen compute shader failed to compile: %s" % spirv.compile_error_compute)
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


func _ensure_buffer(buffers: RenderSceneBuffersRD, size: Vector2i, views: int) -> bool:
	if size == _buffer_size and views == _buffer_views and buffers.has_texture(CONTEXT, BUFFER):
		return true
	if buffers.has_texture(CONTEXT, BUFFER):
		buffers.clear_context(CONTEXT)
	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	buffers.create_texture(
		CONTEXT, BUFFER, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
		usage, RenderingDevice.TEXTURE_SAMPLES_1, size, views, 1, true, false
	)
	_buffer_size = size
	_buffer_views = views
	return buffers.has_texture(CONTEXT, BUFFER)


func _uniform_set(source: RID, destination: RID) -> RID:
	var source_uniform := RDUniform.new()
	source_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	source_uniform.binding = 0
	source_uniform.add_id(_sampler)
	source_uniform.add_id(source)
	var destination_uniform := RDUniform.new()
	destination_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	destination_uniform.binding = 1
	destination_uniform.add_id(destination)
	return UniformSetCacheRD.get_cache(_shader, 0, [source_uniform, destination_uniform])


func _dispatch(list: int, uniforms: RID, push: PackedFloat32Array, size: Vector2i) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniforms, 0)
	_rd.compute_list_set_push_constant(list, push.to_byte_array(), push.size() * 4)
	_rd.compute_list_dispatch(list, ceili(float(size.x) / 8.0), ceili(float(size.y) / 8.0), 1)


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or strength <= 0.0001 or not _ensure_pipeline():
		return
	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not buffers:
		return
	var size := buffers.get_internal_size()
	var views := buffers.get_view_count()
	if size.x <= 0 or size.y <= 0 or not _ensure_buffer(buffers, size, views):
		return

	_parameter_mutex.lock()
	var frame_strength := strength
	var frame_clamp := clamp_strength
	var frame_highlight := highlight_suppression
	_parameter_mutex.unlock()
	for view in range(views):
		var color := buffers.get_color_layer(view)
		var temporary := buffers.get_texture_slice(CONTEXT, BUFFER, view, 0, 1, 1)
		var list := _rd.compute_list_begin()
		var sharpen_push := PackedFloat32Array([
			float(size.x), float(size.y), 0.0, frame_strength,
			frame_clamp, frame_highlight, 0.0, 0.0,
		])
		_dispatch(list, _uniform_set(color, temporary), sharpen_push, size)
		_rd.compute_list_add_barrier(list)
		var copy_push := PackedFloat32Array([
			float(size.x), float(size.y), 1.0, frame_strength,
			frame_clamp, frame_highlight, 0.0, 0.0,
		])
		_dispatch(list, _uniform_set(temporary, color), copy_push, size)
		_rd.compute_list_end()
