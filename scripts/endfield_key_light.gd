@tool
extends DirectionalLight3D

## Keeps screen-space bangs projection aligned with the actual key light.
## DirectionalLight3D emits down local -Z, so +Z points toward the light source.
@export var hair_shadow_material: ShaderMaterial
@export var sync_hair_shadow := true


func _ready() -> void:
	set_process(true)
	_sync_hair_shadow_direction()


func _process(_delta: float) -> void:
	_sync_hair_shadow_direction()


func _sync_hair_shadow_direction() -> void:
	if not sync_hair_shadow or not hair_shadow_material or not is_inside_tree():
		return
	var light_direction := global_transform.basis.z.normalized()
	var current: Variant = hair_shadow_material.get_shader_parameter("light_dir_ws")
	if current is Vector3 and (current as Vector3).distance_squared_to(light_direction) < 0.0000001:
		return
	hair_shadow_material.set_shader_parameter("light_dir_ws", light_direction)
