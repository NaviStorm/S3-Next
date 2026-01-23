import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: S3AppState
    @State private var showingAddKeyAlert = false
    @State private var showingImportKeyAlert = false
    @State private var newKeyAlias = ""
    @State private var importKeyAlias = ""
    @State private var importKeyBase64 = ""

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
                Text("Bucket")
            } footer: {
                Text(
                    "L'activation du versioning vous permet de préserver, récupérer et restaurer chaque version de chaque objet stocké dans votre bucket."
                )
            }

            Section("Chiffrement Client-Side (CSE)") {
                if appState.encryptionAliases.isEmpty {
                    Text("Aucune clé configurée.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.encryptionAliases, id: \.self) { alias in
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundColor(.orange)
                            Text(alias)
                            Spacer()

                            Button {
                                if let base64 = appState.exportKey(alias: alias) {
                                    #if os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(base64, forType: .string)
                                    #else
                                        UIPasteboard.general.string = base64
                                    #endif
                                    appState.showToast(
                                        "Clé '\(alias)' copiée (partage)", type: .success)
                                }
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.plain)
                            .help("Copier la clé pour la partager")

                            Button(role: .destructive) {
                                appState.deleteEncryptionKey(alias: alias)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button(action: {
                    showingAddKeyAlert = true
                }) {
                    Label("Générer une clé...", systemImage: "plus")
                }
                .alert("Nouvelle clé", isPresented: $showingAddKeyAlert) {
                    TextField("Alias de la clé", text: $newKeyAlias)
                    Button("Créer") {
                        if !newKeyAlias.isEmpty {
                            appState.createEncryptionKey(alias: newKeyAlias)
                            newKeyAlias = ""
                        }
                    }
                    Button("Annuler", role: .cancel) { newKeyAlias = "" }
                } message: {
                    Text(
                        "Entrez un alias pour générer une nouvelle clé AES-256 stockée localement dans votre Keychain."
                    )
                }

                Button(action: {
                    showingImportKeyAlert = true
                }) {
                    Label("Importer une clé...", systemImage: "square.and.arrow.down")
                }
                .alert("Importer une clé", isPresented: $showingImportKeyAlert) {
                    TextField("Alias de la clé", text: $importKeyAlias)
                    TextField("Clé Base64", text: $importKeyBase64)
                    Button("Importer") {
                        if !importKeyAlias.isEmpty && !importKeyBase64.isEmpty {
                            appState.importKey(alias: importKeyAlias, base64: importKeyBase64)
                            importKeyAlias = ""
                            importKeyBase64 = ""
                        }
                    }
                    Button("Annuler", role: .cancel) {
                        importKeyAlias = ""
                        importKeyBase64 = ""
                    }
                } message: {
                    Text("Collez ici l'alias et la clé en format Base64 reçus pour l'importation.")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(macOS)
            .frame(minWidth: 800, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
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
