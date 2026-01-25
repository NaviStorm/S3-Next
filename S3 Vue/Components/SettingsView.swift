import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appState: S3AppState
    #if os(macOS)
        @Environment(\.openWindow) var openWindow
    #endif
    @State private var showingAddKeyAlert = false
    @State private var showingImportKeyAlert = false
    @State private var showingAbout = false
    @State private var showingCreateBucketSheet = false
    @State private var newKeyAlias = ""
    @State private var importKeyAlias = ""
    @State private var importKeyBase64 = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Nom du Bucket", value: appState.bucket)
                LabeledContent("Région", value: appState.region)
                Button {
                    #if os(macOS)
                        openWindow(id: "create-bucket")
                    #else
                        showingCreateBucketSheet = true
                    #endif
                } label: {
                    Label("Créer un nouveau bucket", systemImage: "plus.circle")
                }
                #if os(iOS)
                    .sheet(isPresented: $showingCreateBucketSheet) {
                        CreateBucketView()
                        .environmentObject(appState)
                    }
                #endif
            } header: {
                Text("Configuration du Bucket")
            } footer: {
                if !appState.isLoggedIn {
                    Text("Connectez-vous pour créer un nouveau bucket.")
                        .foregroundColor(.orange)
                }
            }
            .disabled(!appState.isLoggedIn)

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
                if !appState.isLoggedIn {
                    Text("Connectez-vous pour gérer le versioning.")
                        .foregroundColor(.orange)
                } else {
                    Text(
                        "L'activation du versioning vous permet de préserver, récupérer et restaurer chaque version de chaque objet stocké dans votre bucket."
                    )
                }
            }
            .disabled(!appState.isLoggedIn)

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

            Section {
                NavigationLink {
                    MultipartCleanupView()
                        .environmentObject(appState)
                } label: {
                    Label("Nettoyer les transferts abandonnés", systemImage: "trash.badge.plus")
                }
            } header: {
                Text("Maintenance")
            } footer: {
                if !appState.isLoggedIn {
                    Text("Connectez-vous pour accéder aux outils de maintenance.")
                        .foregroundColor(.orange)
                }
            }
            .disabled(!appState.isLoggedIn)

            Section("À propos") {
                NavigationLink("Mentions Légales") {
                    MentionsLegalesView()
                }
                NavigationLink("Politique de confidentialité") {
                    PrivacyPolicyView()
                }

                #if os(iOS)
                    Button(action: {
                        showingAbout = true
                    }) {
                        HStack {
                            Label("À propos de S3 Next", systemImage: "info.circle")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                #endif

                Link(destination: URL(string: "https://github.com/NaviStorm/S3-Next.git")!) {
                    Label(
                        "Code source sur GitHub",
                        systemImage: "chevron.left.forwardslash.chevron.right"
                    )
                }

                HStack {
                    Spacer()
                    VStack(spacing: 4) {
                        Text("S3 Next")
                            .font(.system(size: 11, weight: .bold))
                        Text("Version \(appVersion) (Build \(appBuild))")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
        }
        .formStyle(.grouped)
        .padding()
        #if os(macOS)
            .frame(minWidth: 800, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        #endif
        .navigationTitle("Réglages")
        .sheet(isPresented: $showingAbout) {
            AboutView()
        }
        .task {
            appState.refreshVersioningStatus()
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(S3AppState())
    }
}
