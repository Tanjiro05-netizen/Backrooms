# Enhancements & Research Notes

## 0. Intensity update — graphics, dread & gameplay (single-player)

Aimed at the *Backrooms: Escape Together* bar, within a phone's budget.

**Graphics**
- **Baked ambient occlusion.** The floor and ceiling are single planes over the
  whole map, so AO is baked per level into a canvas from the wall grid (soft
  dark bands along every wall edge, radial pools under pillars) and sampled as
  an `aoMap`. Walls get a matching contact-shadow gradient injected into the
  standard shader (`addWallAO`). Corners and corridor edges now read as
  *grounded* instead of floating CG.
- **Two-cone flashlight.** A wide dim spill spot around the sharp hot spot —
  and the lamp gutters when the battery is nearly dead.
- **Adaptive resolution.** A rolling frame-time average rescales the internal
  render buffer (0.55–1×) to hold frame rate; the VHS grain hides the upscale.
  This is the lever that keeps iPhones at 60 when they thermal-throttle.
- **three.js vendored locally** (`web/lib/`) — the game now runs fully offline,
  a hard requirement for wrapping it as an iOS app.

**Intensity**
- **Nerve (sanity) system.** Darkness, blackouts, sightings and hits erode it;
  light, tapes and almond water restore it. Low nerve bleeds into everything:
  the VHS shader degrades, hands tremble, breathing and a heartbeat rise in the
  mix, and the viewfinder starts showing you things that are not there.
- **Horror director.** Between encounters it schedules ambient dread: distant
  thuds several rooms away (stereo-panned), section blackouts with a power-down
  whine, the 60 Hz hum simply *stopping*, false autofocus panics, whispers in
  the static, and half-second silhouette glimpses.
- **Entity upgrades.** Hunts are telegraphed ~1.3 s ahead (lights sag,
  something exhales); during stalking phases the entity closes ground while
  you are not looking (never while observed, never through your line of
  sight); hunts grant an adrenaline stamina surge so you always get a chance
  to run.

**Gameplay**
- **Items with randomized spawns:** camcorder batteries (+55% charge) and
  almond water — carried, drunk with **[Q]** / DRINK for health + nerve.
- New HUD: nerve bar, carry indicator, low-battery lamp behaviour.

**Mobile / iOS**
- **Gyro look** (title-screen toggle, iOS 13+ permission flow): aim the phone
  like the camcorder; blends with drag-look.
- Safe-area insets (`viewport-fit=cover` + `env(safe-area-inset-*)`) so
  controls clear the notch/home indicator; haptic hooks on damage, hunts,
  pickups and death (`navigator.vibrate` today — a no-op on iOS Safari, live
  once wrapped natively).

## 1. VHS shader — rebuilt around the real analog signal path

The previous shader did an RGB channel split + scanlines + grain. That reads as
"chromatic aberration," not as VHS. Real VHS colour artifacts come from how the
format **encodes** the signal, so the shader now models that chain
(`VHS_FRAG` in `web/index.html`, ported to `godot/shaders/vhs.gdshader`):

- **YIQ chroma-bandwidth reduction + chroma delay.** Luma is sampled sharp;
  chroma (I/Q) is reconstructed from ~7 horizontally-spread taps and delayed to
  the right. VHS stores luma at ~3 MHz but chroma at only ~0.6 MHz, so colour
  smears sideways and lags the edges — the single most recognizable VHS tell.
- **Luma ringing / overshoot.** An unsharp term on luma adds the bright/dark
  halo around high-contrast edges that analog sharpening circuits produce.
- **Dot crawl.** A field-walking checkerboard shimmer on chroma at colour
  boundaries — the classic composite-video "crawling ants" artifact.
- **Head-switching tear.** The torn, noisy band along the **bottom** of the
  frame where the tape head switches (was previously only a small top glitch).
- **Tape dropout.** Random bright horizontal dashes, pulsed and decaying, worse
  on low battery and during scares.
- **Separate luma vs chroma noise**, tracking-band wobble, occasional vertical
  hold roll, interlace shimmer, scanlines, warm-shadow/cool-highlight grade.
- **4:3 camcorder pillarbox** — analog-horror framing, with clean black bars.
- **One `intensity` master** drives every amount, so **Clean / VHS / Heavy** all
  come from a single shader with no branching cost.

## 2. Graphics

- **Soft-knee bloom.** The bright-pass now uses a smooth threshold+knee and
  preserves colour in the glow instead of a hard cutoff that washed to white.
- **Runtime render-quality** (Grit / Standard / Crisp) rescales the internal
  buffer live — a genuine sharpness/perf lever the old fixed `RSCALE` didn't
  expose.
- Slightly warmer, filmic grade and gentler vignette falloff.

## 3. GLB / cross-engine structure

- Split the single HTML file into a project tree (`web/`, `assets/`, `godot/`,
  `docs/`) with the original kept intact as a backup.
- Added `THREE.GLTFLoader` + an `ENTITY_MODELS` registry and `loadEntityModel()`
  that hot-swaps procedural creatures for Blender `.glb` models (with an
  `AnimationMixer` for baked clips) and falls back silently when absent.
- Godot 4 bridge shares the **same** `assets/models` GLBs via `GLTFDocument`.

## 4. Research that informed the work

- **Authentic VHS emulation** — YIQ processing, chroma-bandwidth reduction, dot
  crawl and ringing as the true sources of the look (vs. naive aberration):
  Harry Alisavakis' VHS write-up; NTSC/YIQ artifact references; the ntscQT and
  MC-VHS emulators.
- **Analog / found-footage horror aesthetic** — 4:3 framing, grain, tracking
  lines and camcorder viewfinder framing as genre grammar (DEADCAM, The Final
  Take; analog-horror overviews).
- **Backrooms / liminal-space design** — dread from uniform lighting, unsettling
  repetition, sound and isolation over jump-scares; "a door that wasn't there
  before, a hum that cuts out."
- **Cross-engine asset workflow** — GLB as the shared Blender→Three.js/Godot
  interchange format; Godot's native glTF import.

### Sources
- [Harry Alisavakis — VHS Image Effect write-up](https://halisavakis.com/write-up-vhs-image-effect/)
- [How To Make A Retro VHS Effect Shader (gamedev.center)](https://gamedev.center/how-to-make-a-retro-vhs-effect-shader-in-unity/)
- [YIQ color space (Grokipedia)](https://grokipedia.com/page/YIQ)
- [Removal of chroma artefacts / dot crawl (doom9)](https://www.doom9.org/capture/chroma_artefacts.html)
- [ntscQT — analog video simulator](https://github.com/JargeZ/ntscqt)
- [Analog horror (Wikipedia)](https://en.wikipedia.org/wiki/Analog_horror)
- [Analog Horror Video Games (Ties That Bind Gaming)](https://www.tiesthatbindgaming.com/analog-horror-video-games/)
- [Backrooms, liminal spaces & indie horror design (Game Developer)](https://www.gamedeveloper.com/design/backrooms-liminal-spaces-and-the-subliminal-menace-of-loneliness-in-indie-horror-games)
- [Liminal game design (Arena Animation)](https://arenaparkstreet.com/liminal-game-design-creating-spaces-that-feel-haunted-without-horror/)
- [Introducing the Godot glTF 2.0 scene exporter](https://godotengine.org/article/introducing-the-godot-gltf-2-0-scene-exporter/)
- [glTF 2.0 — Blender Manual](https://docs.blender.org/manual/en/latest/addons/import_export/scene_gltf2.html)
- [blender-godot-pipeline add-on](https://github.com/indiedevcasts/blender-godot-pipeline)
