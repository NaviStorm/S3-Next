import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        Form {
            Section("Bucket Configuration") {
                LabeledContent("Bucket Name", value: appState.bucket)
                LabeledContent("Region", value: appState.region)
                LabeledContent("Endpoint", value: appState.endpoint)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("S3 Versioning")
                            .font(.headline)
                        Text("Manage object versions for this bucket.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { appState.isVersioningEnabled ?? false },
                                set: { _ in appState.toggleVersioning() }
                            )
                        )
                        .toggleStyle(.switch)
                        .disabled(appState.isVersioningEnabled == nil)
                    }
                }

                if appState.isVersioningEnabled == nil {
                    Text("Could not determine versioning status.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Management")
            } footer: {
                Text(
                    "Enabling versioning allows you to preserve, retrieve, and restore every version of every object stored in your bucket."
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(macOS)
            .frame(width: 450, height: 350)
        #endif
        .navigationTitle("Settings")
        .task {
            appState.refreshVersioningStatus()
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(S3AppState())
    }
}
