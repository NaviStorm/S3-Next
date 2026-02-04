#if os(macOS)
    import AppKit
    import QuickLook
    import SwiftUI
    import UniformTypeIdentifiers

    extension UTType {
        static var s3Object = UTType(exportedAs: "com.s3next.s3.object", conformingTo: .data)
    }

    struct FileBrowserView_Mac: View {
        @EnvironmentObject var appState: S3AppState
        @Environment(\.openWindow) var openWindow
        @State private var selectedObjectIds: Set<S3Object.ID> = []
        @FocusState private var isTableFocused: Bool
        @State private var targetedObjectId: S3Object.ID? = nil
        @State private var isDraggingOverList = false
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

        @State private var isStatsLoading = false
        @State private var showingUploadLink = false
        @State private var maxUploadSize = "100"
        @State private var showingTimeMachine = false
        @State private var showingSecurity = false
        @State private var showingLifecycle = false

        // Cache for file type descriptions
        @State private var typeCache: [String: String] = [:]

        // Computed property to maintain backward compatibility with inspector logic
        private var selectedObject: S3Object? {
            guard let firstId = selectedObjectIds.first else { return nil }
            return appState.objects.first { object in object.id == firstId }
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
                    onDelete: { triggerDelete() },
                    onShowTimeMachine: { showingTimeMachine = true },
                    onShowHistory: { openWindow(id: "activity-history") },
                    onShowLifecycle: { showingLifecycle = true }
                )
                .fixedSize(horizontal: false, vertical: true)

                // Breadcrumbs / Path Info Bar
                HStack {
                    Image(systemName: "folder").foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            Button(action: { appState.navigateHome() }) {
                                Text(appState.bucket).fontWeight(.bold).foregroundColor(.primary)
                            }.buttonStyle(.plain)

                            ForEach(Array(appState.currentPath.enumerated()), id: \.offset) {
                                index, folder in
                                Image(systemName: "chevron.right").font(.caption2).foregroundColor(
                                    .secondary)
                                Button(action: { appState.navigateToPath(at: index) }) {
                                    Text(folder).foregroundColor(
                                        index == appState.currentPath.count - 1 ? .primary : .blue)
                                }.buttonStyle(.plain).disabled(
                                    index == appState.currentPath.count - 1)
                            }
                        }
                    }
                    Spacer()
                    if let selected = selectedObject {
                        Text("Sélection : \(displayName(for: selected.key))").font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))

                HSplitView {
                    fileListSection
                    if let selected = selectedObject {
                        inspectorSection(selected)
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
                        ? "Voulez-vous supprimer le dossier \"\(displayName(for: deleteItemKey))\" et tout son contenu ?"
                        : "Voulez-vous supprimer \"\(displayName(for: deleteItemKey))\" ?")
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
                Color.clear.fileImporter(
                    isPresented: $showingFolderImporter, allowedContentTypes: [.folder],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        appState.uploadFolder(url: url)
                    }
                }
            )
            .sheet(isPresented: $showingSecurity) {
                if let selected = selectedObject {
                    NavigationStack {
                        ObjectSecurityView(objectKey: selected.key).id(selected.key)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Terminer") { showingSecurity = false }
                                }
                            }
                    }
                }
            }
            .sheet(isPresented: $showingLifecycle) {
                NavigationStack {
                    BucketLifecycleView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Terminer") { showingLifecycle = false }
                            }
                        }
                }.frame(minWidth: 600, minHeight: 400)
            }
            .sheet(isPresented: $showingTimeMachine) { SnapshotTimelineView() }
            .background(
                Button("") { triggerDelete() }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .opacity(0)
            )
        }

        // --- Sub-views ---

        @ViewBuilder
        private var fileListSection: some View {
            VStack(spacing: 0) {
                if appState.isLoading {
                    Spacer()
                    ProgressView("Chargement...")
                    Spacer()
                } else {
                    Table(appState.objects, selection: $selectedObjectIds) {
                        TableColumn("Nom") { object in
                            RowCellWrapper(
                                object: object, targetedObjectId: $targetedObjectId,
                                selection: $selectedObjectIds, appState: appState,
                                isFirstColumn: true
                            ) {
                                FileRowNameCell(
                                    object: object,
                                    appState: appState,
                                    selection: $selectedObjectIds,
                                    isTableFocused: $isTableFocused,
                                    targetedObjectId: $targetedObjectId
                                )
                            }
                        }.width(min: 200, ideal: 300)

                        TableColumn("Type") { object in
                            RowCellWrapper(
                                object: object, targetedObjectId: $targetedObjectId,
                                selection: $selectedObjectIds, appState: appState
                            ) {
                                Text(getType(for: object.key, isFolder: object.isFolder))
                                    .padding(.horizontal, 12)
                                    .foregroundColor(
                                        targetedObjectId == object.id ? .white : .secondary)
                            }
                        }.width(min: 80, ideal: 100)

                        TableColumn("Date Modification") { object in
                            RowCellWrapper(
                                object: object, targetedObjectId: $targetedObjectId,
                                selection: $selectedObjectIds, appState: appState
                            ) {
                                Text(
                                    object.lastModified.formatted(
                                        date: .abbreviated, time: .shortened)
                                )
                                .padding(.horizontal, 12)
                                .foregroundColor(
                                    targetedObjectId == object.id ? .white : .secondary)
                            }
                        }.width(min: 150, ideal: 180)

                        TableColumn("Taille") { object in
                            RowCellWrapper(
                                object: object, targetedObjectId: $targetedObjectId,
                                selection: $selectedObjectIds, appState: appState,
                                isLastColumn: true
                            ) {
                                Text(object.isFolder ? " " : formatBytes(object.size))
                                    .padding(.horizontal, 12)
                                    .foregroundColor(
                                        targetedObjectId == object.id ? .white : .secondary)
                            }
                        }.width(min: 80, ideal: 100)
                    }
                    .focused($isTableFocused)
                    .focusable()
                    .onChange(of: isDraggingOverList) { dragging in
                        if dragging {
                            isTableFocused = false
                        } else if targetedObjectId == nil {
                            isTableFocused = true
                        }
                    }
                    .onChange(of: targetedObjectId) { id in
                        if id != nil {
                            isTableFocused = false
                        } else if !isDraggingOverList {
                            isTableFocused = true
                        }
                    }
                    .onDrop(of: [UTType.fileURL, UTType.s3Object], isTargeted: $isDraggingOverList)
                    {
                        providers in
                        print(
                            "[DND-DEBUG] Table-level Drop triggered. Providers: \(providers.count)")

                        // 1. Tenter le drag interne (S3 vers S3)
                        if let s3Provider = providers.first(where: {
                            $0.hasItemConformingToTypeIdentifier(UTType.s3Object.identifier)
                        }) {
                            print(
                                "[DND-DEBUG] Table-level Internal S3 object detected. Handling drop to current folder."
                            )
                            _ = s3Provider.loadDataRepresentation(
                                forTypeIdentifier: UTType.s3Object.identifier
                            ) { data, error in
                                if let error = error {
                                    print(
                                        "[DND-DEBUG] Table-level Load error: \(error.localizedDescription)"
                                    )
                                }
                                if let data = data,
                                    let sourceKey = String(data: data, encoding: .utf8)
                                {
                                    print("[DND-DEBUG] Table-level Source key loaded: \(sourceKey)")
                                    DispatchQueue.main.async {
                                        let key = sourceKey
                                        // On déplace vers le dossier actuel (prefix)
                                        let destinationPrefix =
                                            appState.currentPath.joined(separator: "/")
                                            + (appState.currentPath.isEmpty ? "" : "/")

                                        print(
                                            "[DND-DEBUG] Table-level Moving \(key) to \(destinationPrefix)"
                                        )

                                        // On utilise le fallback directement car on est au niveau table
                                        appState.moveObject(
                                            sourceKey: key,
                                            destinationPrefix: destinationPrefix,
                                            isFolder: key.hasSuffix("/"))
                                    }
                                }
                            }
                            return true
                        }

                        // 2. Fallback sur le drag externe (Finder vers S3)
                        for provider in providers {
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                if let url = url {
                                    DispatchQueue.main.async {
                                        var isDir: ObjCBool = false
                                        if FileManager.default.fileExists(
                                            atPath: url.path, isDirectory: &isDir)
                                        {
                                            if isDir.boolValue {
                                                appState.uploadFolder(url: url)
                                            } else {
                                                appState.uploadFile(url: url)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        return true
                    }
                }
                statusBarSection
            }
            .frame(minWidth: 400)
            .onChange(of: appState.currentPath) { _ in
                // Sécurité : Réinitialiser tout état de survol lors d'une navigation
                targetedObjectId = nil
                isDraggingOverList = false
            }
        }

        private var statusBarSection: some View {
            HStack(spacing: 16) {
                let folderCount = appState.objects.filter { $0.isFolder && $0.key != ".." }.count
                let fileCount = appState.objects.filter { !$0.isFolder }.count
                let totalSize = appState.objects.reduce(0) { $0 + $1.size }
                Text("\(folderCount) dossier\(folderCount > 1 ? "s" : "")")
                Text("\(fileCount) fichier\(fileCount > 1 ? "s" : "")")
                Text(formatBytes(totalSize)).fontWeight(.medium)
                Spacer()
                Button("Déconnexion") { appState.disconnect() }.buttonStyle(.link).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Color.blue.opacity(0.1))
        }

        @ViewBuilder
        private func inspectorSection(_ selected: S3Object) -> some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Détails").font(.headline)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        DetailItem(label: "Nom", value: displayName(for: selected.key))
                        DetailItem(label: "Clé complète", value: selected.key, isTextSelected: true)

                        if !selected.isFolder {
                            DetailItem(label: "Taille", value: formatBytes(selected.size))
                            DetailItem(
                                label: "Dernière modification",
                                value: selected.lastModified.formatted())

                            // Métadonnées
                            if appState.isMetadataLoading {
                                ProgressView().controlSize(.small)
                            } else if let alias = appState.selectedObjectMetadata[
                                "x-amz-meta-cse-key-alias"]
                            {
                                Divider()
                                HStack {
                                    Image(systemName: "lock.fill").foregroundColor(.orange)
                                    VStack(alignment: .leading) {
                                        Text("Chiffrement CSE").font(.caption).foregroundColor(
                                            .secondary)
                                        Text(alias).fontWeight(.semibold)
                                    }
                                }
                            }

                            Divider()
                            // Permissions simplifiées (utilisant le flag existant s'il y en a un)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Permissions").font(.caption).foregroundColor(.secondary)
                                if appState.isACLLoading {
                                    ProgressView().controlSize(.small)
                                } else if let isPublic = appState.selectedObjectIsPublic {
                                    HStack {
                                        Image(systemName: isPublic ? "globe" : "lock.fill")
                                            .foregroundColor(isPublic ? .green : .secondary)
                                        Text(isPublic ? "Public" : "Privé")
                                        Spacer()
                                        Button(isPublic ? "Rendre Privé" : "Rendre Public") {
                                            appState.togglePublicAccess(for: selected.key)
                                        }.buttonStyle(.link).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    if !selected.isFolder {
                        Button("Télécharger") { appState.downloadFile(key: selected.key) }
                            .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    }
                }.padding()
            }
            .frame(minWidth: 250, maxWidth: 350).background(Color(NSColor.windowBackgroundColor))
            .task(id: selected.id) {
                if !selected.isFolder {
                    appState.loadMetadata(for: selected.key)
                    appState.loadVersions(for: selected.key)
                }
            }
        }

        private var noBucketView: some View {
            VStack(spacing: 30) {
                Image(systemName: "archivebox").font(.system(size: 80)).foregroundColor(.blue)
                VStack(spacing: 15) {
                    Text("Bienvenue sur S3 Next").font(.title).fontWeight(.bold)
                    Text("Aucun bucket sélectionné.").font(.title3).foregroundColor(.secondary)
                }
                if !appState.availableBuckets.isEmpty {
                    Menu("Sélectionner un bucket") {
                        ForEach(appState.availableBuckets, id: \.self) { bname in
                            Button(bname) { appState.selectBucket(named: bname) }
                        }
                    }.buttonStyle(.bordered).controlSize(.large)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(
                Color(NSColor.windowBackgroundColor))
        }

        // --- Helpers ---

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

        func triggerDelete() {
            if let selected = selectedObject {
                deleteItemKey = selected.key
                deleteIsFolder = selected.isFolder
                showingDelete = true
            }
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

        func getHighFidelityType(for ext: String) -> String {
            let tempFile = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString
            ).appendingPathExtension(ext)
            try? "".write(to: tempFile, atomically: false, encoding: .utf8)
            let desc = (try? tempFile.resourceValues(forKeys: [.localizedTypeDescriptionKey]))?
                .localizedTypeDescription
            try? FileManager.default.removeItem(at: tempFile)
            return desc ?? UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
        }

        @ViewBuilder
        func rowWrapper(object: S3Object, content: () -> some View) -> some View {
            let isTargeted = targetedObjectId == object.id
            content()
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .foregroundColor(isTargeted ? .white : .secondary)
                .background(
                    isTargeted ? Color(NSColor.selectedContentBackgroundColor) : Color.clear
                )
        }

        struct RowCellWrapper<Content: View>: View {
            let object: S3Object
            @Binding var targetedObjectId: S3Object.ID?
            @Binding var selection: Set<S3Object.ID>
            @ObservedObject var appState: S3AppState
            let content: Content
            let isFirstColumn: Bool
            let isLastColumn: Bool

            @State private var localIsTargeted = false
            @State private var springLoadingTask: Task<Void, Never>? = nil

            init(
                object: S3Object,
                targetedObjectId: Binding<S3Object.ID?>,
                selection: Binding<Set<S3Object.ID>>,
                appState: S3AppState,
                isFirstColumn: Bool = false,
                isLastColumn: Bool = false,
                @ViewBuilder content: () -> Content
            ) {
                self.object = object
                self._targetedObjectId = targetedObjectId
                self._selection = selection
                self.appState = appState
                self.isFirstColumn = isFirstColumn
                self.isLastColumn = isLastColumn
                self.content = content()
            }

            var body: some View {
                let isHovered = localIsTargeted || targetedObjectId == object.id
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(
                        Group {
                            if isHovered {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(Color(NSColor.selectedContentBackgroundColor))
                                    .padding(.leading, isFirstColumn ? -5 : -20)
                                    .padding(.trailing, isLastColumn ? -5 : -20)
                                    .padding(.vertical, -4)  // Combler les pixels manquants
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .onDrop(of: [UTType.fileURL, UTType.s3Object], isTargeted: $localIsTargeted) {
                        providers in
                        print(
                            "[DND-DEBUG] Drop triggered on \(object.key). Providers: \(providers.count)"
                        )
                        for p in providers {
                            print("[DND-DEBUG] Provider types: \(p.registeredTypeIdentifiers)")
                        }

                        guard object.isFolder else {
                            print("[DND-DEBUG] Drop rejected: Target is not a folder")
                            return false
                        }

                        // 1. Tenter le drag interne (S3 vers S3)
                        if let s3Provider = providers.first(where: {
                            $0.hasItemConformingToTypeIdentifier(UTType.s3Object.identifier)
                        }) {
                            print("[DND-DEBUG] Internal S3 object detected. Loading data...")
                            _ = s3Provider.loadDataRepresentation(
                                forTypeIdentifier: UTType.s3Object.identifier
                            ) { data, error in
                                if let error = error {
                                    print("[DND-DEBUG] Load error: \(error.localizedDescription)")
                                }
                                if let data = data,
                                    let sourceKey = String(data: data, encoding: .utf8)
                                {
                                    print("[DND-DEBUG] Source key loaded: \(sourceKey)")
                                    DispatchQueue.main.async {
                                        let key = sourceKey
                                        // On déplace vers le préfixe de ce dossier
                                        let destinationPrefix =
                                            object.key == ".."
                                            ? appState.currentPath.dropLast().joined(separator: "/")
                                                + (appState.currentPath.count > 1 ? "/" : "")
                                            : object.key + (object.key.hasSuffix("/") ? "" : "/")

                                        print("[DND-DEBUG] Moving \(key) to \(destinationPrefix)")
                                        // Trouver l'objet source pour savoir si c'est un dossier
                                        if let sourceObject = appState.objects.first(where: {
                                            $0.key == key
                                        }) {
                                            appState.moveObject(
                                                sourceKey: key,
                                                destinationPrefix: destinationPrefix,
                                                isFolder: sourceObject.isFolder)
                                        } else {
                                            print(
                                                "[DND-DEBUG] Warning: sourceObject not found in list, using fallback"
                                            )
                                            // Fallback: si l'objet n'est plus dans la liste (ex: après une recherche), on se fie au suffixe /
                                            appState.moveObject(
                                                sourceKey: key,
                                                destinationPrefix: destinationPrefix,
                                                isFolder: key.hasSuffix("/"))
                                        }
                                    }
                                } else {
                                    print("[DND-DEBUG] Failed to decode data to string.")
                                }
                            }
                            return true
                        } else {
                            print(
                                "[DND-DEBUG] No internal S3 object found in providers. Checking external files..."
                            )
                        }

                        // 2. Fallback sur le drag externe (Finder vers S3)
                        let folderPrefix = object.key + (object.key.hasSuffix("/") ? "" : "/")
                        for provider in providers {
                            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                                if let url = url {
                                    DispatchQueue.main.async {
                                        var isDir: ObjCBool = false
                                        if FileManager.default.fileExists(
                                            atPath: url.path, isDirectory: &isDir)
                                        {
                                            if isDir.boolValue {
                                                appState.uploadFolder(
                                                    url: url, folderPrefix: folderPrefix)
                                            } else {
                                                appState.uploadFile(
                                                    url: url, folderPrefix: folderPrefix)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        return true
                    }
                    .onChange(of: localIsTargeted) { targeted in
                        print("[DND-DEBUG] Row targeted changed to \(targeted) for \(object.key)")
                        if targeted {
                            targetedObjectId = object.id
                            // Sync selection instantly to show details
                            selection = [object.id]

                            // SPRING LOADING: Ouvrir le dossier si on reste dessus
                            if object.isFolder {
                                springLoadingTask?.cancel()
                                springLoadingTask = Task {
                                    try? await Task.sleep(nanoseconds: 1_200_000_000)  // 1.2s
                                    if !Task.isCancelled {
                                        await MainActor.run {
                                            if object.key == ".." {
                                                appState.navigateBack()
                                            } else {
                                                // Extraire le nom du dossier pour la navigation
                                                var folderName = object.key
                                                if folderName.hasSuffix("/") {
                                                    folderName = String(folderName.dropLast())
                                                }
                                                if let lastSlash = folderName.lastIndex(of: "/") {
                                                    folderName = String(
                                                        folderName[
                                                            folderName.index(after: lastSlash)...])
                                                }
                                                appState.navigateTo(folder: folderName)
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            springLoadingTask?.cancel()
                            springLoadingTask = nil
                            if targetedObjectId == object.id {
                                targetedObjectId = nil
                            }
                        }
                    }
                    .onDisappear {
                        // Sécurité : Nettoyer si la cellule disparait (par ex: navigation)
                        springLoadingTask?.cancel()
                        springLoadingTask = nil
                        if targetedObjectId == object.id {
                            targetedObjectId = nil
                        }
                    }
            }
        }
    }

    struct FileRowNameCell: View {
        let object: S3Object
        @ObservedObject var appState: S3AppState
        @Binding var selection: Set<S3Object.ID>
        @FocusState.Binding var isTableFocused: Bool
        @Binding var targetedObjectId: S3Object.ID?
        @State private var isTargeted = false

        var body: some View {
            let isHovered = isTargeted || targetedObjectId == object.id
            HStack {
                Image(
                    systemName: object.key == ".."
                        ? "arrow.up.circle.fill" : (object.isFolder ? "folder.fill" : "doc")
                )
                .foregroundColor(
                    isHovered
                        ? .white
                        : (diffColor(for: object.key) ?? (object.isFolder ? .blue : .secondary))
                )
                Text(displayName(for: object.key))
                    .fontWeight(object.isFolder ? .medium : .regular)
                    .strikethrough(isRemoved(object.key))
                    .opacity(isRemoved(object.key) ? 0.6 : 1.0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundColor(isHovered ? .white : .primary)
            .contentShape(Rectangle())
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    if isRemoved(object.key) { return }
                    if object.key == ".." {
                        appState.navigateBack()
                    } else if object.isFolder {
                        appState.navigateTo(folder: displayName(for: object.key))
                    } else {
                        appState.downloadFile(key: object.key)
                    }
                }
            )
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    // Force selection manually to bypass SwiftUI Table bugs
                    isTableFocused = true
                    let modifiers = NSEvent.modifierFlags
                    if modifiers.contains(.command) {
                        if selection.contains(object.id) {
                            selection.remove(object.id)
                        } else {
                            selection.insert(object.id)
                        }
                    } else if modifiers.contains(.shift) {
                        selection.insert(object.id)
                    } else {
                        selection = [object.id]
                    }
                }
            )
            .onDrag {
                print("[DND-DEBUG] Drag started for \(object.key)")
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    displayName(for: object.key))
                if !object.isFolder { appState.downloadFile(key: object.key) }

                let provider = NSItemProvider()

                // Pour le Finder
                provider.registerObject(tempURL as NSURL, visibility: .all)

                // Pour l'interne (S3Next)
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.s3Object.identifier, visibility: .all
                ) { completion in
                    print("[DND-DEBUG] Providing data for internal drag: \(object.key)")
                    completion(object.key.data(using: .utf8), nil)
                    return nil
                }

                return provider
            }
        }

        private func displayName(for key: String) -> String {
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

        private func isRemoved(_ key: String) -> Bool {
            return appState.activeComparison?.removed.contains(where: { $0.key == key }) ?? false
        }

        private func diffColor(for key: String) -> Color? {
            guard let diff = appState.activeComparison else { return nil }
            if diff.added.contains(where: { $0.key == key }) { return .green }
            if diff.modified.contains(where: { $0.key == key }) { return .orange }
            if diff.removed.contains(where: { $0.key == key }) { return .red }
            return nil
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
