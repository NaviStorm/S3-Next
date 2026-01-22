import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        Form {
            Section("Configuration du Bucket") {
                LabeledContent("Nom du Bucket", value: appState.bucket)
                LabeledContent("Région", value: appState.region)
                LabeledContent("Endpoint", value: appState.endpoint)
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Versioning S3")
                            .font(.headline)
                        Text("Gérer les versions des objets pour ce bucket.")
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
                    Text("Impossible de déterminer le statut du versioning.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            } header: {
                Text("Gestion")
            } footer: {
                Text(
                    "L'activation du versioning vous permet de préserver, récupérer et restaurer chaque version de chaque objet stocké dans votre bucket."
                )
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(macOS)
            .frame(width: 450, height: 350)
        #endif
        .navigationTitle("Réglages")
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
