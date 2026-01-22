import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: S3AppState

    var body: some View {
        VStack(spacing: 20) {
            Text("Configuration du S3 Viewer")
                .font(.largeTitle)
                .padding(.bottom, 20)

            Form {
                Section(header: Text("Identifiants")) {
                    TextField("ID de Clé d'accès", text: $appState.accessKey)
                    SecureField("Clé d'accès Secrète", text: $appState.secretKey)
                }

                Section(header: Text("Configuration du Bucket")) {
                    TextField("Nom du Bucket", text: $appState.bucket)
                    TextField("Région (ex: us-east-1)", text: $appState.region)
                    TextField("URL de l'Endpoint (Optionnel)", text: $appState.endpoint)
                    if !appState.endpoint.isEmpty {
                        Toggle(
                            "Forcer le Path Style (ex: endpoint/bucket)",
                            isOn: $appState.usePathStyle)
                    }
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
                .frame(maxWidth: 400)
            #endif

            #if os(iOS)
                Button("Afficher les logs de débogage") {
                    // ...
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
                appState.log("=== [UI] Bouton Connexion cliqué ===")
                Task {
                    await appState.connect()
                }
            }) {
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Se connecter")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isLoading)
        }

        .padding()
    }
}
