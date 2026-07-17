import SwiftUI

struct GameContainerView: View {
    var body: some View {
        BackroomsWebView()
            .background(Color.black)
            .statusBarHidden()
            .persistentSystemOverlays(.hidden)   // fade the home indicator
            .defersSystemGestures(on: .all)      // first edge swipe goes to the game
    }
}

#Preview {
    GameContainerView()
}
