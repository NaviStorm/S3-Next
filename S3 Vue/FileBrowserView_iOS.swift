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
                        ProgressView("Loading...")
                    } else if let error = appState.errorMessage {
                        VStack(spacing: 20) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.yellow)
                            Text(error)
                                .multilineTextAlignment(.center)
                            Button("Retry") { appState.loadObjects() }
                                .buttonStyle(.bordered)
                        }
                        .padding()
                    } else if appState.objects.isEmpty {
                        VStack(spacing: 20) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No items found")
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
                                            Label("Rename", systemImage: "pencil")
                                        }

                                        if !object.isFolder {
                                            Button(action: {
                                                appState.downloadFile(key: object.key)
                                            }) {
                                                Label("Download", systemImage: "arrow.down.circle")
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
                                        }

                                        Button(
                                            role: .destructive,
                                            action: {
                                                deleteItemKey = object.key
                                                deleteIsFolder = object.isFolder
                                                showingDelete = true
                                            }
                                        ) {
                                            Label("Delete", systemImage: "trash")
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
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if !appState.currentPath.isEmpty {
                            Button(action: {
                                appState.navigateBack()
                            }) {
                                Image(systemName: "chevron.left")
                                Text("Back")
                            }
                        }
                    }

                    ToolbarItem(placement: .navigationBarTrailing) {
                        HStack {
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
                            "File selection failed: \(error.localizedDescription)", type: .error)
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
                    Text(
                        deleteIsFolder
                            ? "Are you sure you want to delete this folder and all its contents?"
                            : "Are you sure you want to delete this file?")
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
                                ProgressView("Loading versions...")
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
                                                    Text("Delete Marker")
                                                        .font(.caption)
                                                        .foregroundColor(.red)
                                                }
                                            }

                                            Spacer()

                                            if version.isLatest {
                                                Text("Latest")
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
                                }
                            }
                        }
                        .navigationTitle("Versions")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showingVersions = false }
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
                                    Button("Done") { showingSettings = false }
                                }
                            }
                    }
                }
                .sheet(item: $selectedItemForInfo) { object in
                    NavigationStack {
                        List {
                            Section("Properties") {
                                LabeledContent("Name", value: displayName(for: object.key))
                                LabeledContent("Key", value: object.key)
                                if !object.isFolder {
                                    LabeledContent("Size", value: formatBytes(object.size))
                                    LabeledContent(
                                        "Last Modified", value: object.lastModified.formatted())
                                } else {
                                    LabeledContent("Type", value: "Folder")
                                    if isInfoStatsLoading {
                                        HStack {
                                            Text("Calculating stats...")
                                                .foregroundColor(.secondary)
                                            ProgressView()
                                        }
                                    } else if let stats = infoFolderStats {
                                        LabeledContent("Objects", value: "\(stats.count)")
                                        LabeledContent("Total Size", value: formatBytes(stats.size))
                                    }
                                }
                            }
                        }
                        .navigationTitle("Details")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { selectedItemForInfo = nil }
                            }
                        }
                        .task {
                            if object.isFolder {
                                isInfoStatsLoading = true
                                infoFolderStats = nil
                                infoFolderStats = await appState.calculateFolderStats(
                                    folderKey: object.key)
                                isInfoStatsLoading = false
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
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
