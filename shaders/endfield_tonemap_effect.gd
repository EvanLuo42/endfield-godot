@tool
class_name EndfieldTonemapEffect
extends CompositorEffect

const TONEMAP_SHADER: RDShaderFile = preload("res://shaders/endfield_tonemap.glsl")

var _parameter_mutex := Mutex.new()
var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _lut_sampler := RID()
var _dummy_lut: ImageTexture
var _frame_index := 0
var _reported_shader_error := false

@export_category("Endfield Tonemap")
@export_range(-8.0, 8.0, 0.05) var exposure_ev := 0.0
@export_range(0.5, 2.0, 0.01) var contrast := 1.05
@export_range(0.0, 2.0, 0.01) var saturation := 1.02
@export_range(0.0, 1.0, 0.01) var toe_strength := 0.12
@export_range(1.0, 16.0, 0.1) var white_point := 4.0

@export_category("LogC LUT (Optional)")
@export var color_lut: Texture2D
@export_range(0.0, 1.0, 0.01) var lut_strength := 1.0

@export_category("Output")
@export_range(0.0, 2.0, 0.05) var dither_strength := 0.65


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	_rd = RenderingServer.get_rendering_device()
	_dummy_lut = _create_dummy_lut()


func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or not _rd:
		return
	if _shader.is_valid():
		_rd.free_rid(_shader)
		_shader = RID()
		_pipeline = RID()
	if _lut_sampler.is_valid():
		_rd.free_rid(_lut_sampler)
		_lut_sampler = RID()


func _create_dummy_lut() -> ImageTexture:
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _ensure_pipeline() -> bool:
	if not _rd:
		return false
	if _pipeline.is_valid():
		return true

	var spirv := TONEMAP_SHADER.get_spirv()
	if not spirv or not spirv.compile_error_compute.is_empty():
		if not _reported_shader_error:
			push_error("Endfield tonemap compute shader failed to compile: %s" % spirv.compile_error_compute)
			_reported_shader_error = true
		return false

	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		return false
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		return false

	var sampler_state := RDSamplerState.new()
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	_lut_sampler = _rd.sampler_create(sampler_state)
	return _lut_sampler.is_valid()


func _render_callback(callback_type: int, render_data: RenderData) -> void:
	if callback_type != EFFECT_CALLBACK_TYPE_POST_TRANSPARENT or not _ensure_pipeline():
		return

	var render_scene_buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	if not render_scene_buffers:
		return
	var size := render_scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return

	_parameter_mutex.lock()
	var frame_exposure := exposure_ev
	var frame_contrast := contrast
	var frame_saturation := saturation
	var frame_toe := toe_strength
	var frame_white := white_point
	var frame_lut := color_lut
	var frame_lut_strength := lut_strength
	var frame_dither := dither_strength
	_parameter_mutex.unlock()

	var lut_texture := frame_lut if frame_lut else _dummy_lut
	var lut_size := 0.0
	if frame_lut and frame_lut.get_height() >= 2 and frame_lut.get_width() == frame_lut.get_height() * frame_lut.get_height():
		lut_size = float(frame_lut.get_height())
	else:
		frame_lut_strength = 0.0

	var lut_rd_rid := RenderingServer.texture_get_rd_texture(lut_texture.get_rid())
	if not lut_rd_rid.is_valid():
		return

	var push_constant := PackedFloat32Array([
		float(size.x), float(size.y), frame_exposure, frame_contrast,
		frame_saturation, frame_toe, frame_white, frame_lut_strength,
		lut_size, frame_dither, float(_frame_index % 64), 0.0,
	])
	_frame_index += 1

	var groups_x := ceili(float(size.x) / 8.0)
	var groups_y := ceili(float(size.y) / 8.0)
	var view_count := render_scene_buffers.get_view_count()
	for view in range(view_count):
		var color_uniform := RDUniform.new()
		color_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
		color_uniform.binding = 0
		color_uniform.add_id(render_scene_buffers.get_color_layer(view))

		var lut_uniform := RDUniform.new()
		lut_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		lut_uniform.binding = 1
		lut_uniform.add_id(_lut_sampler)
		lut_uniform.add_id(lut_rd_rid)

		var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [color_uniform, lut_uniform])
		var compute_list := _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
		_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
		_rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
		_rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
		_rd.compute_list_end()
