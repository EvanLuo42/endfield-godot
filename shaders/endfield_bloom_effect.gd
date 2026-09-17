@tool
class_name EndfieldBloomEffect
extends CompositorEffect

const CONTEXT := &"EndfieldBloom"
const LEVEL_NAMES: Array[StringName] = [&"mip0", &"mip1", &"mip2", &"mip3", &"mip4"]
const LEVEL_COUNT := 5
const MODE_PREFILTER := 0.0
const MODE_DOWNSAMPLE := 1.0
const MODE_UPSAMPLE := 2.0
const MODE_COMPOSITE := 3.0

var _parameter_mutex := Mutex.new()
var _rd: RenderingDevice
var _shader_file: RDShaderFile
var _shader := RID()
var _pipeline := RID()
var _sampler := RID()
var _reported_shader_error := false
var _buffer_size := Vector2i.ZERO
var _buffer_views := 0

@export_category("Bloom")
@export_range(0.0, 4.0, 0.01) var threshold := 1.0
@export_range(0.0, 1.0, 0.01) var knee := 0.5
@export_range(0.0, 2.0, 0.01) var intensity := 0.32
@export_range(0.0, 1.0, 0.01) var anamorphic_ratio := 0.28
@export_range(0.5, 1.5, 0.01) var bloom_scatter := 0.92

@export_category("Vignette")
@export_range(0.0, 1.0, 0.01) var vignette_strength := 0.42
@export_range(0.5, 2.5, 0.01) var vignette_intensity := 1.05
@export_range(0.2, 4.0, 0.01) var vignette_power := 1.6
@export_range(0.2, 4.0, 0.01) var vignette_roundness := 1.35
@export var vignette_color := Color(0.03, 0.02, 0.028, 1.0)


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	access_resolved_color = true
	access_resolved_depth = true
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
		_shader_file = load("res://shaders/endfield_bloom.glsl") as RDShaderFile
	if _shader_file == null:
		if not _reported_shader_error:
			push_error("Endfield bloom compute shader missing: res://shaders/endfield_bloom.glsl")
			_reported_shader_error = true
		return false

	var spirv := _shader_file.get_spirv()
	if not spirv or not spirv.compile_error_compute.is_empty():
		if not _reported_shader_error:
			var compile_error := ""
			if spirv:
				compile_error = spirv.compile_error_compute
			push_error("Endfield bloom compute shader failed to compile: %s" % compile_error)
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
	_sampler = _rd.sampler_create(sampler_state)
	return _sampler.is_valid()


func _mip_size(base: Vector2i, level: int) -> Vector2i:
	var shift := level + 1
	return Vector2i(maxi(base.x >> shift, 1), maxi(base.y >> shift, 1))


func _ensure_textures(render_scene_buffers: RenderSceneBuffersRD, size: Vector2i, view_count: int) -> bool:
	if size == _buffer_size and view_count == _buffer_views and render_scene_buffers.has_texture(CONTEXT, LEVEL_NAMES[0]):
		return true

	if render_scene_buffers.has_texture(CONTEXT, LEVEL_NAMES[0]):
		render_scene_buffers.clear_context(CONTEXT)

	var usage := RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	for level in range(LEVEL_COUNT):
		render_scene_buffers.create_texture(
			CONTEXT,
			LEVEL_NAMES[level],
			RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
			usage,
			RenderingDevice.TEXTURE_SAMPLES_1,
			_mip_size(size, level),
			view_count,
			1,
			true,
			false
		)

	_buffer_size = size
	_buffer_views = view_count
	return render_scene_buffers.has_texture(CONTEXT, LEVEL_NAMES[0])


func _push_constants(
	src_size: Vector2i,
	dst_size: Vector2i,
	mode: float,
	threshold_value: float,
	knee_value: float,
	intensity_value: float,
	vignette: PackedFloat32Array
) -> PackedFloat32Array:
	return PackedFloat32Array([
		float(src_size.x), float(src_size.y), float(dst_size.x), float(dst_size.y),
		mode, threshold_value, knee_value, intensity_value,
		vignette[0], vignette[1], vignette[2], vignette[3],
		vignette[4], vignette[5], vignette[6], vignette[7],
		vignette[8], vignette[9], 0.0, 0.0,
	])


func _uniform_set(src_rid: RID, depth_rid: RID, dest_rid: RID) -> RID:
	var src_uniform := RDUniform.new()
	src_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	src_uniform.binding = 0
	src_uniform.add_id(_sampler)
	src_uniform.add_id(src_rid)

	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	depth_uniform.binding = 1
	depth_uniform.add_id(_sampler)
	depth_uniform.add_id(depth_rid)

	var dest_uniform := RDUniform.new()
	dest_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	dest_uniform.binding = 2
	dest_uniform.add_id(dest_rid)

	return UniformSetCacheRD.get_cache(_shader, 0, [src_uniform, depth_uniform, dest_uniform])


func _dispatch(
	compute_list: int,
	uniform_set: RID,
	push_constant: PackedFloat32Array,
	dst_size: Vector2i
) -> void:
	_rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)
	_rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	_rd.compute_list_set_push_constant(compute_list, push_constant.to_byte_array(), push_constant.size() * 4)
	_rd.compute_list_dispatch(
		compute_list,
		ceili(float(dst_size.x) / 8.0),
		ceili(float(dst_size.y) / 8.0),
		1
	)


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
	var frame_threshold := threshold
	var frame_knee := knee
	var frame_intensity := intensity
	var frame_vignette := PackedFloat32Array([
		vignette_strength, vignette_intensity, vignette_power, vignette_roundness,
		vignette_color.r, vignette_color.g, vignette_color.b, vignette_color.a,
		anamorphic_ratio, bloom_scatter,
	])
	_parameter_mutex.unlock()

	var bloom_enabled := frame_intensity > 0.0001
	var vignette_enabled := frame_vignette[0] > 0.0001
	if not bloom_enabled and not vignette_enabled:
		return

	var view_count := render_scene_buffers.get_view_count()
	if bloom_enabled and not _ensure_textures(render_scene_buffers, size, view_count):
		return

	for view in range(view_count):
		var color_rid := render_scene_buffers.get_color_layer(view)
		var depth_rid := render_scene_buffers.get_depth_layer(view)
		if not color_rid.is_valid() or not depth_rid.is_valid():
			continue

		var compute_list := _rd.compute_list_begin()
		if bloom_enabled:
			var mip_rids: Array[RID] = []
			var mip_sizes: Array[Vector2i] = []
			for level in range(LEVEL_COUNT):
				mip_rids.append(render_scene_buffers.get_texture_slice(
					CONTEXT, LEVEL_NAMES[level], view, 0, 1, 1
				))
				mip_sizes.append(_mip_size(size, level))

			_dispatch(
				compute_list,
				_uniform_set(color_rid, depth_rid, mip_rids[0]),
				_push_constants(size, mip_sizes[0], MODE_PREFILTER, frame_threshold, frame_knee, frame_intensity, frame_vignette),
				mip_sizes[0]
			)

			for level in range(LEVEL_COUNT - 1):
				_rd.compute_list_add_barrier(compute_list)
				_dispatch(
					compute_list,
					_uniform_set(mip_rids[level], depth_rid, mip_rids[level + 1]),
					_push_constants(mip_sizes[level], mip_sizes[level + 1], MODE_DOWNSAMPLE, frame_threshold, frame_knee, frame_intensity, frame_vignette),
					mip_sizes[level + 1]
				)

			for level in range(LEVEL_COUNT - 2, -1, -1):
				_rd.compute_list_add_barrier(compute_list)
				_dispatch(
					compute_list,
					_uniform_set(mip_rids[level + 1], depth_rid, mip_rids[level]),
					_push_constants(mip_sizes[level + 1], mip_sizes[level], MODE_UPSAMPLE, frame_threshold, frame_knee, frame_intensity, frame_vignette),
					mip_sizes[level]
				)

			_rd.compute_list_add_barrier(compute_list)
			_dispatch(
				compute_list,
				_uniform_set(mip_rids[0], depth_rid, color_rid),
				_push_constants(mip_sizes[0], size, MODE_COMPOSITE, frame_threshold, frame_knee, frame_intensity, frame_vignette),
				size
			)
		else:
			# Vignette-only: do not alias color as both sampler and storage image.
			_dispatch(
				compute_list,
				_uniform_set(depth_rid, depth_rid, color_rid),
				_push_constants(size, size, MODE_COMPOSITE, frame_threshold, frame_knee, 0.0, frame_vignette),
				size
			)
		_rd.compute_list_end()
