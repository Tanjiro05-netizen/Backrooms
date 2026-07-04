extends Node3D
## Loads a Blender-authored .glb entity from the SHARED asset folder
## (../assets/models/entities) so the Godot build and the web build use the
## exact same models. Falls back gracefully if the file is missing.
##
## Usage:
##   var e := EntityLoader.new()
##   add_child(e)
##   e.load_entity("hound")   # -> loads ../assets/models/entities/hound.glb
##
## The shared assets live OUTSIDE res:// (they're one folder up, next to the
## web build). Two ways to consume them in Godot:
##   A) Let Godot import them: copy/symlink assets/models into godot/assets so
##      they get .import files and can be preloaded (recommended for shipping).
##   B) Runtime-load an external .glb with GLTFDocument (used below) — handy
##      while iterating, no reimport needed.

const SHARED_DIR := "res://../assets/models/entities/"  # dev: sibling of godot/

var _mixer_player: AnimationPlayer

func load_entity(kind: String) -> Node3D:
	var path := SHARED_DIR + kind + ".glb"
	var abs := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs):
		push_warning("Entity model not found: %s (using placeholder)." % abs)
		return _placeholder(kind)

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(abs, state)
	if err != OK:
		push_warning("Failed to load %s (err %d)." % [abs, err])
		return _placeholder(kind)

	var scene: Node3D = doc.generate_scene(state)
	add_child(scene)
	_mixer_player = scene.find_child("AnimationPlayer", true, false)
	if _mixer_player and _mixer_player.get_animation_list().size() > 0:
		_mixer_player.play(_mixer_player.get_animation_list()[0])
	return scene

func play_clip(name: String) -> void:
	if _mixer_player and _mixer_player.has_animation(name):
		_mixer_player.play(name)

func _placeholder(kind: String) -> Node3D:
	# minimal stand-in so the scene still runs without art
	var m := MeshInstance3D.new()
	var caps := CapsuleMesh.new()
	caps.height = 2.0
	caps.radius = 0.35
	m.mesh = caps
	m.position.y = 1.0
	add_child(m)
	return m
