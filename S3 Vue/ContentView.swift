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
        .frame(minWidth: 600, minHeight: 400)
    }
}
