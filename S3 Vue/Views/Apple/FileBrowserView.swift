import SwiftUI

struct FileBrowserView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        #if os(macOS)
            FileBrowserView_Mac()
        #else
            FileBrowserView_iOS()
        #endif
    }
}
