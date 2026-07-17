import SwiftUI

struct GameContainerView: View {
    var body: some View {
        BackroomsWebView()
            .background(Color.black)
            .statusBarHidden()
    }
}

#Preview {
    GameContainerView()
}
