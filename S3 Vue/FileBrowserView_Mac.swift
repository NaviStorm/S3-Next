#if os(macOS)
    import AppKit
    import SwiftUI
    import UniformTypeIdentifiers

    struct FileBrowserView_Mac: View {
        @EnvironmentObject var appState: S3AppState
        @State private var selectedObjectIds: Set<S3Object.ID> = []
        @State private var showingCreateFolder = false
        @State private var newFolderName = ""
        @State private var showingFileImporter = false

        @State private var showingRename = false
        @State private var renameItemKey = ""
        @State private var renameItemName = ""
        @State private var renameIsFolder = false

        @State private var showingDelete = false
        @State private var deleteItemKey = ""
        @State private var deleteIsFolder = false

        @State private var folderStats: (count: Int, size: Int64)? = nil
        @State private var isStatsLoading = false

        // Computed property to maintain backward compatibility with inspector logic
        var selectedObject: S3Object? {
            guard let id = selectedObjectIds.first else { return nil }
            return appState.objects.first { $0.id == id }
        }

        var body: some View {
            HSplitView {
                // Main File List
                VStack(spacing: 0) {
                    // Breadcrumbs / Navigation Bar
                    HStack {
                        Button(action: { appState.navigateBack() }) {
                            Image(systemName: "arrow.backward")
                        }
                        .disabled(appState.currentPath.isEmpty)

                        Button(action: { appState.navigateHome() }) {
                            Image(systemName: "house")
                        }

                        Divider()
                            .frame(height: 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                Text(appState.bucket)
                                    .fontWeight(.bold)
                                // Use indices to handle duplicate folder names in path
                                ForEach(Array(appState.currentPath.enumerated()), id: \.offset) {
                                    index, folder in
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(folder)
                                }
                            }
                        }

                        Menu {
                            Picker("Sort By", selection: $appState.sortOption) {
                                ForEach(S3AppState.SortOption.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            Divider()
                            Toggle("Ascending", isOn: $appState.sortAscending)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 30)

                        Spacer()

                        Button(action: { showingCreateFolder = true }) {
                            Image(systemName: "folder.badge.plus")
                        }
                        .help("New Folder")

                        Button(action: { showingFileImporter = true }) {
                            Image(systemName: "arrow.up.doc")
                        }
                        .help("Upload Files")

                        Button("Logout") {
                            appState.disconnect()
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .alert("New Folder", isPresented: $showingCreateFolder) {
                        TextField("Folder Name", text: $newFolderName)
                        Button("Create") {
                            if !newFolderName.isEmpty {
                                appState.createFolder(name: newFolderName)
                                newFolderName = ""
                            }
                        }
                        Button("Cancel", role: .cancel) { newFolderName = "" }
                    }
                    .alert("Rename", isPresented: $showingRename) {
                        TextField("New Name", text: $renameItemName)
                        Button("Rename") {
                            if !renameItemName.isEmpty {
                                appState.renameObject(
                                    oldKey: renameItemKey, newName: renameItemName,
                                    isFolder: renameIsFolder)
                                renameItemName = ""
                            }
                        }
                        Button("Cancel", role: .cancel) { renameItemName = "" }
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
                                "File selection failed: \(error.localizedDescription)", type: .error
                            )
                        }
                    }
                    .alert("Delete", isPresented: $showingDelete) {
                        Button("Delete", role: .destructive) {
                            if deleteIsFolder {
                                appState.deleteFolder(key: deleteItemKey)
                            } else {
                                appState.deleteObject(key: deleteItemKey)
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        if deleteIsFolder {
                            Text(
                                "Are you sure you want to delete this folder? ALL contents will be permanently deleted."
                            )
                        } else {
                            Text(
                                "Are you sure you want to delete this item? This action cannot be undone."
                            )
                        }
                    }

                    if appState.isLoading {
                        Spacer()
                        ProgressView("Loading...")
                        Spacer()
                    } else {
                        VStack(spacing: 0) {
                            Table(appState.objects, selection: $selectedObjectIds) {
                                TableColumn("Name") { object in
                                    HStack {
                                        Image(systemName: object.isFolder ? "folder.fill" : "doc")
                                            .foregroundColor(object.isFolder ? .blue : .secondary)
                                        Text(displayName(for: object.key))
                                            .fontWeight(object.isFolder ? .medium : .regular)
                                    }
                                    .onTapGesture(count: 2) {
                                        if object.key == ".." {
                                            appState.navigateBack()
                                        } else if object.isFolder {
                                            appState.navigateTo(
                                                folder: displayName(for: object.key))
                                        } else {
                                            appState.downloadFile(key: object.key)
                                        }
                                        appState.log(
                                            "Utilisateur a double-cliqué sur : \(object.key)")
                                    }
                                    .onTapGesture {
                                        selectedObjectIds = [object.id]
                                        appState.log("Utilisateur a cliqué sur : \(object.key)")
                                    }
                                    .contentShape(Rectangle())  // Ensure tap works on empty space in cell
                                    .contextMenu {
                                        Button("Information") {
                                            selectedObjectIds = [object.id]
                                        }

                                        Button("Rename") {
                                            renameItemKey = object.key
                                            renameItemName = displayName(for: object.key)
                                            renameIsFolder = object.isFolder
                                            showingRename = true
                                            // Ensure selection so user sees what they rename
                                            selectedObjectIds = [object.id]
                                        }

                                        if !object.isFolder {
                                            Button("Download") {
                                                appState.downloadFile(key: object.key)
                                            }
                                        }

                                        Divider()

                                        Button("Delete", role: .destructive) {
                                            deleteItemKey = object.key
                                            deleteIsFolder = object.isFolder
                                            // Ensure selection so user sees what they delete
                                            selectedObjectIds = [object.id]
                                            showingDelete = true
                                        }
                                    }
                                }
                                .width(min: 200, ideal: 300)

                                TableColumn("Type") { object in
                                    Text(getType(for: object.key, isFolder: object.isFolder))
                                        .foregroundColor(.secondary)
                                }
                                .width(min: 80, ideal: 100)

                                TableColumn("Date Modified") { object in
                                    Text(
                                        object.lastModified.formatted(
                                            date: .abbreviated, time: .shortened)
                                    )
                                    .foregroundColor(.secondary)
                                }
                                .width(min: 150, ideal: 180)

                                TableColumn("Size") { object in
                                    Text(object.isFolder ? "--" : formatBytes(object.size))
                                        .foregroundColor(.secondary)
                                }
                                .width(min: 80, ideal: 100)
                            }
                        }

                    }

                    // Status Bar
                    HStack(spacing: 16) {
                        let folderCount = appState.objects.filter { $0.isFolder }.count
                        let fileCount = appState.objects.filter { !$0.isFolder }.count
                        let totalSize = appState.objects.reduce(0) { $0 + $1.size }

                        Text("\(folderCount) folder\(folderCount > 1 ? "s" : "")")
                        Text("\(fileCount) file\(fileCount > 1 ? "s" : "")")
                        Text(formatBytes(totalSize))
                            .fontWeight(.medium)

                        Spacer()
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .customBorder(Color.blue, width: 1, edges: [.top])
                }
                .frame(minWidth: 300)

                // Inspector / Detail View
                if let selected = selectedObject {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Details")
                            .font(.headline)

                        Divider()

                        Group {
                            Text("Name:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(displayName(for: selected.key))
                                .textSelection(.enabled)

                            Text("Full Key:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(selected.key)
                                .font(.caption)
                                .textSelection(.enabled)

                            if !selected.isFolder {
                                Text("Size:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(formatBytes(selected.size))

                                Text("Last Modified:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(selected.lastModified.formatted())

                                Divider()

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Permissions")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    if appState.isACLLoading {
                                        HStack {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Loading ACL...")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else if let isPublic = appState.selectedObjectIsPublic {
                                        HStack {
                                            Image(systemName: isPublic ? "globe" : "lock.fill")
                                                .foregroundColor(isPublic ? .green : .secondary)
                                            Text(isPublic ? "Public" : "Private")
                                                .font(.subheadline)

                                            Spacer()

                                            Button(isPublic ? "Make Private" : "Make Public") {
                                                appState.togglePublicAccess(for: selected.key)
                                            }
                                            .buttonStyle(.link)
                                            .font(.caption)
                                        }
                                    } else {
                                        Text("Could not load ACL")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                }

                                Divider()

                                Text("Version History")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if appState.isVersionsLoading {
                                    HStack {
                                        ProgressView().controlSize(.small)
                                        Text("Loading versions...").font(.caption).foregroundColor(
                                            .secondary)
                                    }
                                } else if appState.selectedObjectVersions.isEmpty {
                                    Text("No versions found").font(.caption).foregroundColor(
                                        .secondary)
                                } else {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(appState.selectedObjectVersions) { version in
                                                VStack(alignment: .leading, spacing: 2) {
                                                    HStack {
                                                        Text(
                                                            version.lastModified.formatted(
                                                                date: .abbreviated, time: .shortened
                                                            )
                                                        )
                                                        .font(.caption)
                                                        .fontWeight(
                                                            version.isLatest ? .bold : .regular)

                                                        if version.isLatest {
                                                            Text("Latest")
                                                                .font(
                                                                    .system(size: 8, weight: .bold)
                                                                )
                                                                .padding(.horizontal, 4)
                                                                .padding(.vertical, 1)
                                                                .background(
                                                                    Color.green.opacity(0.2)
                                                                )
                                                                .foregroundColor(.green)
                                                                .cornerRadius(4)
                                                        }

                                                        if version.isDeleteMarker {
                                                            Image(systemName: "trash")
                                                                .font(.caption2)
                                                                .foregroundColor(.red)
                                                        }

                                                        Spacer()

                                                        if !version.isDeleteMarker {
                                                            Button(action: {
                                                                appState.downloadFile(
                                                                    key: version.key,
                                                                    versionId: version.versionId)
                                                            }) {
                                                                Image(
                                                                    systemName: "arrow.down.circle")
                                                            }
                                                            .buttonStyle(.plain)
                                                        }
                                                    }

                                                    if !version.isDeleteMarker {
                                                        Text(formatBytes(version.size))
                                                            .font(.system(size: 9))
                                                            .foregroundColor(.secondary)
                                                    } else {
                                                        Text("Delete Marker")
                                                            .font(.system(size: 9))
                                                            .foregroundColor(.red)
                                                    }
                                                }
                                                .padding(4)
                                                .background(Color.secondary.opacity(0.1))
                                                .cornerRadius(4)
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 200)
                                }

                                Spacer()

                                Button("Download Latest") {
                                    appState.downloadFile(key: selected.key)
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(maxWidth: .infinity)
                            } else {
                                Divider()
                                Text("Folder Statistics:")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if isStatsLoading {
                                    HStack {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.8)
                                        Text("Calculating...")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                } else if let stats = folderStats {
                                    Text("Objects: \(stats.count)")
                                    Text("Total Size: \(formatBytes(stats.size))")
                                } else {
                                    Text("Failed to load stats")
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }

                                Spacer()
                            }
                        }
                    }
                    .padding()
                    .frame(minWidth: 200, maxWidth: 300)
                    .background(Color(NSColor.windowBackgroundColor))
                    .task(id: selected.id) {
                        if selected.isFolder {
                            isStatsLoading = true
                            folderStats = nil
                            folderStats = await appState.calculateFolderStats(
                                folderKey: selected.key)
                            isStatsLoading = false
                        } else {
                            appState.loadVersions(for: selected.key)
                        }
                    }
                }
            }
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

        // Cache for file type descriptions
        @State private var typeCache: [String: String] = [:]

        func getType(for name: String, isFolder: Bool) -> String {
            if isFolder {
                return UTType.folder.localizedDescription ?? "Folder"
            }
            let ext = (name as NSString).pathExtension.lowercased()
            if ext.isEmpty { return "File" }

            // Return cached value if exists
            if let cached = typeCache[ext] {
                return cached
            }

            // Return fast placeholder (UTType or Extension) and fetch real one async
            let fastDesc = UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()

            // Trigger async lookup for high-fidelity description
            Task {
                // Check again inside task to avoid race (though view update handles it)
                if typeCache[ext] != nil { return }

                let highFidelityDesc = getHighFidelityType(for: ext)
                // Update UI on Main Thread
                await MainActor.run {
                    typeCache[ext] = highFidelityDesc
                }
            }

            return fastDesc  // Show this immediately while loading
        }

        // Helper for expensive lookup (non-blocking)
        func getHighFidelityType(for ext: String) -> String {
            // 1. Try simple UTType first (Fast check for common types)
            // But we already used it for placeholder, so we want better.
            // Actually, if UTType gives a specific name (not "Dynamic" or "Data"), keep it?
            // User wanted "Document SQLiteStudio" for .db. UTType often gives generic.

            // We do the file trick.
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(
                ext)

            do {
                // Create empty file
                try "".write(to: tempFile, atomically: false, encoding: .utf8)
                let values = try tempFile.resourceValues(forKeys: [.localizedTypeDescriptionKey])

                let desc = values.localizedTypeDescription
                try? FileManager.default.removeItem(at: tempFile)

                if let validDesc = desc { return validDesc }
            } catch {
                // Ignore
            }

            // Fallback to UTType or UPPERCASE
            return UTType(filenameExtension: ext)?.localizedDescription ?? ext.uppercased()
        }
    }
#endif
