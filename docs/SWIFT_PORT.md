# The full-Swift native game — port plan

Goal: the ENTIRE game running natively in Swift on iOS — no WKWebView, no
JavaScript at runtime. The WKWebView shell in `ios/` ships v1 while this port
is built alongside it; both live in the same repo and share fixtures.

## Ground rules

1. **Deterministic core first, rendering second.** Everything that decides
   *what the world is* lives in the pure-Swift `swift/BackroomsCore` package —
   no UIKit, no Metal imports. It must stay bit-for-bit compatible with the
   web build: same `mulberry32` stream, same maps, same AI decisions where
   determinism applies.
2. **Fixtures are the contract.** Every ported system gets fixtures dumped
   from the running JS game (`tools/` + Playwright) and an XCTest asserting
   exact equality. A port without a fixture test is a rewrite, not a port.
3. **CI is the compiler.** `.github/workflows/ios.yml` builds the shell, builds
   the native app, and runs `swift test` on a macOS runner for every push
   touching `ios/`, `web/` or `swift/` — development of this port can proceed
   from any machine.

## Running the native app

```sh
open ios/BackroomsNative/BackroomsNative.xcodeproj
```

Pick any iPhone simulator and hit run. The project references
`swift/BackroomsCore` as a **local** Swift package (`XCLocalSwiftPackageReference`),
so there is nothing to fetch and edits to the core are picked up on the next
build. Controls: left thumb is a virtual stick — push it to the rim to sprint —
right thumb drags to look, LAMP toggles the camcorder light.

`Shaders.metal` ships as a package *resource* so plain `swift build` — and
therefore CI — can verify the renderer target with no app around it; that path
compiles the shader source at runtime via `device.makeLibrary(source:)`.

`BackroomsNative` also has the same file added directly to its own Compile
Sources, so a real app build gets a precompiled metallib and `makeLibrary()`
returns before the runtime path ever runs. This is the fix for a real device
failure: the runtime resource lookup (`Bundle.module`/`Bundle.main`) had never
been exercised outside of CI's simulator *build* — CI never launches the app —
and came up empty the first time someone actually ran it on hardware. Keep
both: the resource copy is what makes the package buildable standalone, the
Compile Sources entry is what makes the app not depend on that lookup working.

## Status

| System | Package | Fixture-tested | Notes |
|---|---|---|---|
| `Mulberry32` RNG | ✅ BackroomsCore | ✅ reference stream | bit-exact 32-bit wrapping port |
| Level specs (4 floors) | ✅ BackroomsCore | ✅ via map fixtures | generation params only |
| Map generator | ✅ BackroomsCore | ✅ all 4 floors exact | walls/zones/pillars/doors/fixtures + connectivity carving |
| BFS distance field | ✅ BackroomsCore | ✅ (drives generator) | entity pathfinding |
| Grid-DDA line of sight | ✅ BackroomsCore | smoke tests | used by AI + audio occlusion later |
| Wall/pillar geometry emitters | ✅ BackroomsCore | ✅ all 4 floors byte-exact | per-chunk Float32 buffers FNV-hashed vs the JS builders |
| Collider buckets | ✅ BackroomsCore | ✅ all 4 floors exact | wall+pillar rects; theme-prop colliders come with props |
| Player movement + `collide()` + stamina | ✅ BackroomsCore | ✅ 480-frame traces, <1e-6 drift | driven by the real `updatePlayer`; tolerance not hash (transcendentals) |
| Entity hunt navigation (`EntityHunt`) | ✅ BackroomsCore | ✅ 300-frame chase traces, exact | BFS repath + greedy descent + speed model + burst + attack; seeded crawler burst |
| Entity defs (4 creatures) | ✅ BackroomsCore | ✅ | full `ENTITY_DEFS` row incl. sight range, creep, gaze rules, base hunt delay |
| Theme props (crates/pipes/pool platforms, fixture geo) | ⬜ | — | needs cylinder/sphere/torus emitters (`appendGeom` equivalents) |
| Entity idle/seen phases (`EntityPresence`) | ✅ BackroomsCore | ✅ placement/gaze/flee/reposition rules + determinism | sighting, creep, gaze-vanish, flee-on-gaze, stalker reposition, hunt telegraph. Web mixes `lrng()` + `Math.random()`; this port seeds both, on two separate streams |
| Tapes / exits / level flow | ✅ BackroomsCore | ✅ placement + interaction + full run | 2 tapes/floor, door relocation, descent, escape; items still to come |
| Nerve/sanity + horror director | ⬜ | — | port schedules; keep event weights |
| Camera / matrix math (`Mat4`, `Camera`) | ✅ BackroomsCore | ✅ view+proj vs Three.js, exact | YXZ euler + GL and Metal depth conventions |
| **Renderer (Metal)** | 🟡 BackroomsRender | ✅ layout/mesh/light tests | forward pass, uniforms, mesh upload, per-frame entity mesh, albedo/normal/roughness materials with mips |
| Game loop (`GameSession`) | ✅ BackroomsRender | ✅ hunt/death/restart/bounds | fixed 1/60 accumulator over map+player+hunter+camera |
| **Native app target** | ✅ `ios/BackroomsNative` | ✅ builds in CI | `MTKView`, virtual stick + drag look, OSD, USE prompt, floor cards, death/rewind, win screen, start menu + pause/quit, IR nightshot toggle, compass arrows |
| Difficulty (`DIFFS`) | ✅ BackroomsCore | ✅ via existing presence tests | `EntityDifficulty` multipliers were already threaded through `EntityPresence`; `Difficulty` adds the run-level rules (`beaconAlways`, `tapeHints`) and the menu picks it. STANDARD is all-1.0, so fixtures are unaffected |
| On-screen wayfinding | 🟡 arrows done | — | tape + exit compass arrows and bearings, ported from the web arrow math. The *wall* arrows (`buildWallArrows`, spray-painted trail toward the door) are still 3D geometry work and not started |
| Audio (AVAudioEngine) | ✅ BackroomsCore + Render | ✅ filter response, envelopes, every sound audible + bounded | procedural: no audio files exist in this project. Biquad/Envelope/Voice/AudioMixer are pure; AudioHost is one AVAudioSourceNode |
| Input (touch/gyro) | 🟡 touch done | — | gyro still to come; reuse shell's Core Motion work |
| VHS post chain (MSL) | ✅ BackroomsRender | ✅ uniform layout + state response | analog tape model — chroma bandwidth, time-base error, head switching; offscreen target + resolve pass |
| Procedural textures | ✅ BackroomsCore | ✅ range/tiling/normal tests | all 4 themes' wall+floor+ceiling; grime passes reimplemented, not byte-matched |

## Renderer decision

**Metal + MetalKit, written directly** (no SceneKit — deprecated; no engine
dependency). The web renderer is deliberately simple to port:

- One merged static mesh per material bucket per level (positions/normals/uvs
  are already generated procedurally — `BackroomsCore` will emit the same
  vertex buffers the JS builders make).
- Procedural canvas textures → port the generators to CPU-side pixel buffers
  (they're just noise/FBM/stains — Swift ports cleanly) uploaded as `MTLTexture`.
- Forward pass with a handful of point lights + spot (flashlight), fog in the
  fragment shader — the JS scene never exceeds ~8 dynamic lights.
- Post chain is where the identity lives: bright-pass → separable blur →
  **the VHS composite shader**, translated line-for-line from GLSL to MSL
  (same uniforms: intensity, glitch, ir, dropout, aspect43…).
- Baked AO: reuse `GameMap` to rasterize the same wall-distance AO into a
  texture; wall contact gradient moves into the wall fragment shader.

## Porting order (each step lands green in CI)

1. ✅ RNG + map generation + pathfinding/LOS (this commit).
2. Geometry emitters: vertex-buffer builders for walls/floors/props matching
   the JS `pushQuad` layout; fixture = vertex/index counts + checksums.
3. Player sim: movement, collision, stamina/battery/health/nerve ticks;
   fixture = deterministic input-script → state trace comparison.
4. Entity AI + director as a fixed-timestep simulation module.
5. ✅ Metal renderer bootstrap: level mesh + lights + camera + entity.
6. ✅ App target `BackroomsNative` alongside the shell — it launches, generates
   a floor, and is hunted. **This is where the port stands.**
7. ✅ Procedural textures: the canvas generators as CPU pixel buffers, plus
   normal and roughness maps and a tangent frame derived from the UV layout.
8. ✅ VHS post chain in MSL, rebuilt as an analog tape model rather than a
   glitch filter; verified by rendering the web build and looking at it.
9. ✅ Tapes, exits and the four-floor run — the native build is playable
   start to finish.
10. ✅ Audio: the WebAudio graph as a pure Swift synth (`Biquad`, `Envelope`,
    `Voice`, `AudioMixer`) behind one `AVAudioSourceNode`, with an
    `AudioDirector` turning game state into voices and bed levels.
11. ✅ The entity's other two thirds: `EntityPresence` owns idle, sighting and
    hunt as one state machine, so the thing schedules its own appearances and
    the session just feeds it the player and the camera's facing.
12. Items, theme props, nerve/sanity + horror director, gyro — then switch the
    App Store target from the shell to native.

## Working agreement

- `swift test --package-path swift/BackroomsCore` must stay green; CI runs it
  on every push.
- When JS gameplay logic changes, re-dump fixtures in the same commit.
- Floats: `Double` in core sim (matches JS numbers exactly); `Float` only at
  the renderer boundary.
