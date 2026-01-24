#if os(macOS)
    import AppKit
    import QuickLook
    import SwiftUI
    import UniformTypeIdentifiers

    struct FileBrowserView_Mac: View {
        @EnvironmentObject var appState: S3AppState
        @Environment(\.openWindow) var openWindow
        @State private var selectedObjectIds: Set<S3Object.ID> = []
        @State private var showingCreateFolder = false
        @State private var newFolderName = ""
        @State private var showingFileImporter = false
        @State private var showingFolderImporter = false

        @State private var showingRename = false
        @State private var renameItemKey = ""
        @State private var renameItemName = ""
        @State private var renameIsFolder = false

        @State private var showingDelete = false
        @State private var deleteItemKey = ""
        @State private var deleteIsFolder = false

        @State private var folderStats: (count: Int, size: Int64)? = nil
        @State private var isStatsLoading = false
        @State private var showingTimeMachine = false

        // Cache for file type descriptions
        @State private var typeCache: [String: String] = [:]

        // Computed property to maintain backward compatibility with inspector logic
        var selectedObject: S3Object? {
            guard let id = selectedObjectIds.first else { return nil }
            return appState.objects.first { $0.id == id }
        }

        var body: some View {
            VStack(spacing: 0) {
                // Ribbon UI
                RibbonView(
                    onUploadFile: { showingFileImporter = true },
                    onUploadFolder: { showingFolderImporter = true },
                    onCreateFolder: { showingCreateFolder = true },
                    onRefresh: { appState.loadObjects() },
                    onNavigateHome: { appState.navigateHome() },
                    onNavigateBack: { appState.navigateBack() },
                    onDownload: {
                        if let selected = selectedObject {
                            if selected.isFolder {
                                appState.downloadFolder(key: selected.key)
                            } else {
                                appState.downloadFile(key: selected.key)
                            }
                        }
                    },
                    onPreview: {
                        if let selected = selectedObject, !selected.isFolder {
                            appState.previewFile(key: selected.key)
                        }
                    },
                    onRename: {
                        if let selected = selectedObject {
                            renameItemKey = selected.key
                            renameItemName = displayName(for: selected.key)
                            renameIsFolder = selected.isFolder
                            showingRename = true
                        }
                    },
                    onDelete: {
                        if let selected = selectedObject {
                            deleteItemKey = selected.key
                            deleteIsFolder = selected.isFolder
                            showingDelete = true
                        }
                    },
                    onShowTimeMachine: { showingTimeMachine = true },
                    onShowHistory: { openWindow(id: "activity-history") }
                )
                .fixedSize(horizontal: false, vertical: true)

                // Breadcrumbs / Path Info Bar (Discrète)
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Button(action: { appState.navigateHome() }) {
                                Text(appState.bucket)
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                            }
                            .buttonStyle(.plain)
                            .onHover { inside in
                                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                            }

                            ForEach(Array(appState.currentPath.enumerated()), id: \.offset) {
                                index, folder in
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                Button(action: { appState.navigateToPath(at: index) }) {
                                    Text(folder)
                                        .foregroundColor(
                                            index == appState.currentPath.count - 1
                                                ? .primary : .blue)
                                }
                                .buttonStyle(.plain)
                                .disabled(index == appState.currentPath.count - 1)
                                .onHover { inside in
                                    if inside && index != appState.currentPath.count - 1 {
                                        NSCursor.pointingHand.push()
                                    } else {
                                        NSCursor.pop()
                                    }
                                }
                            }
                        }
                    }

                    Spacer()

                    if let selected = selectedObject {
                        Text("Sélection : \(displayName(for: selected.key))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

                HSplitView {
                    // Main File List
                    VStack(spacing: 0) {
                        if appState.isLoading {
                            Spacer()
                            ProgressView("Chargement...")
                            Spacer()
                        } else {
                            Table(appState.objects, selection: $selectedObjectIds) {
                                TableColumn("Nom") { object in
                                    HStack {
                                        Image(
                                            systemName: object.key == ".."
                                                ? "arrow.up.circle.fill"
                                                : (object.isFolder ? "folder.fill" : "doc")
                                        )
                                        .foregroundColor(
                                            diffColor(for: object.key)
                                                ?? (object.isFolder ? .blue : .secondary)
                                        )
                                        Text(displayName(for: object.key))
                                            .fontWeight(object.isFolder ? .medium : .regular)
                                            .strikethrough(isRemoved(object.key))
                                            .opacity(isRemoved(object.key) ? 0.6 : 1.0)
                                    }
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedObjectIds = [object.id]
                                    }
                                    .onTapGesture(count: 2) {
                                        if isRemoved(object.key) { return }
                                        if object.key == ".." {
                                            appState.navigateBack()
                                        } else if object.isFolder {
                                            appState.navigateTo(
                                                folder: displayName(for: object.key))
                                        } else {
                                            appState.downloadFile(key: object.key)
                                        }
                                    }
                                }
                                .width(min: 200, ideal: 300)

                                TableColumn("Type") { object in
                                    Text(getType(for: object.key, isFolder: object.isFolder))
                                        .foregroundColor(.secondary)
                                }
                                .width(min: 80, ideal: 100)

                                TableColumn("Date Modification") { object in
                                    Text(
                                        object.lastModified.formatted(
                                            date: .abbreviated, time: .shortened)
                                    )
                                    .foregroundColor(.secondary)
                                }
                                .width(min: 150, ideal: 180)

                                TableColumn("Taille") { object in
                                    Text(object.isFolder ? "--" : formatBytes(object.size))
                                        .foregroundColor(.secondary)
                                }
                                .width(min: 80, ideal: 100)
                            }
                        }

                        // Status Bar
                        HStack(spacing: 16) {
                            let folderCount = appState.objects.filter {
                                $0.isFolder && $0.key != ".."
                            }.count
                            let fileCount = appState.objects.filter { !$0.isFolder }.count
                            let totalSize = appState.objects.reduce(0) { $0 + $1.size }

                            Text("\(folderCount) dossier\(folderCount > 1 ? "s" : "")")
                            Text("\(fileCount) fichier\(fileCount > 1 ? "s" : "")")
                            Text(formatBytes(totalSize))
                                .fontWeight(.medium)

                            Spacer()

                            Button("Déconnexion") {
                                appState.disconnect()
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                    }
                    .frame(minWidth: 400)

                    // Inspector / Detail View
                    if let selected = selectedObject {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Détails")
                                .font(.headline)

                            Divider()

                            ScrollView {
                                VStack(alignment: .leading, spacing: 12) {
                                    DetailItem(label: "Nom", value: displayName(for: selected.key))
                                    DetailItem(
                                        label: "Clé complète", value: selected.key,
                                        isTextSelected: true)

                                    if !selected.isFolder {
                                        DetailItem(
                                            label: "Taille", value: formatBytes(selected.size))
                                        DetailItem(
                                            label: "Dernière modification",
                                            value: selected.lastModified.formatted())

                                        if appState.isMetadataLoading {
                                            ProgressView().controlSize(.small)
                                        } else if let alias = appState.selectedObjectMetadata[
                                            "x-amz-meta-cse-key-alias"]
                                        {
                                            Divider()
                                            HStack {
                                                Image(systemName: "lock.fill").foregroundColor(
                                                    .orange)
                                                VStack(alignment: .leading) {
                                                    Text("Chiffrement CSE").font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text(alias).fontWeight(.semibold)
                                                }
                                            }
                                        }

                                        Divider()

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Permissions").font(.caption).foregroundColor(
                                                .secondary)
                                            if appState.isACLLoading {
                                                ProgressView().controlSize(.small)
                                            } else if let isPublic = appState.selectedObjectIsPublic
                                            {
                                                HStack {
                                                    Image(
                                                        systemName: isPublic ? "globe" : "lock.fill"
                                                    )
                                                    .foregroundColor(isPublic ? .green : .secondary)
                                                    Text(isPublic ? "Public" : "Privé")
                                                    Spacer()
                                                    Button(
                                                        isPublic ? "Rendre Privé" : "Rendre Public"
                                                    ) {
                                                        appState.togglePublicAccess(
                                                            for: selected.key)
                                                    }
                                                    .buttonStyle(.link)
                                                    .font(.caption)
                                                }
                                            }
                                        }

                                        Divider()

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Versions").font(.caption).foregroundColor(
                                                .secondary)
                                            if appState.isVersionsLoading {
                                                ProgressView().controlSize(.small)
                                            } else {
                                                ForEach(appState.selectedObjectVersions.prefix(5)) {
                                                    version in
                                                    HStack {
                                                        Text(
                                                            version.lastModified.formatted(
                                                                date: .abbreviated, time: .shortened
                                                            )
                                                        )
                                                        .font(.system(size: 10))
                                                        if version.isLatest {
                                                            Text("Actuelle").font(
                                                                .system(size: 8, weight: .bold)
                                                            )
                                                            .foregroundColor(.green)
                                                        }
                                                        Spacer()
                                                        Button(action: {
                                                            appState.downloadFile(
                                                                key: version.key,
                                                                versionId: version.versionId)
                                                        }) {
                                                            Image(systemName: "arrow.down.circle")
                                                        }.buttonStyle(.plain)
                                                    }
                                                    .padding(4)
                                                    .background(Color.secondary.opacity(0.1))
                                                    .cornerRadius(4)
                                                }
                                            }
                                        }
                                    } else {
                                        // Folder Stats
                                        if isStatsLoading {
                                            ProgressView("Calcul des stats...").controlSize(.small)
                                        } else if let stats = folderStats {
                                            DetailItem(
                                                label: "Contenu", value: "\(stats.count) objets")
                                            DetailItem(
                                                label: "Taille totale",
                                                value: formatBytes(stats.size))
                                        }
                                    }
                                }
                            }

                            Spacer()

                            if !selected.isFolder {
                                Button("Télécharger") {
                                    appState.downloadFile(key: selected.key)
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .padding()
                        .frame(minWidth: 250, maxWidth: 350)
                        .background(Color(NSColor.windowBackgroundColor))
                        .task(id: selected.id) {
                            if selected.isFolder {
                                isStatsLoading = true
                                folderStats = await appState.calculateFolderStats(
                                    folderKey: selected.key)
                                isStatsLoading = false
                            } else {
                                appState.loadVersions(for: selected.key)
                                appState.loadACL(for: selected.key)
                                appState.loadMetadata(for: selected.key)
                            }
                        }
                    }
                }
            }
            .quickLookPreview($appState.quickLookURL)
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
                TextField("Nouveau nom", text: $renameItemName)
                Button("Renommer") {
                    if !renameItemName.isEmpty {
                        appState.renameObject(
                            oldKey: renameItemKey, newName: renameItemName, isFolder: renameIsFolder
                        )
                    }
                }
                Button("Annuler", role: .cancel) { renameItemName = "" }
            }
            .alert("Suppression", isPresented: $showingDelete) {
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
                        ? "Tout le contenu du dossier sera supprimé."
                        : "Cette action est irréversible.")
            }
            .fileImporter(
                isPresented: $showingFileImporter, allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    for url in urls { appState.uploadFile(url: url) }
                }
            }
            .background(
                Color.clear
                    .fileImporter(
                        isPresented: $showingFolderImporter, allowedContentTypes: [.folder],
                        allowsMultipleSelection: false
                    ) { result in
                        if case .success(let urls) = result, let url = urls.first {
                            appState.uploadFolder(url: url)
                        }
                    }
            )
        }

        func displayName(for key: String) -> String {
            if key == ".." { return "Dossier parent" }
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

        func getType(for name: String, isFolder: Bool) -> String {
            if isFolder { return UTType.folder.localizedDescription ?? "Dossier" }
            let ext = (name as NSString).pathExtension.lowercased()
            if let cached = typeCache[ext] { return cached }
            let fastDesc = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
            Task {
                let highFid = getHighFidelityType(for: ext)
                await MainActor.run { typeCache[ext] = highFid }
            }
            return fastDesc
        }

        private func diffColor(for key: String) -> Color? {
            guard let diff = appState.activeComparison else { return nil }
            if diff.added.contains(where: { $0.key == key }) { return .green }
            if diff.modified.contains(where: { $0.key == key }) { return .orange }
            if diff.removed.contains(where: { $0.key == key }) { return .red }
            return nil
        }

        private func isRemoved(_ key: String) -> Bool {
            return appState.activeComparison?.removed.contains(where: { $0.key == key }) ?? false
        }

        func getHighFidelityType(for ext: String) -> String {
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(
                ext)
            do {
                try "".write(to: tempFile, atomically: false, encoding: .utf8)
                let values = try tempFile.resourceValues(forKeys: [.localizedTypeDescriptionKey])
                let desc = values.localizedTypeDescription
                try? FileManager.default.removeItem(at: tempFile)
                if let validDesc = desc { return validDesc }
            } catch {}
            return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
        }
    }

    struct DetailItem: View {
        let label: String
        let value: String
        var isTextSelected: Bool = false

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundColor(.secondary)
                if isTextSelected {
                    Text(value).font(.subheadline).textSelection(.enabled)
                } else {
                    Text(value).font(.subheadline).textSelection(.disabled)
                }
            }
        }
    }
#endif
