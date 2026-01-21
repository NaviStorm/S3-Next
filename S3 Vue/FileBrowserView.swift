import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    @EnvironmentObject var appState: S3AppState
    @State private var selectedObjectIds: Set<S3Object.ID> = []

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

                    Spacer()

                    Button("Logout") {
                        appState.disconnect()
                    }
                }
                .padding(8)
                .background(Color(NSColor.controlBackgroundColor))

                if appState.isLoading {
                    Spacer()
                    ProgressView("Loading...")
                    Spacer()
                } else {
                    Table(appState.objects, selection: $selectedObjectIds) {
                        TableColumn("Name") { object in
                            HStack {
                                Image(systemName: object.isFolder ? "folder.fill" : "doc")
                                    .foregroundColor(object.isFolder ? .blue : .secondary)
                                Text(displayName(for: object.key))
                                    .fontWeight(object.isFolder ? .medium : .regular)
                            }
                            .onTapGesture(count: 2) {
                                if object.isFolder {
                                    appState.navigateTo(folder: displayName(for: object.key))
                                } else {
                                    appState.downloadFile(key: object.key)
                                }
                                appState.log("Utilisateur a double-cliqué sur : \(object.key)")
                            }
                            .onTapGesture {
                                selectedObjectIds = [object.id]
                                appState.log("Utilisateur a cliqué sur : \(object.key)")
                            }
                            .contextMenu {
                                if !object.isFolder {
                                    Button("Download") {
                                        appState.downloadFile(key: object.key)
                                    }
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
                                object.lastModified.formatted(date: .abbreviated, time: .shortened)
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

                            Spacer()

                            Button("Download") {
                                appState.downloadFile(key: selected.key)
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                        } else {
                            Spacer()
                        }
                    }
                }
                .padding()
                .frame(minWidth: 200, maxWidth: 300)
                .background(Color(NSColor.windowBackgroundColor))
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
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)

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

extension View {
    func customBorder(_ color: Color, width: CGFloat, edges: [Edge]) -> some View {
        overlay(
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                Path { path in
                    if edges.contains(.top) {
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: w, y: 0))
                    }
                    if edges.contains(.bottom) {
                        path.move(to: CGPoint(x: 0, y: h))
                        path.addLine(to: CGPoint(x: w, y: h))
                    }
                    if edges.contains(.leading) {
                        path.move(to: CGPoint(x: 0, y: 0))
                        path.addLine(to: CGPoint(x: 0, y: h))
                    }
                    if edges.contains(.trailing) {
                        path.move(to: CGPoint(x: w, y: 0))
                        path.addLine(to: CGPoint(x: w, y: h))
                    }
                }
                .stroke(color, lineWidth: width)
            }
        )
    }
}
