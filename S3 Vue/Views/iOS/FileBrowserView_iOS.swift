import QuickLook
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    struct FileBrowserView_iOS: View {
        @EnvironmentObject var appState: S3AppState

        // Alert States
        @State private var showingCreateFolder = false
        @State private var newFolderName = ""
        @State private var showingFileImporter = false
        @State private var showingFolderImporter = false
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

        @State private var showingTransfers = false

        @State private var selectedItemForInfo: S3Object?
        @State private var infoFolderStats: (count: Int, size: Int64)?
        @State private var isInfoStatsLoading = false

        var body: some View {
            NavigationStack {
                ZStack {
                    if appState.isLoading {
                        ProgressView("Chargement...")
                    } else if let error = appState.errorMessage {
                        errorView(error)
                    } else if appState.objects.isEmpty {
                        emptyView
                    } else {
                        listContent
                    }
                }
                .navigationTitle(appState.currentPath.last ?? appState.bucket)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .modifier(
                    AlertsAndSheets(
                        showingCreateFolder: $showingCreateFolder,
                        newFolderName: $newFolderName,
                        showingRename: $showingRename,
                        renameItemKey: $renameItemKey,
                        renameItemName: $renameItemName,
                        renameIsFolder: $renameIsFolder,
                        showingFileImporter: $showingFileImporter,
                        showingFolderImporter: $showingFolderImporter,
                        showingDelete: $showingDelete,
                        deleteItemKey: $deleteItemKey,
                        deleteIsFolder: $deleteIsFolder,
                        showingVersions: $showingVersions,
                        showingSettings: $showingSettings,
                        showingTransfers: $showingTransfers,
                        selectedItemForInfo: $selectedItemForInfo,
                        appState: appState,
                        selectedVerObject: $selectedVerObject,
                        infoSheet: { obj in infoSheet(for: obj) }
                    )
                )
                .fileImporter(
                    isPresented: $showingFileImporter, allowedContentTypes: [.item],
                    allowsMultipleSelection: true
                ) { result in
                    if case .success(let urls) = result {
                        for url in urls {
                            appState.log("[FilePicker] Picked: \(url.lastPathComponent)")
                            appState.uploadFile(url: url)
                        }
                    }
                }
                .background(
                    Color.clear
                        .fileImporter(
                            isPresented: $showingFolderImporter, allowedContentTypes: [.folder],
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                appState.log("[FolderPicker] Picked: \(url.path)")
                                appState.uploadFolder(url: url)
                            }
                        }
                )
            }
        }

        @ViewBuilder
        private var listContent: some View {
            List {
                Section(footer: Text(appState.formattedStats)) {
                    ForEach(appState.objects) { object in
                        fileRow(for: object)
                    }
                }
            }
            .refreshable {
                appState.loadObjects()
            }
        }

        @ViewBuilder
        private func fileRow(for object: S3Object) -> some View {
            HStack {
                Image(systemName: object.isFolder ? "folder.fill" : "doc")
                    .foregroundColor(object.isFolder ? .blue : .secondary)
                    .font(.title3)

                VStack(alignment: .leading) {
                    Text(displayName(for: object.key))
                        .font(.headline)
                        .lineLimit(1)

                    if !object.isFolder {
                        HStack {
                            Text(formatBytes(object.size))
                            Text("•")
                            Text(
                                object.lastModified.formatted(date: .abbreviated, time: .shortened))
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if object.isFolder {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.gray)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if object.key == ".." {
                    appState.navigateBack()
                } else if object.isFolder {
                    appState.navigateTo(folder: displayName(for: object.key))
                } else {
                    appState.log("Selection file: \(object.key)")
                }
            }
            .contextMenu {
                fileContextMenu(for: object)
            }
        }

        @ViewBuilder
        private func fileContextMenu(for object: S3Object) -> some View {
            Button(action: { selectedItemForInfo = object }) {
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
                Button(action: { appState.previewFile(key: object.key) }) {
                    Label("Aperçu rapide", systemImage: "eye")
                }

                Button(action: { appState.downloadFile(key: object.key) }) {
                    Label("Télécharger", systemImage: "arrow.down.circle")
                }

                Button(action: {
                    selectedVerObject = object
                    appState.loadVersions(for: object.key)
                    showingVersions = true
                }) {
                    Label("Versions", systemImage: "clock.arrow.circlepath")
                }

                Menu {
                    Button(action: { appState.copyPresignedURL(for: object.key, expires: 3600) }) {
                        Label("Valide 1 heure", systemImage: "timer")
                    }
                    Button(action: { appState.copyPresignedURL(for: object.key, expires: 86400) }) {
                        Label("Valide 24 heures", systemImage: "calendar")
                    }
                } label: {
                    Label("Lien de partage", systemImage: "link")
                }
            } else {
                Button(action: { appState.downloadFolder(key: object.key) }) {
                    Label("Télécharger le dossier", systemImage: "arrow.down.circle")
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

        @ToolbarContentBuilder
        private var toolbarContent: some ToolbarContent {
            ToolbarItem(placement: .navigationBarLeading) {
                if !appState.currentPath.isEmpty {
                    Button(action: { appState.navigateBack() }) {
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
                                    option == .name ? "Nom" : (option == .date ? "Date" : "Taille")
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

                    Menu {
                        Section("Sélection de la clé (Sticky)") {
                            Button(action: {
                                appState.selectedEncryptionAlias = nil
                            }) {
                                HStack {
                                    Label(
                                        "Sans chiffrement",
                                        systemImage: appState.selectedEncryptionAlias == nil
                                            ? "checkmark" : "unlock")
                                }
                            }

                            ForEach(appState.encryptionAliases, id: \.self) { alias in
                                Button(action: {
                                    appState.selectedEncryptionAlias = alias
                                }) {
                                    Label(
                                        alias,
                                        systemImage: appState.selectedEncryptionAlias == alias
                                            ? "checkmark" : "key.fill")
                                }
                            }
                        }

                        Section("Actions d'upload") {
                            Button(action: {
                                showingFileImporter = true
                            }) {
                                Label("Fichiers", systemImage: "doc.badge.plus")
                            }
                            Button(action: {
                                showingFolderImporter = true
                            }) {
                                Label("Dossier", systemImage: "folder.badge.plus")
                            }
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(systemName: "plus.app")
                            if appState.selectedEncryptionAlias != nil {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 8))
                                    .foregroundColor(.orange)
                                    .offset(x: 2, y: 2)
                            }
                        }
                    }

                    Button(action: { showingTransfers = true }) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "arrow.up.arrow.down.circle")
                            if appState.transferManager.transferTasks.contains(where: {
                                $0.status == .inProgress
                            }) {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 8, height: 8)
                                    .offset(x: 2, y: -2)
                            }
                        }
                    }

                    Button(action: { appState.disconnect() }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }

        @ViewBuilder
        private func errorView(_ error: String) -> some View {
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundColor(
                    .yellow)
                Text(error).multilineTextAlignment(.center)
                Button("Réessayer") { appState.loadObjects() }.buttonStyle(.bordered)
            }
            .padding()
        }

        private var emptyView: some View {
            VStack(spacing: 20) {
                Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundColor(
                    .secondary)
                Text("Aucun élément trouvé").font(.headline).foregroundColor(.secondary)
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
                                "Dernière modification", value: object.lastModified.formatted())

                            if appState.isMetadataLoading {
                                ProgressView().padding(.top, 4)
                            } else if let alias = appState.selectedObjectMetadata[
                                "x-amz-meta-cse-key-alias"]
                            {
                                LabeledContent("Chiffrement (CSE)", value: alias)
                                    .foregroundColor(.orange)
                            }

                            Divider()
                            accessSection(for: object)
                            Divider()
                            sharingSection(for: object)
                        } else {
                            LabeledContent("Type", value: "Dossier")
                            folderStatsSection(for: object)
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
                        infoFolderStats = await appState.calculateFolderStats(folderKey: object.key)
                        isInfoStatsLoading = false
                    } else {
                        appState.loadACL(for: object.key)
                        appState.loadMetadata(for: object.key)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }

        @ViewBuilder
        private func accessSection(for object: S3Object) -> some View {
            HStack {
                Text("Accès")
                Spacer()
                if appState.isACLLoading {
                    ProgressView()
                } else if let isPublic = appState.selectedObjectIsPublic {
                    HStack {
                        Image(systemName: isPublic ? "globe" : "lock.fill").foregroundColor(
                            isPublic ? .green : .secondary)
                        Text(isPublic ? "Public" : "Privé")
                        Button("Modifier") { appState.togglePublicAccess(for: object.key) }
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.blue.opacity(0.1)).cornerRadius(8)
                    }
                }
            }
        }

        @ViewBuilder
        private func sharingSection(for object: S3Object) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Partage temporaire").font(.subheadline).foregroundColor(.secondary)
                HStack {
                    Button("Lien 1h") { appState.copyPresignedURL(for: object.key, expires: 3600) }
                        .buttonStyle(.bordered)
                    Button("Lien 24h") {
                        appState.copyPresignedURL(for: object.key, expires: 86400)
                    }.buttonStyle(.bordered)
                }
            }
        }

        @ViewBuilder
        private func folderStatsSection(for object: S3Object) -> some View {
            if isInfoStatsLoading {
                HStack {
                    Text("Calcul des stats...").foregroundColor(.secondary)
                    ProgressView()
                }
            } else if let stats = infoFolderStats {
                LabeledContent("Objets", value: "\(stats.count)")
                LabeledContent("Taille totale", value: formatBytes(stats.size))
            }
        }

        func displayName(for key: String) -> String {
            let prefix = appState.currentPath.joined(separator: "/")
            var name = key
            let fullPrefix = prefix.isEmpty ? "" : prefix + "/"
            if !prefix.isEmpty, name.hasPrefix(fullPrefix) {
                name = String(name.dropFirst(fullPrefix.count))
            }
            if name.hasSuffix("/") { name = String(name.dropLast()) }
            return name
        }

        func formatBytes(_ bytes: Int64) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useAll]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: bytes)
        }
    }

    struct AlertsAndSheets: ViewModifier {
        @Binding var showingCreateFolder: Bool
        @Binding var newFolderName: String
        @Binding var showingRename: Bool
        @Binding var renameItemKey: String
        @Binding var renameItemName: String
        @Binding var renameIsFolder: Bool
        @Binding var showingFileImporter: Bool
        @Binding var showingFolderImporter: Bool
        @Binding var showingDelete: Bool
        @Binding var deleteItemKey: String
        @Binding var deleteIsFolder: Bool
        @Binding var showingVersions: Bool
        @Binding var showingSettings: Bool
        @Binding var showingTransfers: Bool
        @Binding var selectedItemForInfo: S3Object?
        @ObservedObject var appState: S3AppState
        @Binding var selectedVerObject: S3Object?
        let infoSheet: (S3Object) -> any View

        func body(content: Content) -> some View {
            content
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
                        set: { if !$0 { appState.pendingDownloadURL = nil } })
                ) {
                    if let url = appState.pendingDownloadURL { ActivityView(activityItems: [url]) }
                }
                .sheet(isPresented: $showingVersions) {
                    NavigationStack {
                        VStack {
                            if appState.isVersionsLoading {
                                ProgressView("Chargement des versions...")
                            } else {
                                List(appState.selectedObjectVersions) { version in
                                    VersionRow(version: version, appState: appState)
                                }
                            }
                        }
                        .navigationTitle("Versions").navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Terminé") { showingVersions = false }
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                    .quickLookPreview($appState.quickLookURL)
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack {
                        SettingsView().environmentObject(appState)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Terminé") { showingSettings = false }
                                }
                            }
                    }
                }
                .sheet(isPresented: $showingTransfers) {
                    NavigationStack {
                        TransferProgressView().environmentObject(appState)
                            .navigationTitle("Transferts")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Terminé") { showingTransfers = false }
                                }
                            }
                    }
                }
                .sheet(item: $selectedItemForInfo) { AnyView(infoSheet($0)) }
                .quickLookPreview($appState.quickLookURL)
        }
    }

    struct VersionRow: View {
        let version: S3Version
        @ObservedObject var appState: S3AppState
        var body: some View {
            VStack(alignment: .leading) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(version.lastModified.formatted()).fontWeight(
                            version.isLatest ? .bold : .regular)
                        if !version.isDeleteMarker {
                            Text(formatBytes(version.size)).font(.caption).foregroundColor(
                                .secondary)
                        } else {
                            Text("Marqueur de suppression").font(.caption).foregroundColor(.red)
                        }
                    }
                    Spacer()
                    if version.isLatest {
                        Text("Dernière").font(.caption2).padding(4).background(
                            Color.green.opacity(0.1)
                        ).foregroundColor(.green).cornerRadius(4)
                    }
                    if !version.isDeleteMarker {
                        HStack(spacing: 12) {
                            Button {
                                appState.previewFile(key: version.key, versionId: version.versionId)
                            } label: {
                                Image(systemName: "eye")
                            }

                            Button {
                                appState.downloadFile(
                                    key: version.key, versionId: version.versionId)
                            } label: {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Partage temporaire").font(.subheadline).foregroundColor(.secondary)
                    HStack {
                        Button("Lien 1h") {
                            appState.copyPresignedURL(for: version.key, expires: 3600)
                        }.buttonStyle(.bordered)
                        Button("Lien 24h") {
                            appState.copyPresignedURL(for: version.key, expires: 86400)
                        }.buttonStyle(.bordered)
                    }
                }
            }
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
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        }
        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context)
        {}
    }
#endif
