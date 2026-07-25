import GameKit

/// Game Center integration for the shipping shell.
///
/// The web game already knows when a run ends and how it went; this turns
/// those moments into leaderboard scores and achievements. Everything is
/// best-effort: Game Center is optional, so a player who declines sign-in
/// (or is offline) plays exactly as before and never sees an error.
///
/// The identifiers below must also be created in App Store Connect before
/// they do anything on a real device — see ios/README.md.
enum GameCenterID {
    /// Fastest full escape, in hundredths of a second (lower is better).
    static let escapeTimeLeaderboard = "com.backrooms.escape.fastest"
    /// Deepest floor reached across all runs.
    static let depthLeaderboard = "com.backrooms.depth.deepest"

    static let firstDescent = "com.backrooms.achievement.firstdescent"
    static let reachedPoolrooms = "com.backrooms.achievement.poolrooms"
    static let escaped = "com.backrooms.achievement.escaped"
    static let allTapes = "com.backrooms.achievement.alltapes"
    static let noDeaths = "com.backrooms.achievement.nodeaths"
}

final class GameCenter {
    static let shared = GameCenter()
    private(set) var authenticated = false

    /// Presents Apple's sign-in flow if needed. Safe to call once at launch;
    /// declining simply leaves `authenticated` false.
    func authenticate(presenter: @escaping (UIViewController) -> Void) {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            if let viewController {
                presenter(viewController)          // player needs to sign in
                return
            }
            self?.authenticated = (error == nil) && GKLocalPlayer.local.isAuthenticated
        }
    }

    // MARK: - Reporting

    /// A completed escape: submits the run time and unlocks the endgame
    /// achievements the run earned.
    func reportEscape(seconds: Double, tapes: Int, deaths: Int) {
        guard authenticated else { return }
        submit(Int(seconds * 100), to: GameCenterID.escapeTimeLeaderboard)
        unlock(GameCenterID.escaped)
        if tapes >= 8 { unlock(GameCenterID.allTapes) }
        if deaths == 0 { unlock(GameCenterID.noDeaths) }
    }

    /// Reaching a new floor. Level indices match the web build: 0 is the
    /// Lobby, 3 is Level 37 (the Poolrooms).
    func reportDepth(level: Int) {
        guard authenticated else { return }
        submit(level, to: GameCenterID.depthLeaderboard)
        if level >= 1 { unlock(GameCenterID.firstDescent) }
        if level >= 3 { unlock(GameCenterID.reachedPoolrooms) }
    }

    // MARK: - Plumbing

    private func submit(_ value: Int, to id: String) {
        GKLeaderboard.submitScore(value, context: 0, player: GKLocalPlayer.local,
                                  leaderboardIDs: [id]) { _ in }
    }

    private func unlock(_ id: String, percent: Double = 100) {
        let achievement = GKAchievement(identifier: id)
        achievement.percentComplete = percent
        achievement.showsCompletionBanner = true
        GKAchievement.report([achievement]) { _ in }
    }

    /// The standard Game Center dashboard, for a future "leaderboards" button.
    func presentDashboard(from viewController: UIViewController) {
        guard authenticated else { return }
        let vc = GKGameCenterViewController(state: .leaderboards)
        vc.gameCenterDelegate = DashboardDismisser.shared
        viewController.present(vc, animated: true)
    }
}

/// Game Center's dashboard requires a delegate purely to dismiss itself.
private final class DashboardDismisser: NSObject, GKGameCenterControllerDelegate {
    static let shared = DashboardDismisser()
    func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
        gameCenterViewController.dismiss(animated: true)
    }
}
