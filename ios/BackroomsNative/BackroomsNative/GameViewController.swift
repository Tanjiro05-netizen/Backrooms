import UIKit
import MetalKit
import BackroomsCore
import BackroomsRender

/// The native game screen: an `MTKView` driving `GameSession`, with on-screen
/// controls. Left thumb is a virtual stick (push past the rim to sprint),
/// right thumb drags to look — the same scheme the web build uses on phones,
/// so muscle memory carries over.
final class GameViewController: UIViewController, MTKViewDelegate {

    private var mtkView: MTKView!
    private var renderer: MetalRenderer!
    private var session: GameSession!

    private var input = GameSession.Input()
    private var lastFrame: CFTimeInterval = CACurrentMediaTime()

    // Touch tracking
    private var moveTouch: UITouch?
    private var moveOrigin: CGPoint = .zero
    private var lookTouch: UITouch?
    private var lookLast: CGPoint = .zero

    private let stickRadius: CGFloat = 90
    private let lookSensitivity: Double = 0.005

    private var hud: UILabel!
    private var stickView: UIView!
    private var knobView: UIView!
    private var deathView: UIView!
    private var loadingView: UIView!
    private var cardView: UIView!
    private var cardTitle: UILabel!
    private var cardSub: UILabel!
    private var promptButton: UIButton!
    private var messageLabel: UILabel!
    private var cardAgainButton: UIButton!
    /// Set while the next floor is being generated, so the cut only fires once.
    private var buildingNextFloor = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let renderer = MetalRenderer() else {
            showFailure("This device has no Metal support.")
            return
        }
        self.renderer = renderer

        mtkView = MTKView(frame: view.bounds, device: renderer.device)
        mtkView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.depthStencilPixelFormat = .depth32Float
        mtkView.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1)
        mtkView.preferredFramesPerSecond = 60
        mtkView.delegate = self
        mtkView.isMultipleTouchEnabled = true
        view.addSubview(mtkView)

        do {
            try renderer.prepare(colorFormat: mtkView.colorPixelFormat,
                                 depthFormat: mtkView.depthStencilPixelFormat)
        } catch {
            showFailure("Shader pipeline failed: \(error)")
            return
        }

        buildOverlay()
        loadLevel(0)
    }

    /// Generating a floor means synthesising ~2M pixels of wallpaper, carpet
    /// and ceiling on the CPU, so it happens off the main thread behind a card
    /// rather than freezing the first second of the app.
    private func loadLevel(_ index: Int, resettingRun: Bool = false) {
        loadingView.isHidden = false
        hud.isHidden = true
        promptButton.isHidden = true
        messageLabel.text = nil
        let renderer = self.renderer!
        DispatchQueue.global(qos: .userInitiated).async {
            let session = GameSession(levelIndex: index, renderer: renderer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.session = session
                self.input = GameSession.Input()
                self.moveTouch = nil
                self.lookTouch = nil
                self.stickView.alpha = 0
                self.knobView.alpha = 0
                self.lastFrame = CACurrentMediaTime()
                self.loadingView.isHidden = true
                self.hud.isHidden = false
                self.buildingNextFloor = false
                _ = resettingRun
            }
        }
    }

    /// Descending keeps the run going, so the existing session builds the next
    /// floor in place rather than being replaced — that is what carries the
    /// run's tape total down with you.
    private func descendToNextFloor() {
        guard !buildingNextFloor, let session, let renderer else { return }
        buildingNextFloor = true
        showCard(title: "DESCENDING",
                 sub: LevelSpec.standardLevels[min(session.levelIndex + 1, 3)].name,
                 showRestart: false)
        DispatchQueue.global(qos: .userInitiated).async {
            session.advanceToNextFloor(renderer: renderer)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lastFrame = CACurrentMediaTime()
                self.input = GameSession.Input()
                self.moveTouch = nil
                self.lookTouch = nil
                self.stickView.alpha = 0
                self.knobView.alpha = 0
                self.buildingNextFloor = false
                // The card stays up; `.transitioning` clears it when its timer
                // runs out, so the cut has a consistent length either way.
            }
        }
    }

    private func showCard(title: String, sub: String, showRestart: Bool) {
        cardTitle.text = title
        cardSub.text = sub
        cardAgainButton.isHidden = !showRestart
        cardView.isHidden = false
    }

    private func showFailure(_ message: String) {
        let label = UILabel(frame: view.bounds)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: 15, weight: .semibold)
        label.text = message
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    // MARK: - Overlay

    private func buildOverlay() {
        stickView = UIView()
        stickView.layer.borderWidth = 2
        stickView.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
        stickView.layer.cornerRadius = stickRadius
        stickView.isUserInteractionEnabled = false
        stickView.alpha = 0
        view.addSubview(stickView)

        knobView = UIView()
        knobView.backgroundColor = UIColor(white: 1, alpha: 0.14)
        knobView.layer.borderWidth = 2
        knobView.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        knobView.layer.cornerRadius = 34
        knobView.isUserInteractionEnabled = false
        knobView.alpha = 0
        view.addSubview(knobView)

        hud = UILabel()
        hud.numberOfLines = 0
        hud.textColor = UIColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        hud.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        hud.shadowColor = .black
        hud.shadowOffset = CGSize(width: 0, height: 1)
        hud.isUserInteractionEnabled = false
        view.addSubview(hud)

        let lamp = UIButton(type: .system)
        lamp.setTitle("LAMP", for: .normal)
        lamp.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        lamp.tintColor = .white
        lamp.layer.borderWidth = 2
        lamp.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        lamp.layer.cornerRadius = 30
        lamp.addTarget(self, action: #selector(toggleLamp), for: .touchUpInside)
        lamp.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(lamp)

        NSLayoutConstraint.activate([
            lamp.widthAnchor.constraint(equalToConstant: 60),
            lamp.heightAnchor.constraint(equalToConstant: 60),
            lamp.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            lamp.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])

        promptButton = UIButton(type: .system)
        promptButton.titleLabel?.font = .monospacedSystemFont(ofSize: 14, weight: .bold)
        promptButton.tintColor = UIColor(red: 0.85, green: 1, blue: 0.92, alpha: 1)
        promptButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
        promptButton.layer.borderWidth = 2
        promptButton.layer.borderColor = UIColor(red: 0.4, green: 0.95, blue: 0.7, alpha: 0.8).cgColor
        promptButton.layer.cornerRadius = 6
        promptButton.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        promptButton.isHidden = true
        promptButton.addTarget(self, action: #selector(useAction), for: .touchUpInside)
        promptButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(promptButton)

        messageLabel = UILabel()
        messageLabel.numberOfLines = 2
        messageLabel.textAlignment = .center
        messageLabel.textColor = UIColor(red: 0.91, green: 1, blue: 0.95, alpha: 1)
        messageLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        messageLabel.shadowColor = .black
        messageLabel.shadowOffset = CGSize(width: 0, height: 1)
        messageLabel.isUserInteractionEnabled = false
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)

        NSLayoutConstraint.activate([
            promptButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            promptButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -110),
            messageLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            messageLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
            messageLabel.bottomAnchor.constraint(equalTo: promptButton.topAnchor, constant: -16)
        ])

        buildDeathOverlay()
        buildLoadingOverlay()
        buildCard()
    }

    /// The between-floors card, reused for the win screen. Both are "the tape
    /// cuts, then tells you where you are", so they are the same view.
    private func buildCard() {
        cardView = UIView(frame: view.bounds)
        cardView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cardView.backgroundColor = .black
        cardView.isHidden = true
        view.addSubview(cardView)

        cardTitle = UILabel()
        cardTitle.textAlignment = .center
        cardTitle.textColor = UIColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        cardTitle.font = .monospacedSystemFont(ofSize: 30, weight: .heavy)
        cardTitle.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardTitle)

        cardSub = UILabel()
        cardSub.numberOfLines = 0
        cardSub.textAlignment = .center
        cardSub.textColor = UIColor(white: 0.62, alpha: 1)
        cardSub.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        cardSub.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(cardSub)

        let again = UIButton(type: .system)
        again.setTitle("NEW RUN", for: .normal)
        again.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        again.tintColor = .white
        again.layer.borderWidth = 2
        again.layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
        again.layer.cornerRadius = 6
        again.tag = 77
        again.isHidden = true
        again.addTarget(self, action: #selector(newRun), for: .touchUpInside)
        again.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(again)
        cardAgainButton = again

        NSLayoutConstraint.activate([
            cardTitle.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            cardTitle.centerYAnchor.constraint(equalTo: cardView.centerYAnchor, constant: -24),
            cardSub.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            cardSub.topAnchor.constraint(equalTo: cardTitle.bottomAnchor, constant: 14),
            cardSub.widthAnchor.constraint(lessThanOrEqualTo: cardView.widthAnchor, multiplier: 0.8),
            again.centerXAnchor.constraint(equalTo: cardView.centerXAnchor),
            again.topAnchor.constraint(equalTo: cardSub.bottomAnchor, constant: 30),
            again.widthAnchor.constraint(equalToConstant: 180),
            again.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    private func buildLoadingOverlay() {
        loadingView = UIView(frame: view.bounds)
        loadingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        loadingView.backgroundColor = .black
        loadingView.isHidden = true
        view.addSubview(loadingView)

        let label = UILabel()
        label.text = "◉ GENERATING FLOOR"
        label.textColor = UIColor(white: 0.72, alpha: 1)
        label.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor)
        ])
    }

    /// Shown when vitals hit zero. It covers the stick and the lamp so only
    /// REWIND is reachable; `touchesBegan` additionally ignores stray touches
    /// while dead, since a plain `UIView` still lets them reach the controller.
    private func buildDeathOverlay() {
        deathView = UIView(frame: view.bounds)
        deathView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        deathView.backgroundColor = UIColor(white: 0, alpha: 0.86)
        deathView.isHidden = true
        view.addSubview(deathView)

        let caption = UILabel()
        caption.numberOfLines = 0
        caption.textAlignment = .center
        caption.textColor = UIColor(red: 0.86, green: 0.20, blue: 0.18, alpha: 1)
        caption.font = .monospacedSystemFont(ofSize: 22, weight: .heavy)
        caption.text = "SIGNAL LOST\n\nTAPE RECOVERED"
        caption.translatesAutoresizingMaskIntoConstraints = false
        deathView.addSubview(caption)

        let retry = UIButton(type: .system)
        retry.setTitle("REWIND", for: .normal)
        retry.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        retry.tintColor = .white
        retry.layer.borderWidth = 2
        retry.layer.borderColor = UIColor(white: 1, alpha: 0.4).cgColor
        retry.layer.cornerRadius = 6
        retry.addTarget(self, action: #selector(restart), for: .touchUpInside)
        retry.translatesAutoresizingMaskIntoConstraints = false
        deathView.addSubview(retry)

        NSLayoutConstraint.activate([
            caption.centerXAnchor.constraint(equalTo: deathView.centerXAnchor),
            caption.centerYAnchor.constraint(equalTo: deathView.centerYAnchor, constant: -30),
            retry.centerXAnchor.constraint(equalTo: deathView.centerXAnchor),
            retry.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 28),
            retry.widthAnchor.constraint(equalToConstant: 160),
            retry.heightAnchor.constraint(equalToConstant: 48)
        ])
    }

    @objc private func toggleLamp() { input.lampOn.toggle() }

    @objc private func useAction() {
        guard let session, session.phase == .playing else { return }
        if let done = session.interact(renderer: renderer) {
            // A tape is a small confirmation; the door is a commitment.
            let style: UIImpactFeedbackGenerator.FeedbackStyle
            switch done {
            case .tape: style = .light
            case .door: style = .heavy
            }
            UIImpactFeedbackGenerator(style: style).impactOccurred()
        }
    }

    @objc private func newRun() {
        cardAgainButton.isHidden = true
        cardView.isHidden = true
        loadLevel(0, resettingRun: true)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard hud != nil else { return }   // renderer failed; only the notice is up
        hud.frame = CGRect(x: view.safeAreaInsets.left + 20,
                           y: view.safeAreaInsets.top + 14,
                           width: 320, height: 60)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // MARK: - Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard session != nil, !session.isDead else { return }
        for touch in touches {
            let p = touch.location(in: view)
            if p.x < view.bounds.width * 0.5 {
                guard moveTouch == nil else { continue }
                moveTouch = touch
                moveOrigin = p
                stickView.frame = CGRect(x: p.x - stickRadius, y: p.y - stickRadius,
                                         width: stickRadius * 2, height: stickRadius * 2)
                knobView.frame = CGRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68)
                stickView.alpha = 1
                knobView.alpha = 1
            } else if lookTouch == nil {
                lookTouch = touch
                lookLast = p
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            let p = touch.location(in: view)
            if touch === moveTouch {
                var dx = (p.x - moveOrigin.x) / stickRadius
                var dy = (p.y - moveOrigin.y) / stickRadius
                let len = sqrt(dx * dx + dy * dy)
                if len > 1 { dx /= len; dy /= len }
                input.moveX = Double(dx)
                input.moveZ = Double(dy)
                // Pushing the stick to the rim sprints, with hysteresis so it
                // does not chatter right at the boundary.
                if len >= 0.96 { input.run = true } else if len < 0.86 { input.run = false }
                knobView.center = CGPoint(x: moveOrigin.x + dx * stickRadius * 0.55,
                                          y: moveOrigin.y + dy * stickRadius * 0.55)
            } else if touch === lookTouch {
                input.lookDeltaX += Double(p.x - lookLast.x) * lookSensitivity
                input.lookDeltaY += Double(p.y - lookLast.y) * lookSensitivity
                lookLast = p
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endTouches(touches) }

    private func endTouches(_ touches: Set<UITouch>) {
        for touch in touches {
            if touch === moveTouch {
                moveTouch = nil
                input.moveX = 0; input.moveZ = 0; input.run = false
                stickView.alpha = 0; knobView.alpha = 0
            } else if touch === lookTouch {
                lookTouch = nil
            }
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let session, let renderer else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 0.25)
        lastFrame = now

        let size = view.drawableSize
        let aspect = size.height > 0 ? Float(size.width / size.height) : 1.777
        session.update(deltaTime: dt, input: input, aspect: aspect)
        // Look deltas are consumed once; movement persists while held.
        input.lookDeltaX = 0
        input.lookDeltaY = 0

        if let scene = session.scene,
           let descriptor = view.currentRenderPassDescriptor {
            renderer.draw(scene: scene, uniforms: session.uniforms,
                          entity: session.entityMesh,
                          tape: session.tape, drawableSize: size,
                          passDescriptor: descriptor, drawable: view.currentDrawable)
        }
        updateHUD()
    }

    private func updateHUD() {
        switch session.phase {
        case .dead:
            deathView.isHidden = false
            promptButton.isHidden = true
            messageLabel.text = nil
            hud.text = ""
            return
        case .escaped:
            promptButton.isHidden = true
            messageLabel.text = nil
            hud.text = ""
            let secs = Int(session.elapsed)
            showCard(title: "YOU GOT OUT",
                     sub: String(format: "RUNTIME %02ld:%02ld\nTAPES RECOVERED %ld", 
                                 secs / 60, secs % 60, session.tapesTotal),
                     showRestart: true)
            return
        case .awaitingDescent:
            descendToNextFloor()
            return
        case .transitioning:
            return                      // card is up, floor is already rebuilt
        case .playing:
            break
        }
        deathView.isHidden = true
        cardView.isHidden = true

        // The prompt is the only thing telling you an objective is actionable,
        // so it doubles as the button on touch.
        if let action = session.availableInteraction {
            let label = action == .door
                ? (session.isFinalFloor ? "OPEN THE LAST DOOR" : "OPEN DOOR — DESCEND")
                : action.label
            promptButton.setTitle("▸ \(label)", for: .normal)
            promptButton.isHidden = false
        } else {
            promptButton.isHidden = true
        }
        messageLabel.text = session.message

        let name = LevelSpec.standardLevels[session.levelIndex].name
        let secs = Int(session.elapsed)
        let clock = String(format: "%02ld:%02ld", secs / 60, secs % 60)
        var text = "● REC   \(name)   \(clock)"
        text += "\nTAPES   \(session.tapesThisFloor)/\(session.tapeGoal) HERE   \(session.tapesTotal) TOTAL"
        text += "\nVITALS  \(Int(session.health))%   STAMINA \(Int(session.player.stamina))%"
        if let exit = session.exit {
            let d = ((exit.x - session.player.x) * (exit.x - session.player.x)
                     + (exit.z - session.player.z) * (exit.z - session.player.z)).squareRoot()
            let word = session.isFinalFloor ? "EXIT" : "DESCEND"
            text += String(format: "\n%@ ▸ %.0fM%@", word, d, exit.revealed ? "" : "  (UNFOUND)")
        }
        if let d = session.hunterDistance {
            text += String(format: "\n⚠ CONTACT %.0fM", d)
        } else {
            text += String(format: "\nSIGNAL ▸ %.0fS", max(0, session.nextHunt))
        }
        hud.text = text
    }

    @objc private func restart() {
        session.restart(renderer: renderer)
        input = GameSession.Input()
        moveTouch = nil
        lookTouch = nil
        stickView.alpha = 0
        knobView.alpha = 0
        lastFrame = CACurrentMediaTime()
    }
}
