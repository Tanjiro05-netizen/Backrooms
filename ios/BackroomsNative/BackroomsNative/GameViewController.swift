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

        session = GameSession(levelIndex: 0, renderer: renderer)
        buildOverlay()
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

        buildDeathOverlay()
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
                          passDescriptor: descriptor, drawable: view.currentDrawable)
        }
        updateHUD()
    }

    private func updateHUD() {
        if session.isDead {
            deathView.isHidden = false
            hud.text = ""
            return
        }
        deathView.isHidden = true

        let name = LevelSpec.standardLevels[session.levelIndex].name
        let secs = Int(session.elapsed)
        let clock = String(format: "%02ld:%02ld", secs / 60, secs % 60)
        var text = "● REC   \(name)   \(clock)"
        text += "\nVITALS  \(Int(session.health))%   STAMINA \(Int(session.player.stamina))%"
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
