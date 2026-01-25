import SwiftUI

struct LoginView: View {
    @EnvironmentObject var appState: S3AppState
    @State private var newSiteName = ""

    var body: some View {
        VStack(spacing: 20) {
            Text("Configuration du S3 Viewer")
                .font(.largeTitle)
                .bold()
                .padding(.top, 20)

            Form {
                Section {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundColor(.blue)
                        Picker("Site", selection: $appState.selectedSiteId) {
                            Text("Nouveau site...").tag(UUID?.none)
                            Divider()
                            ForEach(appState.savedSites) { site in
                                Text(site.name).tag(site.id as UUID?)
                            }
                        }
                        .pickerStyle(.menu)

                        if let siteId = appState.selectedSiteId {
                            Button(role: .destructive) {
                                if let index = appState.savedSites.firstIndex(where: {
                                    $0.id == siteId
                                }) {
                                    appState.deleteSite(at: IndexSet(integer: index))
                                    appState.selectedSiteId = nil
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onChange(of: appState.selectedSiteId) { newValue in
                        if let siteId = newValue,
                            let site = appState.savedSites.first(where: { $0.id == siteId })
                        {
                            newSiteName = site.name
                        } else {
                            newSiteName = ""
                            appState.clearFields()
                        }
                    }

                    HStack {
                        TextField("Nom du site", text: $newSiteName)
                            .textFieldStyle(.roundedBorder)

                        if !newSiteName.isEmpty {
                            Button("Enregistrer") {
                                appState.saveCurrentAsSite(named: newSiteName)
                            }
                            #if os(macOS)
                                .buttonStyle(.bordered)
                            #else
                                .buttonStyle(.plain)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(4)
                            #endif
                        }
                    }
                } header: {
                    Text("Site")
                }

                Section {
                    TextField("ID de Clé d'accès", text: $appState.accessKey)
                    SecureField("Clé d'accès Secrète", text: $appState.secretKey)
                } header: {
                    Text("Identifiants")
                }

                Section {
                    TextField("Nom du Bucket", text: $appState.bucket)
                    TextField("Région (ex: us-east-1)", text: $appState.region)
                    TextField("URL de l'Endpoint", text: $appState.endpoint)

                    Toggle("Utiliser le Path Style", isOn: $appState.usePathStyle)
                        .tint(.blue)
                } header: {
                    Text("Configuration S3")
                } footer: {
                    Text(
                        "Le Path Style est nécessaire pour certains fournisseurs S3 (ex: MinIO, Scaleway)."
                    )
                    .font(.caption2)
                }
            }
            .formStyle(.grouped)
            #if os(macOS)
                .frame(maxWidth: 500)
            #endif

            if let error = appState.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                }
                .foregroundColor(.red)
                .font(.caption)
                .padding(.horizontal)
            }

            Button(action: {
                appState.log("=== [UI] Bouton Connexion cliqué ===")
                Task {
                    await appState.connect()
                }
            }) {
                HStack {
                    if appState.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 8)
                    }
                    Text(appState.isLoading ? "Connexion..." : "Se connecter")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.isLoading)
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
    }
}
