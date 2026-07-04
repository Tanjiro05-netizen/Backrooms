extends ColorRect
## Drives the VHS post-process shader (shaders/vhs.gdshader).
##
## Setup:
##   1. Add a CanvasLayer as a child of your main scene (layer = 10).
##   2. Add a ColorRect child, anchors = Full Rect, mouse_filter = Ignore.
##   3. Give it a ShaderMaterial whose shader = res://shaders/vhs.gdshader.
##   4. Attach this script to that ColorRect.
##
## Presets mirror the web build: CLEAN (0.0) / VHS (0.6) / HEAVY (1.0),
## plus a 4:3 camcorder toggle. Feed `glitch`, `ir`, `heat`, `lowbatt`
## from your gameplay code (proximity to entity, nightshot, level, battery).

const PRESETS := {"clean": 0.0, "vhs": 0.6, "heavy": 1.0}
const ORDER := ["clean", "vhs", "heavy"]

@export var preset: String = "vhs"
@export var crt_43: bool = false

var _mat: ShaderMaterial
var _dropout: float = 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_mat = material as ShaderMaterial
	_rng.randomize()
	_apply()

func _process(delta: float) -> void:
	if _mat == null:
		return
	var vp := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("res", vp)
	_mat.set_shader_parameter("intensity", PRESETS.get(preset, 0.6))
	_mat.set_shader_parameter("aspect43", 1.0 if crt_43 else 0.0)

	# animated tape dropout, same feel as the web build
	_dropout = max(0.0, _dropout - delta * 2.2)
	var g: float = _mat.get_shader_parameter("glitch") if _mat.get_shader_parameter("glitch") != null else 0.0
	if PRESETS.get(preset, 0.6) > 0.01 and _rng.randf() < delta * (0.35 + g * 2.0):
		_dropout = 0.55 + _rng.randf() * 0.45
	_mat.set_shader_parameter("dropout", _dropout)

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("cycle_vhs"):
		var i := ORDER.find(preset)
		preset = ORDER[(i + 1) % ORDER.size()]
		_apply()
	elif event.is_action_pressed("toggle_43"):
		crt_43 = not crt_43
		_apply()

func _apply() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("intensity", PRESETS.get(preset, 0.6))
	_mat.set_shader_parameter("aspect43", 1.0 if crt_43 else 0.0)

## Call from gameplay code:
func set_glitch(v: float) -> void: if _mat: _mat.set_shader_parameter("glitch", v)
func set_ir(v: float) -> void:     if _mat: _mat.set_shader_parameter("ir", v)
func set_heat(v: float) -> void:   if _mat: _mat.set_shader_parameter("heat", v)
func set_lowbatt(v: float) -> void: if _mat: _mat.set_shader_parameter("lowbatt", v)
