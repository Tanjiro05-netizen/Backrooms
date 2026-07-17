# iOS Roadmap — "Best Backrooms Game on iOS"

Target style: **Backrooms: Escape Together** (PS5/Steam). What defines that game,
per its store pages and site: **1–6 player co-op**, **proximity voice chat that
adapts to walls and rooms**, **entities that hear you through your microphone**,
and **11 procedurally generated levels** where every run randomizes layout, item
spawns, and entity encounters.

What we already have (in `web/index.html`): a complete single-player loop —
seeded procedural maps (`mulberry32` → `generateMap`), 4 levels, 4 entities with
a threat/aggro system, tapes + a wandering exit door, per-cell BFS + line-of-sight
(`bfsFrom`, `losClear`), WebAudio with positional panning (`panTo`), a virtual
stick + look-zone touch UI, and the multi-pass VHS shader with runtime quality
scaling. That is a genuinely strong base — the plan below is about (1) making it
a *real iOS product*, (2) adding the co-op/voice layer that defines the target
game, and (3) tripling content depth.

---

## Pillar 0 — Ship decision: how it becomes an iOS app

| Option | Effort | Verdict |
|---|---|---|
| **Capacitor (WKWebView) wrapper around the existing Three.js game** | Low — game is one HTML file, zero server deps | ✅ **Recommended for v1.** Keeps 100% of the working game; unlocks App Store, haptics, Game Center, mic permission prompts, push. |
| PWA (Add to Home Screen) | Trivial | Do it anyway as the free demo/marketing funnel, but no App Store presence, no Game Center, weaker audio/mic permissions. |
| Godot 4 iOS export (bridge already in `godot/`) | High — gameplay would need a full port; only the VHS shader + input maps exist | v2 option if we hit WKWebView performance walls. Don't start here. |

**Capacitor v1 checklist**
- App shell: landscape-lock, `viewport-fit=cover` + CSS `env(safe-area-inset-*)`
  so the stick/buttons clear the notch and home indicator.
- **Audio unlock:** iOS requires a user gesture before `AudioContext` runs —
  resume it inside the PLAY button handler (`initAudio` already exists; gate it).
- **Haptics** (Capacitor Haptics plugin): light tick on tape pickup, heavy pulse
  on entity hit (`damagePlayer`), rumble ramp tied to the existing threat state
  (DORMANT → HUNTING). `navigator.vibrate` is a no-op in iOS Safari, so this is
  a native-shell win specifically.
- **Game Center**: achievements + leaderboards (see Pillar 5).
- App Store assets: the VHS aesthetic screenshots basically make themselves.

## Pillar 1 — iOS-first game feel

1. **Gyro camcorder look (the killer iOS feature).** `DeviceOrientationEvent`
   (with the iOS permission request) blended with the existing drag-look: you
   physically *hold the phone as the camcorder*. No PS5 version can do this —
   it's our differentiator, not a compromise. Add a toggle + recenter button.
2. **Dynamic resolution.** We already rescale the internal buffer at runtime
   (Grit/Standard/Crisp). Make it automatic: measure frame time over a rolling
   window, step `quality` down/up to hold 60 (or 120 on ProMotion via
   unlocked rAF). The VHS grain actively hides upscaling — low res is *on brand*.
3. **Touch polish.** Current stick/look-zone works; add: sprint by pushing the
   stick past 90%, tap-to-interact on the world prompt (replacing the USE
   button), pinch for camcorder zoom (with AF hunt + zoom-noise on the shader),
   `touch-action:none` / gesture-conflict audit, larger hit targets.
4. **Battery/thermal mode:** detect `navigator.getBattery` absence gracefully;
   offer a "long session" preset (lower res + 30 Hz entity AI tick).

## Pillar 2 — Co-op + proximity voice (the Escape Together layer)

This is the single biggest gap, and the architecture is unusually ready for it:

- **Shared worlds are nearly free.** Maps are already deterministic from a seed.
  Co-op world sync = share one seed + level index in the lobby. No geometry
  netcode at all.
- **Topology:** WebRTC data channels, host-authoritative, 2–6 players. A tiny
  signaling server (or a managed layer like PlayroomKit/Colyseus) issues room
  codes — "join with a 4-letter code" is the right mobile UX.
- **What syncs:**
  - Player transforms + anim state at ~12 Hz, interpolated (unreliable channel).
  - Entity position/target/threat from the **host only** (entities keep their
    existing AI, it just runs on one machine).
  - Events as reliable messages: tape pickup, door relocate (`relocateExit`),
    damage, death, descend.
- **Teammate avatars:** players render as *other camcorder-holders* — a simple
  rig + a glowing REC dot + IR lamp cone. Found-footage fiction holds: you're a
  film crew that went in together.
- **Proximity voice chat with wall occlusion.** WebRTC audio streams routed into
  the existing WebAudio graph: `PannerNode` (HRTF) per teammate, and — this is
  the part we get almost for free — run the existing `losClear()` between
  listener and speaker and drive a low-pass filter + gain cut when walls block.
  "Voice that adapts to walls and rooms" is Escape Together's flagship feature
  and our grid + LOS code makes it ~50 lines.
- **Entities hear you.** With mic permission already granted for voice chat,
  meter local mic level and feed it into the entity threat system as a noise
  stimulus (same pathway as running footsteps). Screaming when the Hound is
  near gets your whole squad killed. Solo players get this too ("it can hear
  you" mode, opt-in).
- **Death ≠ spectate boredom:** dead players become static-drenched spectator
  tapes of living teammates, can still talk (with heavy VHS voice degradation).

## Pillar 3 — Content depth (4 levels → 9+, Escape Together has 11)

New floors, each with one mechanic (keep the one-file procedural approach —
every level below is buildable with the existing quad/chunk generators):

1. **Level ! (RUN FOR YOUR LIFE)** — a single long red corridor, scripted chase,
   sprint-only, collapsing behind you. Cheap geometry, huge payoff.
2. **Level Fun =)** — party room, balloons, cake props; **Partygoers** entity
   that *waves before it charges*.
3. **Level 6 (Lights Out)** — pitch black, nightshot-IR only, battery drain ×3;
   the existing NV system becomes a survival resource.
4. **The Hub / The End** — finale + win state upgrade.
5. **Poolrooms expansion** — swimmable water volumes, drowned ambushes from
   below the surface.

Systems that multiply replay value:

- **Skin-Stealer (co-op-only entity):** occasionally an "extra teammate" spawns
  wearing another player's avatar; only voice proximity and behavior give it
  away. This mechanic alone markets the game.
- **Items & randomized spawns:** almond water (heal + sanity), spare batteries,
  glowsticks (droppable breadcrumbs, visible to teammates), keycards/valves as
  per-level objectives beyond tapes (Pipe Dreams: close 3 valves to stop the
  steam that blinds you; Habitable Zone: restore power to open the exit).
- **Sanity:** darkness + isolation + entity sightings drain it; low sanity
  amplifies the VHS shader (`intensity` master is already a single uniform) and
  produces false audio cues. Being near teammates restores it — a co-op reason
  to stick together *and* split up.
- **Daily seed run:** everyone worldwide gets the same descent each day;
  leaderboard by time (Game Center + a tiny score endpoint).
- **Difficulty modifiers:** entity density, battery scarcity, permadeath tape.

## Pillar 4 — Audio & visuals within a phone budget

- Replace one-shot `noiseBurst` ambience with **layered per-level loops**
  (fluorescent hum with random dropouts, pipe knocks, pool reverb) + a
  **ConvolverNode reverb sized by BFS room-openness** at the listener cell.
- Occlusion-filter entity sounds with the same `losClear` trick as voice.
- Visuals: bake AO into vertex colors at generation time (free at runtime),
  animated caustics in the Poolrooms, flashlight shadow *fakery* (blob +
  projected gradient) instead of real shadow maps.
- Keep GLB entity hot-swap (`loadEntityModel`) — Blender-authored Partygoers /
  Skin-Stealer slot straight in on both engines.

## Pillar 5 — Meta & retention

- Progress save (per-level unlocks, best times) — extend the existing
  `localStorage` settings store, mirror to iCloud KV via Capacitor for device
  moves.
- Game Center achievements ("Descended to Level 37", "Escaped without running",
  "Survived Level ! with 4 alive") + daily-seed leaderboard.
- **Photo mode / clip export:** grab the post-VHS framebuffer to Photos — every
  screenshot is a marketing asset in disguise.
- Run-end "recovered tape report": time, tapes, distance, closest call.

---

## Phasing

| Phase | Scope | Outcome |
|---|---|---|
| **1. Real iOS app** (1–2 wk) | Capacitor shell, audio unlock, safe areas, gyro look, haptics, auto dynamic resolution, touch polish | TestFlight build that already feels native |
| **2. Co-op MVP** (2–4 wk) | Room codes, seed-shared maps, transform/event sync, host-run entities, proximity voice + wall occlusion, mic-aggro | The Escape Together loop, on phones |
| **3. Content** (2–4 wk) | Level !, Level Fun, Lights Out; items, sanity, objectives, Skin-Stealer | 7+ levels, per-run variety |
| **4. Meta & launch** (1–2 wk) | Game Center, daily seed, photo mode, achievements, store assets | App Store release |

Phase 1 has zero unknowns and immediately makes the current game shippable;
Phase 2 is the differentiator; content scales indefinitely after that.

## References

- [Backrooms: Escape Together — Steam](https://store.steampowered.com/app/2141730/Backrooms_Escape_Together/)
- [Backrooms: Escape Together — official site](https://www.backroomsescapetogether.com/)
- [Backrooms: Escape Together — PlayStation Store](https://store.playstation.com/en-us/concept/10015041)
- [Backrooms: Escape Together Wiki](https://backrooms-escape-together.fandom.com/wiki/Backrooms:_Escape_Together)
