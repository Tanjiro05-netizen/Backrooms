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
    /// Started lazily on the first frame: AVAudioEngine wants the audio session
    /// already active, and it is not worth blocking launch on.
    private var audio: AudioHost?

    private var input = GameSession.Input()
    private var lastFrame: CFTimeInterval = CACurrentMediaTime()

    // Touch tracking
    private var moveTouch: UITouch?
    private var moveOrigin: CGPoint = .zero
    private var lookTouch: UITouch?
    private var lookLast: CGPoint = .zero

    private let stickRadius: CGFloat = 90
    private let lookSensitivity: Double = 0.005

    /// Chosen on the menu, carried into every `GameSession` the run creates.
    private var chosenDifficulty: Difficulty = .standard
    /// IR nightshot. The shader has always supported it; this is the switch.
    private var nightVision = false
    /// True while the pause overlay is up — the world stops stepping but keeps
    /// drawing, so pausing does not black out the picture.
    private var isPaused = false

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

    // OSD
    private var recDot: UIView!
    private var nvLabel: UILabel!
    private var rightOSD: UILabel!
    private var threatLabel: UILabel!
    private var vitalsTrack: UIView!
    private var vitalsFill: UIView!
    private var staminaTrack: UIView!
    private var staminaFill: UIView!
    private var exitArrow: ArrowView!
    private var tapeArrow: ArrowView!

    // Menu / pause
    private var menuView: UIView!
    private var pauseView: UIView!
    private var pauseButton: UIButton!
    private var lampButton: UIButton!
    private var nvButton: UIButton!
    private var difficultyButtons: [UIButton] = []

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
        buildMenu()
        buildPauseOverlay()
        showMenu()
    }

    // MARK: - Run lifecycle

    private func showMenu() {
        session = nil
        isPaused = false
        // With no session, `draw` returns before it feeds the mixer — so the
        // drone and water beds would hold their last level under the menu
        // forever. Silence them on the way out.
        audio?.update { mixer in
            mixer.waterLevel = 0
            mixer.breathLevel = 0
            mixer.droneLevel = 0
        }
        buildingNextFloor = false
        menuView.isHidden = false
        pauseView.isHidden = true
        cardView.isHidden = true
        deathView.isHidden = true
        loadingView.isHidden = true
        setPlayChromeHidden(true)
    }

    /// Hides everything that only makes sense mid-run, so the menu is not
    /// showing a HUD for a session that does not exist yet.
    private func setPlayChromeHidden(_ hidden: Bool) {
        hud.isHidden = hidden
        recDot.isHidden = hidden
        rightOSD.isHidden = hidden
        threatLabel.isHidden = hidden
        vitalsTrack.isHidden = hidden
        vitalsFill.isHidden = hidden
        staminaTrack.isHidden = hidden
        staminaFill.isHidden = hidden
        lampButton.isHidden = hidden
        nvButton.isHidden = hidden
        pauseButton.isHidden = hidden
        if hidden {
            exitArrow.isHidden = true
            tapeArrow.isHidden = true
            nvLabel.isHidden = true
            promptButton.isHidden = true
            messageLabel.text = nil
            stickView.alpha = 0
            knobView.alpha = 0
        }
    }

    @objc private func startRun() {
        menuView.isHidden = true
        nightVision = false
        nvButton.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        setPlayChromeHidden(false)
        loadLevel(0, resettingRun: true)
    }

    @objc private func pickDifficulty(_ sender: UIButton) {
        guard sender.tag >= 0 && sender.tag < Difficulty.all.count else { return }
        chosenDifficulty = Difficulty.all[sender.tag]
        refreshDifficultyButtons()
    }

    private func refreshDifficultyButtons() {
        for button in difficultyButtons {
            let picked = button.tag < Difficulty.all.count
                && Difficulty.all[button.tag].id == chosenDifficulty.id
            button.layer.borderColor = picked
                ? UIColor(red: 0.55, green: 1, blue: 0.75, alpha: 0.95).cgColor
                : UIColor(white: 1, alpha: 0.22).cgColor
            button.layer.borderWidth = picked ? 3 : 2
            button.tintColor = picked
                ? UIColor(red: 0.85, green: 1, blue: 0.92, alpha: 1)
                : UIColor(white: 0.75, alpha: 1)
        }
    }

    @objc private func togglePause() {
        guard session != nil, session.phase == .playing else { return }
        isPaused = true
        pauseView.isHidden = false
        // Drop any held touch, or the stick stays deflected through the pause.
        moveTouch = nil
        lookTouch = nil
        input.moveX = 0
        input.moveZ = 0
        input.run = false
        stickView.alpha = 0
        knobView.alpha = 0
    }

    @objc private func resumeRun() {
        isPaused = false
        pauseView.isHidden = true
        // Without this the first frame back sees the whole paused wall-clock
        // as one step and teleports everything.
        lastFrame = CACurrentMediaTime()
    }

    @objc private func quitToMenu() {
        showMenu()
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
        let difficulty = chosenDifficulty
        DispatchQueue.global(qos: .userInitiated).async {
            let session = GameSession(levelIndex: index, renderer: renderer,
                                      difficulty: difficulty)
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

        // The exit arrow sits above the tape arrow, matching the web build's
        // 36% / 46% split — two arrows at the same height read as one control.
        exitArrow = ArrowView(color: UIColor(red: 0.62, green: 1, blue: 0.71, alpha: 1))
        exitArrow.isHidden = true
        view.addSubview(exitArrow)

        tapeArrow = ArrowView(color: UIColor(red: 1, green: 0.82, blue: 0.48, alpha: 1))
        tapeArrow.isHidden = true
        view.addSubview(tapeArrow)

        recDot = UIView()
        recDot.backgroundColor = UIColor(red: 1, green: 0.13, blue: 0.13, alpha: 1)
        recDot.layer.cornerRadius = 6
        recDot.isUserInteractionEnabled = false
        view.addSubview(recDot)
        // A camcorder's REC light is the one thing on screen that never stops
        // moving, so it does the work of telling you the tape is still running.
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1.0
        blink.toValue = 0.12
        blink.duration = 0.6
        blink.autoreverses = true
        blink.repeatCount = .infinity
        recDot.layer.add(blink, forKey: "blink")

        hud = UILabel()
        hud.numberOfLines = 0
        hud.textColor = UIColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        hud.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        hud.shadowColor = .black
        hud.shadowOffset = CGSize(width: 0, height: 1)
        hud.isUserInteractionEnabled = false
        view.addSubview(hud)

        rightOSD = UILabel()
        rightOSD.numberOfLines = 0
        rightOSD.textAlignment = .right
        rightOSD.textColor = UIColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        rightOSD.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        rightOSD.shadowColor = .black
        rightOSD.shadowOffset = CGSize(width: 0, height: 1)
        rightOSD.isUserInteractionEnabled = false
        view.addSubview(rightOSD)

        threatLabel = UILabel()
        threatLabel.font = .monospacedSystemFont(ofSize: 13, weight: .heavy)
        threatLabel.shadowColor = .black
        threatLabel.shadowOffset = CGSize(width: 0, height: 1)
        threatLabel.isUserInteractionEnabled = false
        view.addSubview(threatLabel)

        nvLabel = UILabel()
        nvLabel.text = "◉ NIGHTSHOT"
        nvLabel.textColor = UIColor(red: 0.49, green: 1, blue: 0.63, alpha: 1)
        nvLabel.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        nvLabel.shadowColor = .black
        nvLabel.shadowOffset = CGSize(width: 0, height: 1)
        nvLabel.isHidden = true
        nvLabel.isUserInteractionEnabled = false
        view.addSubview(nvLabel)

        (vitalsTrack, vitalsFill) = makeBar(UIColor(red: 1, green: 0.35, blue: 0.35, alpha: 1))
        (staminaTrack, staminaFill) = makeBar(UIColor(red: 0.95, green: 0.93, blue: 0.7, alpha: 1))

        lampButton = makeRoundButton("LAMP", action: #selector(toggleLamp))
        nvButton = makeRoundButton("NV", action: #selector(toggleNightVision))

        pauseButton = UIButton(type: .system)
        pauseButton.setTitle("❙❙", for: .normal)
        pauseButton.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        pauseButton.tintColor = .white
        pauseButton.layer.borderWidth = 2
        pauseButton.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        pauseButton.layer.cornerRadius = 6
        pauseButton.addTarget(self, action: #selector(togglePause), for: .touchUpInside)
        pauseButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pauseButton)

        NSLayoutConstraint.activate([
            lampButton.widthAnchor.constraint(equalToConstant: 60),
            lampButton.heightAnchor.constraint(equalToConstant: 60),
            lampButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            lampButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),

            nvButton.widthAnchor.constraint(equalToConstant: 60),
            nvButton.heightAnchor.constraint(equalToConstant: 60),
            nvButton.trailingAnchor.constraint(equalTo: lampButton.leadingAnchor, constant: -14),
            nvButton.bottomAnchor.constraint(equalTo: lampButton.bottomAnchor),

            pauseButton.widthAnchor.constraint(equalToConstant: 46),
            pauseButton.heightAnchor.constraint(equalToConstant: 34),
            pauseButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            pauseButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12)
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

    private func makeBar(_ color: UIColor) -> (UIView, UIView) {
        let track = UIView()
        track.backgroundColor = UIColor(white: 1, alpha: 0.13)
        track.layer.cornerRadius = 2
        track.isUserInteractionEnabled = false
        view.addSubview(track)

        let fill = UIView()
        fill.backgroundColor = color
        fill.layer.cornerRadius = 2
        fill.isUserInteractionEnabled = false
        view.addSubview(fill)
        return (track, fill)
    }

    private func makeRoundButton(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: .bold)
        button.tintColor = .white
        button.layer.borderWidth = 2
        button.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
        button.layer.cornerRadius = 30
        button.addTarget(self, action: action, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        return button
    }

    /// The start screen. Difficulty is picked here rather than in a settings
    /// panel because it changes what the run *is*, and the web build likewise
    /// commits to it before the first frame.
    private func buildMenu() {
        menuView = UIView(frame: view.bounds)
        menuView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menuView.backgroundColor = .black
        view.addSubview(menuView)

        let title = UILabel()
        title.text = "BACKROOMS"
        title.textAlignment = .center
        title.textColor = UIColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        title.font = .monospacedSystemFont(ofSize: 34, weight: .heavy)
        title.translatesAutoresizingMaskIntoConstraints = false
        menuView.addSubview(title)

        let sub = UILabel()
        sub.text = "FOUND FOOTAGE"
        sub.textAlignment = .center
        sub.textColor = UIColor(white: 0.5, alpha: 1)
        sub.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        sub.translatesAutoresizingMaskIntoConstraints = false
        menuView.addSubview(sub)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 14
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        menuView.addSubview(row)

        for (index, difficulty) in Difficulty.all.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(difficulty.label, for: .normal)
            button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
            button.layer.cornerRadius = 6
            button.tag = index
            button.addTarget(self, action: #selector(pickDifficulty(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
            difficultyButtons.append(button)
        }
        refreshDifficultyButtons()

        let blurb = UILabel()
        blurb.numberOfLines = 0
        blurb.textAlignment = .center
        blurb.textColor = UIColor(white: 0.45, alpha: 1)
        blurb.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        blurb.text = Difficulty.all.map { "\($0.label) — \($0.blurb)" }.joined(separator: "\n")
        blurb.translatesAutoresizingMaskIntoConstraints = false
        menuView.addSubview(blurb)

        let play = UIButton(type: .system)
        play.setTitle("▸ PLAY", for: .normal)
        play.titleLabel?.font = .monospacedSystemFont(ofSize: 18, weight: .heavy)
        play.tintColor = UIColor(red: 0.85, green: 1, blue: 0.92, alpha: 1)
        play.layer.borderWidth = 2
        play.layer.borderColor = UIColor(red: 0.4, green: 0.95, blue: 0.7, alpha: 0.85).cgColor
        play.layer.cornerRadius = 6
        play.addTarget(self, action: #selector(startRun), for: .touchUpInside)
        play.translatesAutoresizingMaskIntoConstraints = false
        menuView.addSubview(play)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: menuView.centerXAnchor),
            title.topAnchor.constraint(equalTo: menuView.safeAreaLayoutGuide.topAnchor, constant: 26),
            sub.centerXAnchor.constraint(equalTo: menuView.centerXAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),

            row.centerXAnchor.constraint(equalTo: menuView.centerXAnchor),
            row.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 26),
            row.widthAnchor.constraint(equalToConstant: 340),
            row.heightAnchor.constraint(equalToConstant: 46),

            blurb.centerXAnchor.constraint(equalTo: menuView.centerXAnchor),
            blurb.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 12),
            blurb.widthAnchor.constraint(lessThanOrEqualTo: menuView.widthAnchor, multiplier: 0.8),

            play.centerXAnchor.constraint(equalTo: menuView.centerXAnchor),
            play.topAnchor.constraint(equalTo: blurb.bottomAnchor, constant: 22),
            play.widthAnchor.constraint(equalToConstant: 200),
            play.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    private func buildPauseOverlay() {
        pauseView = UIView(frame: view.bounds)
        pauseView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pauseView.backgroundColor = UIColor(white: 0, alpha: 0.78)
        pauseView.isHidden = true
        view.addSubview(pauseView)

        let title = UILabel()
        title.text = "▮▮ PAUSED"
        title.textAlignment = .center
        title.textColor = UIColor(red: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        title.font = .monospacedSystemFont(ofSize: 24, weight: .heavy)
        title.translatesAutoresizingMaskIntoConstraints = false
        pauseView.addSubview(title)

        let resume = UIButton(type: .system)
        resume.setTitle("RESUME", for: .normal)
        resume.titleLabel?.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        resume.tintColor = UIColor(red: 0.85, green: 1, blue: 0.92, alpha: 1)
        resume.layer.borderWidth = 2
        resume.layer.borderColor = UIColor(red: 0.4, green: 0.95, blue: 0.7, alpha: 0.85).cgColor
        resume.layer.cornerRadius = 6
        resume.addTarget(self, action: #selector(resumeRun), for: .touchUpInside)
        resume.translatesAutoresizingMaskIntoConstraints = false
        pauseView.addSubview(resume)

        let quit = UIButton(type: .system)
        quit.setTitle("QUIT TO MENU", for: .normal)
        quit.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        quit.tintColor = UIColor(white: 0.72, alpha: 1)
        quit.layer.borderWidth = 2
        quit.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
        quit.layer.cornerRadius = 6
        quit.addTarget(self, action: #selector(quitToMenu), for: .touchUpInside)
        quit.translatesAutoresizingMaskIntoConstraints = false
        pauseView.addSubview(quit)

        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: pauseView.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: pauseView.centerYAnchor, constant: -70),
            resume.centerXAnchor.constraint(equalTo: pauseView.centerXAnchor),
            resume.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 26),
            resume.widthAnchor.constraint(equalToConstant: 200),
            resume.heightAnchor.constraint(equalToConstant: 48),
            quit.centerXAnchor.constraint(equalTo: pauseView.centerXAnchor),
            quit.topAnchor.constraint(equalTo: resume.bottomAnchor, constant: 14),
            quit.widthAnchor.constraint(equalToConstant: 200),
            quit.heightAnchor.constraint(equalToConstant: 44)
        ])
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

    @objc private func toggleLamp() {
        input.lampOn.toggle()
        lampButton.layer.borderColor = input.lampOn
            ? UIColor(white: 1, alpha: 0.25).cgColor
            : UIColor(white: 1, alpha: 0.08).cgColor
    }

    /// IR is a trade, not a free upgrade: the picture goes monochrome green and
    /// the lamp is what the entity does *not* need to find you.
    @objc private func toggleNightVision() {
        nightVision.toggle()
        nvLabel.isHidden = !nightVision
        nvButton.layer.borderColor = nightVision
            ? UIColor(red: 0.49, green: 1, blue: 0.63, alpha: 0.9).cgColor
            : UIColor(white: 1, alpha: 0.25).cgColor
    }

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

        let left = view.safeAreaInsets.left + 20
        let top = view.safeAreaInsets.top + 14
        recDot.frame = CGRect(x: left, y: top + 2, width: 12, height: 12)
        hud.frame = CGRect(x: left + 20, y: top, width: 340, height: 56)
        threatLabel.frame = CGRect(x: left, y: top + 60, width: 340, height: 18)

        let rightEdge = view.bounds.width - view.safeAreaInsets.right - 20
        rightOSD.frame = CGRect(x: rightEdge - 300, y: top + 46, width: 300, height: 54)
        nvLabel.frame = CGRect(x: left, y: top + 82, width: 200, height: 16)

        // Bars sit bottom-left, clear of the stick's usual thumb position.
        let barW: CGFloat = 132, barH: CGFloat = 6
        let barX = left
        let barY = view.bounds.height - view.safeAreaInsets.bottom - 34
        vitalsTrack.frame = CGRect(x: barX, y: barY, width: barW, height: barH)
        staminaTrack.frame = CGRect(x: barX, y: barY + 14, width: barW, height: barH)
        // Fills keep their frames from `updateOSD`; seed them so a first layout
        // before the first frame does not flash a zero-width bar.
        vitalsFill.frame = CGRect(x: barX, y: barY, width: vitalsFill.frame.width, height: barH)
        staminaFill.frame = CGRect(x: barX, y: barY + 14, width: staminaFill.frame.width, height: barH)

        let mid = view.bounds.midX
        exitArrow.bounds = CGRect(x: 0, y: 0, width: 62, height: 62)
        exitArrow.center = CGPoint(x: mid, y: view.bounds.height * 0.36)
        tapeArrow.bounds = CGRect(x: 0, y: 0, width: 44, height: 44)
        tapeArrow.center = CGPoint(x: mid, y: view.bounds.height * 0.46)
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

    // MARK: - Touch

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard session != nil, !session.isDead, !isPaused, menuView.isHidden else { return }
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
        guard !isPaused else { return }
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

        // Paused still draws — the frozen picture behind the overlay is the
        // point — it just does not advance the world or the tape.
        if !isPaused {
            session.update(deltaTime: dt, input: input, aspect: aspect)
            // Look deltas are consumed once; movement persists while held.
            input.lookDeltaX = 0
            input.lookDeltaY = 0

            // `update` rewrites the tape's state from the game every frame, so
            // the nightshot switch has to be applied after it, not before.
            session.tape.infrared = nightVision ? 1 : 0

            // The synth is a few hundred voices of arithmetic on its own thread;
            // starting it here rather than in viewDidLoad keeps launch clean.
            if audio == nil {
                let host = AudioHost()
                try? host.start()
                audio = host
            }
            if let audio {
                let decided = session.audio
                audio.play(decided.voices)
                audio.update { mixer in
                    mixer.waterLevel = decided.waterLevel
                    mixer.breathLevel = decided.breathLevel
                    mixer.droneLevel = decided.droneLevel
                    mixer.dronePan = decided.dronePan
                    mixer.muffleCutoff = decided.muffleCutoff
                }
            }
        }

        if let scene = session.scene,
           let descriptor = view.currentRenderPassDescriptor {
            renderer.draw(scene: scene, uniforms: session.uniforms,
                          entity: session.entityMesh,
                          tape: session.tape, drawableSize: size,
                          passDescriptor: descriptor, drawable: view.currentDrawable)
        }
        if !isPaused { updateOSD() }
    }

    private func updateOSD() {
        switch session.phase {
        case .dead:
            deathView.isHidden = false
            promptButton.isHidden = true
            messageLabel.text = nil
            hud.text = ""
            threatLabel.text = ""
            rightOSD.text = ""
            recDot.isHidden = true
            exitArrow.isHidden = true
            tapeArrow.isHidden = true
            return
        case .escaped:
            promptButton.isHidden = true
            messageLabel.text = nil
            hud.text = ""
            threatLabel.text = ""
            rightOSD.text = ""
            recDot.isHidden = true
            exitArrow.isHidden = true
            tapeArrow.isHidden = true
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
        recDot.isHidden = false

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
        hud.text = "REC   \(name)   \(clock)"
            + "\nTAPES  \(session.tapesThisFloor)/\(session.tapeGoal) HERE   \(session.tapesTotal) TOTAL"

        // Three readings, in order of how much trouble you are in. A sighting
        // gets no distance — knowing exactly how far away it is would defeat
        // the point of it standing there.
        if let d = session.hunterDistance {
            threatLabel.text = String(format: "⚠ IT IS COMING — %.0fM", d)
            threatLabel.textColor = UIColor(red: 1, green: 0.3, blue: 0.26, alpha: 1)
        } else if session.presence.state == .seen {
            threatLabel.text = "▚ CONTACT"
            threatLabel.textColor = UIColor(red: 1, green: 0.78, blue: 0.35, alpha: 1)
        } else {
            threatLabel.text = String(format: "SIGNAL ▸ %.0fS", max(0, session.nextHunt))
            threatLabel.textColor = UIColor(white: 0.62, alpha: 1)
        }

        // Right-hand OSD: where you are going, and (on SIMPLE) what you still
        // have to pick up before it is worth going there.
        var osd = ""
        if let exit = session.exit, let d = session.exitDistance {
            let word = session.isFinalFloor ? "EXIT" : "DESCEND"
            osd = String(format: "%@ ▸ %.0fM%@", word, d, exit.revealed ? "" : "  (UNFOUND)")
            exitArrow.isHidden = false
            exitArrow.transform = CGAffineTransform(
                rotationAngle: CGFloat(session.bearing(toX: exit.x, z: exit.z)))
        } else {
            exitArrow.isHidden = true
        }

        if session.difficulty.tapeHints, let near = session.nearestUnfoundTape {
            osd += String(format: "\nTAPE ▸ %.0fM", near.distance)
            tapeArrow.isHidden = false
            tapeArrow.transform = CGAffineTransform(
                rotationAngle: CGFloat(session.bearing(toX: near.tape.x, z: near.tape.z)))
        } else {
            tapeArrow.isHidden = true
        }
        rightOSD.text = osd

        let barW: CGFloat = 132
        vitalsFill.frame.size.width = barW * CGFloat(max(0, min(1, session.health / 100)))
        staminaFill.frame.size.width = barW * CGFloat(max(0, min(1, session.player.stamina / 100)))
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
