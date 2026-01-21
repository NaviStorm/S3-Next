import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        VStack(spacing: 20) {
            Text("S3 Viewer Setup")
                .font(.largeTitle)
                .padding(.bottom, 20)

            Form {
                Section(header: Text("Credentials")) {
                    TextField("Access Key ID", text: $appState.accessKey)
                    SecureField("Secret Access Key", text: $appState.secretKey)
                }

                Section(header: Text("Bucket Configuration")) {
                    TextField("Bucket Name", text: $appState.bucket)
                    TextField("Region (e.g. us-east-1)", text: $appState.region)
                    TextField("Endpoint URL (Optional)", text: $appState.endpoint)
                    if !appState.endpoint.isEmpty {
                        Toggle(
                            "Force Path Style (e.g. endpoint/bucket)", isOn: $appState.usePathStyle)
                    }
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
                .frame(maxWidth: 400)
            #endif

            #if os(iOS)
                Button("Show Debug Logs") {
                    // Modifying state here requiring new State property or just toggle?
                    // Simplest is to assume DebugView can be presented.
                    // But LoginView doesn't have a sheet state.
                    // Let's add one.
                }
                .buttonStyle(.borderless)
                .padding(.top)
            #endif

            if let error = appState.errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            Button(action: {
                appState.log("=== [UI] Connect Button Clicked ===")
                Task {
                    await appState.connect()
                }
            }) {
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isLoading)
        }

        .padding()
    }
}
