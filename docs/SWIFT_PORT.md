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
3. **CI is the compiler.** `.github/workflows/ios.yml` builds the shell and
   runs `swift test` on a macOS runner for every push touching `ios/`, `web/`
   or `swift/` — development of this port can proceed from any machine.

## Status

| System | Package | Fixture-tested | Notes |
|---|---|---|---|
| `Mulberry32` RNG | ✅ BackroomsCore | ✅ reference stream | bit-exact 32-bit wrapping port |
| Level specs (4 floors) | ✅ BackroomsCore | ✅ via map fixtures | generation params only |
| Map generator | ✅ BackroomsCore | ✅ all 4 floors exact | walls/zones/pillars/doors/fixtures + connectivity carving |
| BFS distance field | ✅ BackroomsCore | ✅ (drives generator) | entity pathfinding |
| Grid-DDA line of sight | ✅ BackroomsCore | smoke tests | used by AI + audio occlusion later |
| Colliders + player movement | ⬜ next | — | port `collide()` + friction model, fixture: recorded input → position trace |
| Entity AI (idle/seen/hunt, telegraph, stalker reposition) | ⬜ | — | port state machine; fixture: scripted scenario traces |
| Tapes / items / exits / level flow | ⬜ | — | pure logic, easy fixtures |
| Nerve/sanity + horror director | ⬜ | — | port schedules; keep event weights |
| **Renderer (Metal)** | ⬜ | — | see below |
| Audio (AVAudioEngine) | ⬜ | — | procedural synth port of the WebAudio graph |
| Input (touch/gyro) | ⬜ | — | reuse shell's Core Motion work |

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
5. Metal renderer bootstrap: level mesh + textures + lights + camera.
6. VHS post chain in MSL; A/B screenshot comparison against the web build.
7. AVAudioEngine synth: port `noiseBurst`-family + drone/heartbeat graph.
8. New SwiftUI app target `BackroomsNative` alongside the shell; ship both
   until parity, then switch the App Store target.

## Working agreement

- `swift test --package-path swift/BackroomsCore` must stay green; CI runs it
  on every push.
- When JS gameplay logic changes, re-dump fixtures in the same commit.
- Floats: `Double` in core sim (matches JS numbers exactly); `Float` only at
  the renderer boundary.
