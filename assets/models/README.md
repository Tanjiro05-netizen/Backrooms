# 3D Models — Blender → GLB pipeline

`.glb` is the shared interchange format for this project. The **same file**
is consumed by:

- the **web game** (`web/index.html`) via `THREE.GLTFLoader`, and
- the **Godot 4** project (`godot/`) via its native glTF importer.

Author once in Blender, export a `.glb`, drop it in the right folder — both
engines pick it up.

```
assets/models/
├── entities/          # the creatures (one per level)
│   ├── smiler.glb     # Level 0  — The Smiler
│   ├── hound.glb      # Level 1  — The Hound
│   ├── crawler.glb    # Level 2  — The Crawler
│   └── drowned.glb    # Level 37 — The Drowned
└── props/             # optional set-dressing (crates, lamps, pipes…)
```

If an entity `.glb` is **absent or fails to load**, the web game silently falls
back to its built-in procedural creature — so you can add models one at a time.

---

## Conventions (match these and models "just work")

| Property     | Convention                                                        |
|--------------|-------------------------------------------------------------------|
| Up axis      | **Y-up** (Blender glTF exporter converts Z-up → Y-up for you)      |
| Facing       | Model looks down **-Z** (the game rotates it to face the player)   |
| Scale        | **Metres, life-size.** Player eye height is 1.62 m. Feet at Y = 0. |
| Origin       | On the floor, centred (X/Z = 0) so it plants on the ground.        |
| Materials    | PBR metallic-roughness (Principled BSDF). Keep textures ≤ 1–2 K.   |
| Emissive     | Use the Emission input for glowing eyes/grins — both engines read it. |

### Animation
Bake actions into the glTF (enable **Animation** on export). The web loader
plays the **first clip** automatically via `AnimationMixer`; name a clip
`idle`, `walk`, `run`, or `hunt` and you can wire state-driven playback later
(hooks are in `loadEntityModel()` in `web/index.html`). Godot exposes every
clip on an `AnimationPlayer`.

---

## Exporting from Blender (2.9+ / 3.x / 4.x)

1. Select your model (mesh + armature).
2. **File ▸ Export ▸ glTF 2.0 (.glb/.gltf)**.
3. Format: **glTF Binary (.glb)**.
4. Include: **Selected Objects**. Transform: **+Y Up**.
5. Data ▸ Mesh: **Apply Modifiers**, **UVs**, **Normals**, **Tangents**.
6. Data ▸ Material: **Export**. Data ▸ Animation: **on** (if animated).
7. Save as e.g. `assets/models/entities/hound.glb`.

Blender's own exporter is the reference implementation — no add-on required.
For heavier map/level authoring the community add-on
`indiedevcasts/blender-godot-pipeline` automates collision suffixes and
per-object export if you want it later.

---

## Using a format other than GLB

GLB is recommended (single file, PBR, animation, smallest, and the Godot bridge
reads it too). But the web loader also handles other formats — just point the
entity's `url` at the file and the matching loader is fetched automatically:

| Format | Extension | Animation | Notes |
|--------|-----------|-----------|-------|
| glTF Binary / Text | `.glb` `.gltf` | ✅ | Best. |
| FBX | `.fbx` | ✅ | Heavier; auto-loads the `fflate` dependency. |
| Wavefront OBJ | `.obj` | ❌ | Static. Add a `.mtl` for materials (see below). |
| Collada | `.dae` | ✅ | Verbose XML, larger files. |
| STL | `.stl` | ❌ | Geometry only → gets a neutral default material. |
| PLY | `.ply` | ❌ | Geometry only (uses vertex colours if present). |

Edit the `ENTITY_MODELS` registry in `web/index.html`:

```js
const ENTITY_MODELS={
  hound  :{url:'../assets/models/entities/hound.fbx', scale:0.01, yOffset:0},          // FBX (often authored in cm → scale down)
  crawler:{url:'../assets/models/entities/crawler.obj', mtl:'../assets/models/entities/crawler.mtl', scale:1.0},
  drowned:{url:'../assets/models/entities/drowned.stl', scale:1.0}                      // STL: geometry only
};
```

Gotchas:
- **OBJ/FBX often need scaling** — OBJ has no unit info and FBX is frequently in
  centimetres, so a model can import 100× too big or small. Tune `scale`.
- **OBJ has no animation.** Use GLB/FBX/DAE if you need baked clips.
- **STL/PLY have no materials** — they render with a neutral grey PBR material;
  override it in `_wrapGeo()` if you want a different look.
- These loaders are fetched from a CDN on first use, so a non-GLB model needs an
  internet connection (GLB's `GLTFLoader` is already bundled in the page).

## Testing models in the web game

Browsers block `file://` XHR, so loading a local `.glb` needs a tiny server:

```bash
cd Backrooms
python3 -m http.server 8123
# open http://localhost:8123/web/index.html
```

Opening `web/index.html` by double-click still runs the game fine — it just
uses the procedural entities instead of the GLBs.

To point an entity at a different file or tweak its scale/offset, edit the
`ENTITY_MODELS` registry near the top of the entity section in
`web/index.html`.
