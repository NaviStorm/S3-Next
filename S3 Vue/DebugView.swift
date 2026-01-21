import SwiftUI

struct DebugView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        VStack(spacing: 0) {
            Text("DEBUG MODE ACTIVE")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .background(Color.blue)

            ScrollView {
                Text(appState.debugMessage.isEmpty ? "Waiting for logs..." : appState.debugMessage)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .background(Color.blue.opacity(0.1))
        }
    }
}
