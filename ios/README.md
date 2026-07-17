# Backrooms iOS app

This is the first native iOS delivery target for the existing game. It is a
landscape-only SwiftUI application which bundles `web/` and `assets/` locally,
then hosts `web/index.html` in a `WKWebView`. The app deliberately preserves
the web game's `web/../assets` layout, so its local GLB character files keep
working without a server or CDN.

## Open and run

1. On a Mac with Xcode 15 or newer, open `BackroomsIOS.xcodeproj`.
2. In **Signing & Capabilities**, replace `com.example.backrooms` with your own
   unique bundle identifier and choose an Apple development team.
3. Choose an iPhone or iPad simulator/device and run. The app is locked to
   landscape on both phone and tablet.

## Manual work required before TestFlight

1. **Use a Mac and a physical iPhone.** The Simulator is useful for launch and
   layout checks, but it cannot validate real gyro feel, thermal behavior,
   haptics, WebGL performance, or audio interruptions.
2. **Set your signing identity.** In Xcode, replace `com.example.backrooms`,
   choose your Apple development team, and register that identifier in the
   Apple Developer portal when you create an App Store Connect record.
3. **Verify gyro feel on hardware.** Both landscape directions are mapped
   (the coordinator mirrors the axes from the live interface orientation);
   confirm the signs feel right on a physical device and flip `mirror` in
   `BackroomsWebView.swift` if they do not.
4. **Test the shipped asset layout.** On a device, start a run and verify every
   GLB creature loads. The app bundles `web/` and `assets/` as folder resources;
   do not flatten or move either folder without also changing the relative
   asset URLs in the game.
5. **Add privacy-sensitive features deliberately.** Do not add a microphone
   usage description, Game Center capability, CloudKit container, analytics
   SDK, or StoreKit product until its player-facing feature and App Store
   privacy declaration are ready.
6. **Profile before expanding content.** Archive a Release build, use
   Instruments/Xcode's memory graph on device, and run a 20–30 minute session
   on at least one baseline supported iPhone before committing to the web-shell
   path for launch.

## What exists now

- Local, offline-first game bundle.
- Landscape-only app orientation and an immersive full-screen SwiftUI host
  (status bar and home indicator hidden, first edge-swipe deferred to the game).
- Complete `Info.plist` (executable/bundle metadata, black launch screen,
  export-compliance flag) and an asset catalog with the in-engine app icon
  (1024 px, no alpha) and launch background color.
- `AVAudioSession` playback category — the tape keeps playing with the silent
  switch on — and the idle timer disabled so the screen never sleeps mid-run.
- `WKScriptMessageHandler` bridge named `backroomsNative`.
- Native impact feedback via cached, pre-warmed haptic generators for the
  game's pickup, damage, hunt, and death intents.
- Native Core Motion gyro at 60 Hz routed into the existing game-side gyro
  toggle, with both landscape orientations mapped; it stops when the app
  resigns active and re-arms itself through `backrooms:nativeResume`.
- A lifecycle bridge that pauses an active run when the application backgrounds
  or is interrupted, so the player explicitly resumes audio and gameplay.
- External links open in Safari rather than replacing the game document.
- Web Inspector enabled for Debug builds (Safari → Develop → your device).

## Intentionally deferred

Game Center, CloudKit, microphone/voice chat, gyro calibration UI, and StoreKit
need their own player-facing UX and entitlement/privacy configuration. Add
them through the existing native message bridge rather than exposing arbitrary
native calls to the web page.
