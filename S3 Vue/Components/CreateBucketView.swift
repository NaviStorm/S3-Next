import SwiftUI

struct CreateBucketView: View {
    @EnvironmentObject var appState: S3AppState
    @Environment(\.dismiss) var dismiss

    @State private var bucketName = ""
    @State private var isVersioningEnabled = false
    @State private var isObjectLockEnabled = false
    @State private var selectedACL = "private"
    @State private var isCreating = false

    let aclOptions = [
        ("Privé", "private"),
        ("Lecture publique", "public-read"),
    ]

    var body: some View {
        #if os(macOS)
            mainContent
        #else
            NavigationStack {
                mainContent
            }
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            Form {
                Section("Informations de base") {
                    TextField("Nom du bucket", text: $bucketName)
                        .autocorrectionDisabled()
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                        #endif
                        .onChange(of: bucketName) { _ in
                            if appState.bucketActionError != nil {
                                appState.bucketActionError = nil
                            }
                        }
                }

                if let error = appState.bucketActionError {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Erreur", systemImage: "exclamationmark.octagon.fill")
                                .font(.headline)
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Options S3") {
                    Toggle("Activer le Versioning", isOn: $isVersioningEnabled)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Activer l'Object Lock", isOn: $isObjectLockEnabled)

                        if isObjectLockEnabled {
                            Label(
                                "Attention : L'Object Lock est irréversible après la création.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                }

                Section("Accès (ACL)") {
                    Picker("Contrôle d'accès", selection: $selectedACL) {
                        ForEach(aclOptions, id: \.1) { option in
                            Text(option.0).tag(option.1)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            #if os(macOS)
                Divider()
                HStack {
                    Button("Annuler") {
                        #if os(macOS)
                            NSApp.stopModal()
                            NSApplication.shared.keyWindow?.close()
                        #else
                            dismiss()
                        #endif
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    if isCreating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Créer") {
                            createBucket()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bucketName.isEmpty)
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
            #endif
        }
        .navigationTitle("Nouveau Bucket")
        #if os(macOS)
            .frame(width: 400, height: 450)
        #endif
        #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isCreating {
                        ProgressView()
                        .controlSize(.small)
                    } else {
                        Button("Créer") {
                            createBucket()
                        }
                        .disabled(bucketName.isEmpty)
                    }
                }
            }
        #endif
        .onAppear {
            appState.bucketActionError = nil
            #if os(macOS)
                if let window = NSApplication.shared.keyWindow {
                    window.styleMask.remove(.resizable)
                    window.styleMask.remove(.miniaturizable)
                    window.title = "Création de bucket"
                    window.center()

                    // On lance le mode modal après un court délai pour laisser la fenêtre s'afficher
                    DispatchQueue.main.async {
                        NSApp.runModal(for: window)
                    }
                }
            #endif
        }
        #if os(macOS)
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            ) { notification in
                if let window = notification.object as? NSWindow,
                    window.identifier?.rawValue == "create-bucket"
                        || window.title == "Création de bucket"
                {
                    NSApp.stopModal()
                }
            }
        #endif
    }

    private func createBucket() {
        isCreating = true
        Task {
            await appState.createBucket(
                name: bucketName,
                objectLock: isObjectLockEnabled,
                versioning: isVersioningEnabled,
                acl: selectedACL
            )
            await MainActor.run {
                isCreating = false
                if appState.bucketActionError == nil {
                    #if os(macOS)
                        NSApp.stopModal()
                        NSApplication.shared.keyWindow?.close()
                    #else
                        dismiss()
                    #endif
                }
            }
        }
    }
}

struct CreateBucketView_Previews: PreviewProvider {
    static var previews: some View {
        CreateBucketView()
            .environmentObject(S3AppState())
    }
}
