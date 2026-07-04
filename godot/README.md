# Godot 4 bridge — BACKROOMS // FOUND FOOTAGE

This is a **starting scaffold / bridge**, not a full port. It gives you:

- `project.godot` — Godot 4.2+ project with input maps matching the web build.
- `shaders/vhs.gdshader` — the web game's VHS shader ported to Godot's shading
  language (canvas_item screen shader). Same YIQ chroma bleed, dot-crawl,
  head-switch tear, tracking, dropout, 4:3 pillarbox, CLEAN/VHS/HEAVY presets.
- `scenes/Main.tscn` — a tiny lit scene so the project runs immediately and you
  can see the filter working. Replace the 3D side with your real levels.
- `scripts/vhs_controller.gd` — drives the shader uniforms (presets, 4:3,
  dropout, and hooks for glitch/IR/heat/battery from gameplay).
- `scripts/entity_loader.gd` — loads the **shared** `assets/models` GLBs so
  Godot and the web build use the exact same Blender models.

## Open it

1. Launch Godot 4.2 or newer.
2. **Import** ▸ select `godot/project.godot`.
3. Press **Play** (F5). You'll see a floor + wall through the VHS filter.
4. In-game: **V** cycles CLEAN → VHS → HEAVY, **B** toggles 4:3.

## How the post-processing is wired

`Main.tscn` puts a `CanvasLayer (layer 10)` over the 3D world with a full-rect
`ColorRect`. The ColorRect's `ShaderMaterial` uses `shaders/vhs.gdshader` and
`scripts/vhs_controller.gd` feeds it uniforms each frame. Bloom is handled by
the `WorldEnvironment` **Glow** (higher quality than a manual bright pass), so
the shader itself skips bloom — matching the look of the web build's bloom pass.

To drive scares from gameplay, call from your code:

```gdscript
$PostFX/VHS.set_glitch(proximity)   # 0..1, ramps near the entity
$PostFX/VHS.set_ir(nightshot ? 1.0 : 0.0)
$PostFX/VHS.set_heat(level_is_pipes ? 1.0 : 0.0)
$PostFX/VHS.set_lowbatt(battery < 15 ? 1.0 : 0.0)
```

## Shared models (the whole point of the bridge)

Both engines read `../assets/models/entities/*.glb`. For iteration,
`entity_loader.gd` runtime-loads the external `.glb` with `GLTFDocument`. For a
shipping build, copy or symlink `assets/models` into `godot/assets/` so Godot
imports them normally and you can `preload()` them:

```bash
# from repo root — symlink so there's one source of truth
ln -s ../../assets/models godot/assets/models
```

See `../assets/models/README.md` for the Blender export conventions (Y-up,
faces -Z, metres, feet at Y=0).

## What a full port would add (roadmap, not included)

The web build's procedural generation (level grids, procedural textures,
entity AI, audio) lives in `web/index.html`. Porting it means reimplementing:
level generation in GDScript, materials via `StandardMaterial3D`/shaders, the
four entity state machines, and the Web Audio synthesis via `AudioStreamPlayer`
buses. The VHS look, input maps, asset pipeline and scene skeleton are already
done here to build on.
