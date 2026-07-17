# Design Notes — how iOS games & Backrooms games should look and feel

Research summary that drives this project's visual & feel decisions, and how
each finding maps to the code.

## 1. The Kane Pixels standard: clean image, believable seasoning

The reference for "good Backrooms" is Kane Parsons' *The Backrooms (Found
Footage)* series. The key production insight: he did **not** shoot on degraded
media. Clean, high-resolution digital footage comes first, and restrained
analog texture is layered on top so the image "reads as old tape while
standing up to close visual scrutiny." Controlled palettes, minimal sound
design, and restrained camera choreography keep the focus on **spatial**
cues — the horror is an extra doorway, not a glitch storm.

**→ In code:** the VHS pass was retuned so artifacts are *events, not floors*.

- Dropout dashes and signal-loss streaks are now fully gated behind dropout /
  glitch events — the baseline image has none (previously ~2.5% of scanlines
  flashed dashes every frame).
- The tracking wobble band drifts in and out (`bGate`) instead of roaming
  permanently.
- Grain floor cut ~3× (0.008 + 0.020·V), scanlines halved, dot crawl, chroma
  noise, AGC flutter, barrel distortion and fringing all reduced.
- Grade reworked for deeper blacks (`0.985+0.015` lift, gamma 0.97) instead of
  a washed lift — perceived quality lives in the blacks.
- Presets remapped: CLEAN 0 · VHS 0.42 · HEAVY 0.85; default render quality is
  now CRISP (1.0) with device pixel ratio up to 2.0. The adaptive-resolution
  system is the perf safety net, not a permanently soft image.
- Glitch feedback from entity proximity halved and capped; false-AF hunts are
  ~2× rarer. Terror moments still spike the signal — they just have headroom
  to *read* as moments now.

## 2. What makes Backrooms games scary (Escape the Backrooms / Escape Together)

Reviews and design writing about the genre agree on the same points:

- **Lighting is the fear engine.** Flickering fluorescents, dim pockets, the
  60 Hz buzz. "Dim lighting, flickering lights, and strange sounds that
  suddenly appear keep players on high alert."
- **Silence and emptiness beat monsters.** "Even when no creatures are
  visible, the silence and emptiness are the most terrifying aspects." The
  horror "feels wrong rather than loud."
- **Realistic graphics + minimal UI + dreary ambience** — the world speaks,
  not the interface.
- **Unexplained rules and per-run variation** keep the space untrustworthy.

**→ In code:** the horror director leans on lighting and sound-absence events
(section blackouts, hum cuts, distant thuds) rather than screen effects; the
baked AO + contact shadows sell the "real place" reading; the HUD stays a
minimal diegetic camcorder OSD; nerve/hallucination systems make the *space*
untrustworthy rather than spamming jumpscares.

## 3. iOS game feel (Apple HIG + mobile design practice)

- Touch targets ≥ 44 pt, anchored to screen edges where thumbs rest; controls
  should feel native and contextual — show buttons only when usable.
- Immersive genres favour minimal, diegetic UI over chrome.
- Haptics + spatial audio are the immersion multipliers on iOS.
- Respect the notch/home indicator via safe-area insets.

**→ In code:** edge-anchored stick/buttons padded by `env(safe-area-inset-*)`;
the USE and DRINK buttons appear only when actionable; gyro look ("aim the
phone like the camcorder") with the iOS 13+ permission flow; haptic hooks on
damage/hunt/pickup/death; positional beeps, panned director events, heartbeat
and breath layers in the WebAudio mix.

## Sources

- [The Backrooms (Found Footage) — 4 years on from Kane Pixels' first video](https://medium.com/@thebackrooms.online/the-backrooms-found-footage-4-years-on-from-kane-pixels-first-backrooms-video-2f3b6c2b3dad)
- [Backrooms (web series) — Wikipedia](https://en.wikipedia.org/wiki/Backrooms_(web_series))
- [Escape the Backrooms — Steam](https://store.steampowered.com/app/1943950/Escape_the_Backrooms/)
- [Escape the Backrooms review — Push Square (PS5)](https://www.pushsquare.com/reviews/ps5/escape-the-backrooms)
- [Escape the Backrooms review — GameSpot](https://www.gamespot.com/reviews/escape-the-backrooms-review/1900-6418431/)
- [Escape the Backrooms — still worth it in 2026? (builttofrag)](https://builttofrag.com/escape-the-backrooms-review/)
- [Designing for games — Apple Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-games)
- [Make your game great with touch — WWDC26](https://developer.apple.com/videos/play/wwdc2026/358/)
- [Turning phone UX into game mechanics in SIMULACRA 2 — Game Developer](https://www.gamedeveloper.com/design/deep-dive-turning-phone-ux-into-game-mechanics-in-horror-game-i-simulacra-2-i-)
- [How to immerse players through effective UI and game design — Unity](https://unity.com/blog/games/how-to-immerse-your-players-through-effective-ui-and-game-design)
- [Backrooms: Escape Together — official site](https://www.backroomsescapetogether.com/)
