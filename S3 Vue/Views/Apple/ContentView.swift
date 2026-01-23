import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        Group {
            if appState.isLoggedIn {
                FileBrowserView()
            } else {
                LoginView()
            }
        }
        .overlay(
            ToastView(message: $appState.toastMessage, type: appState.toastType)
        )
        #if os(macOS)
            .frame(minWidth: 600, minHeight: 400)
        #endif
    }
}
