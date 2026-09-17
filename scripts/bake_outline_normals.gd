@tool
extends EditorScenePostImport

## Bakes averaged object-space normals into vertex color RGB for the inverted
## hull outline. Averaging by position removes UV/material seam spikes while a
## cancellation guard preserves thin, opposing surfaces.
const POSITION_QUANTIZATION := 100000.0


func _post_import(scene: Node) -> Object:
	_bake_node(scene)
	return scene


func _bake_node(node: Node) -> void:
	if node is MeshInstance3D:
		_bake_mesh_instance(node as MeshInstance3D)
	for child in node.get_children():
		_bake_node(child)


func _position_key(position: Vector3) -> Vector3i:
	return Vector3i(
		roundi(position.x * POSITION_QUANTIZATION),
		roundi(position.y * POSITION_QUANTIZATION),
		roundi(position.z * POSITION_QUANTIZATION)
	)


func _bake_mesh_instance(mesh_instance: MeshInstance3D) -> void:
	var source := mesh_instance.mesh as ArrayMesh
	if not source or source.get_surface_count() == 0:
		return

	var normal_sums: Dictionary = {}
	var normal_counts: Dictionary = {}
	for surface_index in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if vertices.size() != normals.size():
			continue
		for vertex_index in vertices.size():
			var key := _position_key(vertices[vertex_index])
			normal_sums[key] = normal_sums.get(key, Vector3.ZERO) + normals[vertex_index].normalized()
			normal_counts[key] = int(normal_counts.get(key, 0)) + 1

	var baked := ArrayMesh.new()
	baked.resource_name = source.resource_name
	for blend_shape_index in source.get_blend_shape_count():
		baked.add_blend_shape(source.get_blend_shape_name(blend_shape_index))
	baked.blend_shape_mode = source.blend_shape_mode

	for surface_index in source.get_surface_count():
		var arrays: Array = source.surface_get_arrays(surface_index)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if vertices.size() == normals.size():
			var old_colors := PackedColorArray()
			if arrays[Mesh.ARRAY_COLOR] != null:
				old_colors = arrays[Mesh.ARRAY_COLOR]
			var colors := PackedColorArray()
			colors.resize(vertices.size())
			for vertex_index in vertices.size():
				var key := _position_key(vertices[vertex_index])
				var sum: Vector3 = normal_sums.get(key, normals[vertex_index])
				var count := int(normal_counts.get(key, 1))
				var smooth: Vector3 = normals[vertex_index].normalized()
				if sum.length() > float(count) * 0.15:
					smooth = sum.normalized()
				var alpha: float = old_colors[vertex_index].a if old_colors.size() == vertices.size() else 1.0
				colors[vertex_index] = Color(
					smooth.x * 0.5 + 0.5,
					smooth.y * 0.5 + 0.5,
					smooth.z * 0.5 + 0.5,
					alpha
				)
			arrays[Mesh.ARRAY_COLOR] = colors

		var blend_shapes: Array = source.surface_get_blend_shape_arrays(surface_index)
		baked.add_surface_from_arrays(
			source.surface_get_primitive_type(surface_index), arrays, blend_shapes
		)
		baked.surface_set_name(baked.get_surface_count() - 1, source.surface_get_name(surface_index))
		baked.surface_set_material(baked.get_surface_count() - 1, source.surface_get_material(surface_index))

	baked.custom_aabb = source.custom_aabb
	mesh_instance.mesh = baked
