import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    struct FileBrowserView_iOS: View {
        @EnvironmentObject var appState: S3AppState

        // Alert States
        @State private var showingCreateFolder = false
        @State private var newFolderName = ""
        @State private var showingFileImporter = false
        @State private var showingVersions = false
        @State private var showingSettings = false
        @State private var selectedVerObject: S3Object? = nil

        @State private var showingRename = false
        @State private var renameItemKey = ""
        @State private var renameItemName = ""
        @State private var renameIsFolder = false

        @State private var showingDelete = false
        @State private var deleteItemKey = ""
        @State private var deleteIsFolder = false

        @State private var selectedItemForInfo: S3Object?
        @State private var infoFolderStats: (count: Int, size: Int64)?
        @State private var isInfoStatsLoading = false

        var body: some View {
            NavigationStack {
                ZStack {
                    if appState.isLoading {
                        ProgressView("Chargement...")
                    } else if let error = appState.errorMessage {
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.yellow)
                            Text(error)
                                .multilineTextAlignment(.center)
                            Button("Réessayer") { appState.loadObjects() }
                                .buttonStyle(.bordered)
                        }
                        .padding()
                    } else if appState.objects.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("Aucun élément trouvé")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        List {
                            Section(footer: Text(appState.formattedStats)) {
                                ForEach(appState.objects) { object in
                                    HStack {
                                        Image(systemName: object.isFolder ? "folder.fill" : "doc")
                                            .foregroundColor(object.isFolder ? .blue : .secondary)
                                            .font(.title3)

                                        VStack(alignment: .leading) {
                                            Text(displayName(for: object.key))
                                                .font(.headline)
                                                .lineLimit(1)

                                            HStack {
                                                if !object.isFolder {
                                                    Text(formatBytes(object.size))
                                                    Text("•")
                                                    Text(
                                                        object.lastModified.formatted(
                                                            date: .abbreviated, time: .shortened))
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        }

                                        Spacer()

                                        if object.isFolder {
                                            Image(systemName: "chevron.right")
                                                .foregroundColor(.gray)
                                                .font(.caption)
                                        }
                                    }
                                    .contentShape(Rectangle())  // Make entire row tappable
                                    .onTapGesture {
                                        if object.key == ".." {
                                            appState.navigateBack()
                                        } else if object.isFolder {
                                            appState.navigateTo(
                                                folder: displayName(for: object.key))
                                        } else {
                                            // Show actions for file? Or just download?
                                            // For now, maybe just log, or trigger download
                                            appState.log("Selection file: \(object.key)")
                                        }
                                    }
                                    .contextMenu {
                                        Button(action: {
                                            selectedItemForInfo = object
                                        }) {
                                            Label("Information", systemImage: "info.circle")
                                        }

                                        Button(action: {
                                            renameItemKey = object.key
                                            renameItemName = displayName(for: object.key)
                                            renameIsFolder = object.isFolder
                                            showingRename = true
                                        }) {
                                            Label("Renommer", systemImage: "pencil")
                                        }

                                        if !object.isFolder {
                                            Button(action: {
                                                appState.downloadFile(key: object.key)
                                            }) {
                                                Label(
                                                    "Télécharger", systemImage: "arrow.down.circle")
                                            }

                                            Button(action: {
                                                selectedVerObject = object
                                                appState.loadVersions(for: object.key)
                                                showingVersions = true
                                            }) {
                                                Label(
                                                    "Versions",
                                                    systemImage: "clock.arrow.circlepath")
                                            }

                                            Menu {
                                                Button(action: {
                                                    appState.copyPresignedURL(
                                                        for: object.key, expires: 3600)
                                                }) {
                                                    Label("Valide 1 heure", systemImage: "timer")
                                                }
                                                Button(action: {
                                                    appState.copyPresignedURL(
                                                        for: object.key, expires: 86400)
                                                }) {
                                                    Label(
                                                        "Valide 24 heures", systemImage: "calendar")
                                                }
                                            } label: {
                                                Label("Lien de partage", systemImage: "link")
                                            }
                                        }

                                        Button(
                                            role: .destructive,
                                            action: {
                                                deleteItemKey = object.key
                                                deleteIsFolder = object.isFolder
                                                showingDelete = true
                                            }
                                        ) {
                                            Label("Supprimer", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .refreshable {
                            appState.loadObjects()
                        }
                    }
                }
                .navigationTitle(appState.currentPath.last ?? appState.bucket)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .alert("Nouveau Dossier", isPresented: $showingCreateFolder) {
                    TextField("Nom du dossier", text: $newFolderName)
                    Button("Créer") {
                        if !newFolderName.isEmpty {
                            appState.createFolder(name: newFolderName)
                            newFolderName = ""
                        }
                    }
                    Button("Annuler", role: .cancel) { newFolderName = "" }
                }
                .alert("Renommer", isPresented: $showingRename) {
                    TextField("Nouveau Nom", text: $renameItemName)
                    Button("Renommer") {
                        if !renameItemName.isEmpty {
                            appState.renameObject(
                                oldKey: renameItemKey, newName: renameItemName,
                                isFolder: renameIsFolder)
                            renameItemName = ""
                        }
                    }
                    Button("Annuler", role: .cancel) { renameItemName = "" }
                }
                .fileImporter(
                    isPresented: $showingFileImporter,
                    allowedContentTypes: [.data],
                    allowsMultipleSelection: true
                ) { result in
                    switch result {
                    case .success(let urls):
                        for url in urls {
                            appState.uploadFile(url: url)
                        }
                    case .failure(let error):
                        appState.showToast(
                            "File selection failed: \(error.localizedDescription)", type: .error)
                    }
                }
                .alert("Supprimer", isPresented: $showingDelete) {
                    Button("Supprimer", role: .destructive) {
                        if deleteIsFolder {
                            appState.deleteFolder(key: deleteItemKey)
                        } else {
                            appState.deleteObject(key: deleteItemKey)
                        }
                    }
                    Button("Annuler", role: .cancel) {}
                } message: {
                    Text(
                        deleteIsFolder
                            ? "Êtes-vous sûr de vouloir supprimer ce dossier et tout son contenu ?"
                            : "Êtes-vous sûr de vouloir supprimer ce fichier ?")
                }
                .sheet(
                    isPresented: Binding(
                        get: { appState.pendingDownloadURL != nil },
                        set: { if !$0 { appState.pendingDownloadURL = nil } }
                    )
                ) {
                    if let url = appState.pendingDownloadURL {
                        ActivityView(activityItems: [url])
                    }
                }
                .sheet(isPresented: $showingVersions) {
                    NavigationStack {
                        VStack {
                            if appState.isVersionsLoading {
                                ProgressView("Chargement des versions...")
                            } else {
                                List(appState.selectedObjectVersions) { version in
                                    VStack(alignment: .leading) {
                                        HStack {
                                            VStack(alignment: .leading) {
                                                Text(version.lastModified.formatted())
                                                    .fontWeight(version.isLatest ? .bold : .regular)
                                                if !version.isDeleteMarker {
                                                    Text(formatBytes(version.size))
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                } else {
                                                    Text("Marqueur de suppression")
                                                        .font(.caption)
                                                        .foregroundColor(.red)
                                                }
                                            }

                                            Spacer()

                                            if version.isLatest {
                                                Text("Dernière")
                                                    .font(.caption2)
                                                    .padding(4)
                                                    .background(Color.green.opacity(0.1))
                                                    .foregroundColor(.green)
                                                    .cornerRadius(4)
                                            }

                                            if !version.isDeleteMarker {
                                                Button {
                                                    appState.downloadFile(
                                                        key: version.key,
                                                        versionId: version.versionId)
                                                } label: {
                                                    Image(systemName: "arrow.down.circle")
                                                }
                                            }
                                        }
                                    }

                                    Divider()

                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("Partage temporaire")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)

                                        HStack {
                                            Button("Lien 1h") {
                                                appState.copyPresignedURL(
                                                    for: version.key, expires: 3600)
                                            }
                                            .buttonStyle(.bordered)

                                            Button("Lien 24h") {
                                                appState.copyPresignedURL(
                                                    for: version.key, expires: 86400)
                                            }
                                            .buttonStyle(.bordered)
                                        }
                                    }
                                }
                            }
                        }
                        .navigationTitle("Versions")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Terminé") { showingVersions = false }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView()
                            .environmentObject(appState)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Terminé") { showingSettings = false }
                                }
                            }
                    }
                }
                .sheet(item: $selectedItemForInfo) { object in
                    infoSheet(for: object)
                }
            }
        }

        @ToolbarContentBuilder
        private var toolbarContent: some ToolbarContent {
            ToolbarItem(placement: .navigationBarLeading) {
                if !appState.currentPath.isEmpty {
                    Button(action: {
                        appState.navigateBack()
                    }) {
                        Image(systemName: "chevron.left")
                        Text("Retour")
                    }
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                HStack {
                    Menu {
                        Picker("Trier par", selection: $appState.sortOption) {
                            ForEach(S3AppState.SortOption.allCases) { option in
                                Text(
                                    option == .name
                                        ? "Nom" : (option == .date ? "Date" : "Taille")
                                ).tag(option)
                            }
                        }
                        Divider()
                        Toggle("Ascendant", isOn: $appState.sortAscending)
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }

                    Button(action: { showingCreateFolder = true }) {
                        Image(systemName: "folder.badge.plus")
                    }

                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gear")
                    }

                    Button(action: { showingFileImporter = true }) {
                        Image(systemName: "arrow.up.doc")
                    }

                    Button(action: {
                        appState.disconnect()
                    }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }

        @ViewBuilder
        private func infoSheet(for object: S3Object) -> some View {
            NavigationStack {
                List {
                    Section("Propriétés") {
                        LabeledContent("Nom", value: displayName(for: object.key))
                        LabeledContent("Clé", value: object.key)
                        if !object.isFolder {
                            LabeledContent("Taille", value: formatBytes(object.size))
                            LabeledContent(
                                "Dernière modification",
                                value: object.lastModified.formatted())

                            Divider()

                            HStack {
                                Text("Accès")
                                Spacer()
                                if appState.isACLLoading {
                                    ProgressView()
                                } else if let isPublic = appState.selectedObjectIsPublic {
                                    HStack {
                                        Image(systemName: isPublic ? "globe" : "lock.fill")
                                            .foregroundColor(isPublic ? .green : .secondary)
                                        Text(isPublic ? "Public" : "Privé")

                                        Button(action: {
                                            appState.togglePublicAccess(for: object.key)
                                        }) {
                                            Text("Modifier")
                                                .font(.caption)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.1))
                                                .cornerRadius(8)
                                        }
                                    }
                                }
                            }

                            Divider()

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Partage temporaire")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Button("Lien 1h") {
                                        appState.copyPresignedURL(
                                            for: object.key, expires: 3600)
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Lien 24h") {
                                        appState.copyPresignedURL(
                                            for: object.key, expires: 86400)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        } else {
                            LabeledContent("Type", value: "Dossier")
                            if isInfoStatsLoading {
                                HStack {
                                    Text("Calcul des stats...")
                                        .foregroundColor(.secondary)
                                    ProgressView()
                                }
                            } else if let stats = infoFolderStats {
                                LabeledContent("Objets", value: "\(stats.count)")
                                LabeledContent(
                                    "Taille totale", value: formatBytes(stats.size))
                            }
                        }
                    }
                }
                .navigationTitle("Détails")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Terminé") { selectedItemForInfo = nil }
                    }
                }
                .task {
                    if object.isFolder {
                        isInfoStatsLoading = true
                        infoFolderStats = nil
                        infoFolderStats = await appState.calculateFolderStats(
                            folderKey: object.key)
                        isInfoStatsLoading = false
                    } else {
                        appState.loadACL(for: object.key)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        func displayName(for key: String) -> String {
            // Remove prefix of current path to show only filename/foldername
            let prefix = appState.currentPath.joined(separator: "/")

            var name = key
            let fullPrefix = prefix.isEmpty ? "" : prefix + "/"
            if !prefix.isEmpty, name.hasPrefix(fullPrefix) {
                name = String(name.dropFirst(fullPrefix.count))
            }

            // Remove trailing slash for display if folder
            if name.hasSuffix("/") {
                name = String(name.dropLast())
            }

            return name
        }

        func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }

    struct ActivityView: UIViewControllerRepresentable {
        let activityItems: [Any]
        let applicationActivities: [UIActivity]? = nil

        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(
                activityItems: activityItems, applicationActivities: applicationActivities)
        }

        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context)
        {}
    }
#endif
