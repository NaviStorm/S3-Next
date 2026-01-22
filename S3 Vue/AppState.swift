import Combine
import Foundation
import SwiftUI

final class S3AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Toast
    @Published var toastMessage: String?
    @Published var toastType: ToastType = .info

    func showToast(_ message: String, type: ToastType = .info) {
        DispatchQueue.main.async {
            self.toastMessage = message
            self.toastType = type

            // Auto dismiss
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if self.toastMessage == message {
                    self.toastMessage = nil
                }
            }
        }
    }

    // Config
    @Published var accessKey = ""
    @Published var secretKey = ""
    @Published var bucket = ""
    @Published var region = "us-east-1"
    @Published var endpoint = "https://s3.fr1.next.ink"  // Default or empty
    @Published var usePathStyle = true
    @Published var debugMessage: String = ""  // For debugging

    // Smart Logging Helper
    func log(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        let fileName = (file as NSString).lastPathComponent
        let logEntry = "[\(fileName):\(line)] \(function) > \(message)\n"
        print(logEntry)  // Print to console for Xcode debugging

        if Thread.isMainThread {
            self.debugMessage += logEntry
        } else {
            DispatchQueue.main.async {
                self.debugMessage += logEntry
            }
        }
    }

    // Sort Options
    enum SortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case date = "Date"
        case size = "Size"
        var id: String { rawValue }
    }

    @Published var sortOption: SortOption = .name {
        didSet { applySort() }
    }
    @Published var sortAscending: Bool = true {
        didSet { applySort() }
    }

    // Data
    @Published var currentPath: [String] = []  // Navigation stack (folders)
    @Published var objects: [S3Object] = []
    @Published var pendingDownloadURL: URL? = nil

    // Versioning
    @Published var selectedObjectVersions: [S3Version] = []
    @Published var isVersionsLoading = false
    @Published var isVersioningEnabled: Bool? = nil
    @Published var selectedObjectIsPublic: Bool? = nil
    @Published var isACLLoading = false

    private func applySort() {
        // Keep ".." at top
        let parentItems = objects.filter { $0.key == ".." }
        var content = objects.filter { $0.key != ".." }

        content.sort { lhs, rhs in
            if lhs.isFolder != rhs.isFolder { return lhs.isFolder }

            let ascending = self.sortAscending
            switch self.sortOption {
            case .name:
                return ascending ? lhs.key < rhs.key : lhs.key > rhs.key
            case .date:
                return ascending
                    ? lhs.lastModified < rhs.lastModified : lhs.lastModified > rhs.lastModified
            case .size:
                return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
            }
        }
        objects = parentItems + content
    }

    private var client: S3Client?

    private let kService = "com.antigravity.s3viewer"
    private let kAccount = "aws-secret"

    init() {
        loadConfig()
    }

    func loadConfig() {
        if let savedAccess = UserDefaults.standard.string(forKey: "accessKey") {
            accessKey = savedAccess
        }
        if let savedBucket = UserDefaults.standard.string(forKey: "bucket") { bucket = savedBucket }
        if let savedRegion = UserDefaults.standard.string(forKey: "region") { region = savedRegion }
        if let savedEndpoint = UserDefaults.standard.string(forKey: "endpoint") {
            endpoint = savedEndpoint
        }
        if UserDefaults.standard.object(forKey: "usePathStyle") != nil {
            usePathStyle = UserDefaults.standard.bool(forKey: "usePathStyle")
        }
        if let savedSecret = KeychainHelper.shared.read(service: kService, account: kAccount) {
            secretKey = savedSecret
        }
    }

    func connect() async {
        log("connect() called. Resetting state...")
        DispatchQueue.main.async {
            self.saveConfig()  // Save immediately when user clicks Connect
            self.isLoading = true
            self.errorMessage = nil
        }

        let newClient = S3Client(
            accessKey: accessKey, secretKey: secretKey, region: region, bucket: bucket,
            endpoint: endpoint, usePathStyle: usePathStyle)

        log("S3Client initialized. Testing connection to bucket: \(self.bucket)...")

        do {
            // Test connection by listing root
            let _ = try await newClient.listObjects(prefix: "")
            log("Connection test successful (Root listed).")

            DispatchQueue.main.async {
                self.log("Connection confirmed. Switching to logged in state.")
                self.client = newClient
                self.isLoggedIn = true
                self.isLoading = false
                self.saveConfig()
                self.loadObjects()
                self.refreshVersioningStatus()
            }
        } catch {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "Connection failed: \(error.localizedDescription)"
                self.log("[Connection Error] \(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        isLoggedIn = false
        client = nil
        objects = []
        currentPath = []
    }

    func loadObjects() {
        guard let client = client else { return }

        isLoading = true
        let prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"

        log("LOADING: \(prefix)")

        Task {
            do {
                let (fetchedObjects, debugInfo) = try await client.listObjects(prefix: prefix)
                DispatchQueue.main.async {
                    var finalObjects = fetchedObjects

                    // Synthetic ".." for Navigation
                    if !self.currentPath.isEmpty {
                        let parentObj = S3Object(
                            key: "..",  // Special identifier
                            size: 0,
                            lastModified: Date(),
                            isFolder: true
                        )
                        // Insert at top
                        finalObjects.insert(parentObj, at: 0)
                    }

                    self.objects = finalObjects
                    self.applySort()
                    self.log("Objects fetched. Parser logs: \n" + debugInfo)
                    self.isLoading = false
                    // Heuristic checks removed to prevent false positives hiding the file list
                    if !debugInfo.isEmpty {
                        self.log("Debug Info: " + debugInfo)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to list objects: \(error.localizedDescription)"
                    self.log("ERROR: \(error.localizedDescription)")
                    self.isLoading = false

                    // Auto-revert path on failure if not root
                    if !self.currentPath.isEmpty {
                        self.currentPath.removeLast()
                        self.log("-> Reverted path due to error.")
                    }
                }
            }
        }
    }

    func navigateTo(folder: String) {
        // Do not strip slashes. S3 keys/prefixes can contain slashes (e.g. `diskNAS/Config`).
        // We only trim whitespace if needed, but usually exact match is key.
        let targetFolder = folder
        guard !targetFolder.isEmpty else { return }

        currentPath.append(targetFolder)
        log("NAVIGATING TO: '\(targetFolder)'")
        loadObjects()
    }

    func navigateBack() {
        if !currentPath.isEmpty {
            currentPath.removeLast()
            loadObjects()
        }
    }

    func navigateHome() {
        currentPath.removeAll()
        loadObjects()
    }

    func downloadFile(key: String, versionId: String? = nil) {
        guard let client = client else { return }
        isLoading = true
        let logSuffix = versionId != nil ? " (Version: \(versionId!))" : ""
        log("[Download START] \(key)\(logSuffix)")
        Task {
            do {
                let (data, logs) = try await client.fetchObjectData(key: key, versionId: versionId)
                DispatchQueue.main.async {
                    self.log(logs)
                    self.log("[Download SUCCESS] Size: \(data.count) bytes")
                    self.saveFileToDisk(
                        data: data, filename: key.components(separatedBy: "/").last ?? "download")
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Le téléchargement a échoué : \(error.localizedDescription)"
                    self.log("[Download ERROR] \(error.localizedDescription)")
                    self.isLoading = false
                }
            }
        }
    }

    func loadACL(for key: String) {
        guard let client = client else { return }
        isACLLoading = true
        selectedObjectIsPublic = nil

        Task {
            do {
                let isPublic = try await client.getObjectACL(key: key)
                DispatchQueue.main.async {
                    self.selectedObjectIsPublic = isPublic
                    self.isACLLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isACLLoading = false
                    self.log("[ACL] Failed to load ACL: \(error.localizedDescription)")
                }
            }
        }
    }

    func togglePublicAccess(for key: String) {
        guard let client = client, let current = selectedObjectIsPublic else { return }
        let target = !current
        isACLLoading = true

        Task {
            do {
                try await client.setObjectACL(key: key, isPublic: target)
                DispatchQueue.main.async {
                    self.selectedObjectIsPublic = target
                    self.isACLLoading = false
                    self.showToast("File is now \(target ? "Public" : "Private")", type: .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isACLLoading = false
                    self.showToast(
                        "Failed to update permissions: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func refreshVersioningStatus() {
        guard let client = client else { return }
        Task {
            do {
                let status = try await client.getBucketVersioning()
                DispatchQueue.main.async {
                    self.isVersioningEnabled = status
                    self.log("[Versioning] Status: \(status ? "Enabled" : "Disabled")")
                }
            } catch {
                self.log("[Versioning] Failed to refresh status: \(error.localizedDescription)")
            }
        }
    }

    func toggleVersioning() {
        guard let client = client, let current = isVersioningEnabled else { return }
        let target = !current
        isLoading = true

        Task {
            do {
                try await client.putBucketVersioning(enabled: target)
                DispatchQueue.main.async {
                    self.isVersioningEnabled = target
                    self.isLoading = false
                    self.showToast("Versioning \(target ? "activé" : "désactivé")", type: .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.showToast(
                        "Échec de la mise à jour du versioning : \(error.localizedDescription)",
                        type: .error)
                }
            }
        }
    }

    func loadVersions(for key: String) {
        guard let client = client else { return }
        isVersionsLoading = true
        selectedObjectVersions = []

        // Also load ACL when loading versions (since it depends on the same selection)
        loadACL(for: key)

        log("[Versions] Loading for: \(key)")
        Task {
            do {
                let versions = try await client.listObjectVersions(key: key)
                DispatchQueue.main.async {
                    self.selectedObjectVersions = versions
                    self.isVersionsLoading = false
                    self.log("[Versions] Loaded \(versions.count) versions for \(key)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isVersionsLoading = false
                    self.log("[Versions] ERROR: \(error.localizedDescription)")
                    self.showToast(
                        "Échec du chargement des versions : \(error.localizedDescription)",
                        type: .error)
                }
            }
        }
    }

    // MARK: - File Operations

    func createFolder(name: String) {
        guard let client = client else { return }
        let prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"
        // Folder in S3 is just a key ending with "/"
        let folderKey = prefix + name + "/"

        isLoading = true
        Task {
            do {
                try await client.putObject(key: folderKey, data: nil)
                log("Folder Created: \(folderKey)")
                DispatchQueue.main.async { self.loadObjects() }
            } catch {
                DispatchQueue.main.async {
                    self.showToast(
                        "Création du dossier échouée : \(error.localizedDescription)", type: .error)
                    self.isLoading = false
                }
            }
        }
    }

    func uploadFile(url: URL) {
        guard let client = client else { return }

        // Security scoped resource check (for sandbox)
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent
            let prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"
            let key = prefix + filename

            isLoading = true
            log("[Upload START] \(filename) (\(data.count) bytes)")

            Task {
                do {
                    try await client.putObject(key: key, data: data)
                    log("[Upload SUCCESS] \(key)")
                    DispatchQueue.main.async { self.loadObjects() }
                } catch {
                    DispatchQueue.main.async {
                        self.showToast("Upload Failed: \(error.localizedDescription)", type: .error)
                        self.isLoading = false
                    }
                }
            }
        } catch {
            self.showToast(
                "Échec de la lecture du fichier : \(error.localizedDescription)", type: .error)
            log("[Upload ERROR] Read failed: \(error.localizedDescription)")
        }
    }

    func deleteObject(key: String) {
        guard let client = client else { return }
        log("[DELETE] Single Object: \(key)")
        isLoading = true
        Task {
            do {
                try await client.deleteObject(key: key)
                log("[DELETE SUCCESS] \(key)")
                DispatchQueue.main.async { self.loadObjects() }
            } catch {
                log("[DELETE ERROR] \(key): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showToast("Delete Failed: \(error.localizedDescription)", type: .error)
                    self.isLoading = false
                }
            }
        }
    }

    func deleteFolder(key: String) {
        guard let client = client else { return }
        log("[DELETE] Folder Recursive: \(key)")
        isLoading = true
        Task {
            do {
                try await client.deleteRecursive(prefix: key)
                log("[DELETE SUCCESS] Recursive Folder: \(key)")
                DispatchQueue.main.async { self.loadObjects() }
            } catch {
                log("[DELETE ERROR] Recursive Folder \(key): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.showToast(
                        "Delete Folder Failed: \(error.localizedDescription)", type: .error)
                    self.isLoading = false
                }
            }
        }
    }

    func renameObject(oldKey: String, newName: String, isFolder: Bool) {
        guard let client = client else { return }
        // Construct new key
        // If it's a folder, we must be careful. Renaming a folder in S3 is complex (Move all children).
        // For now, let's assume SIMPLE rename for files.
        // For folders, we'd need to list children and move them all. High complexity.
        // Given constraint of swift assistant, let's implement FILE rename first.
        // And simple Empty Folder Rename (which is just one object).
        // If specific logic needed for recursive move, that's a bigger task.

        let pathParts = oldKey.split(separator: "/")
        // Parent path is everything except last component
        var parentPath = ""
        if pathParts.count > 1 {
            parentPath = pathParts.dropLast().joined(separator: "/") + "/"
        }

        var newKey = parentPath + newName
        if isFolder { newKey += "/" }  // Ensure trailing slash if it was a folder

        isLoading = true
        Task {
            do {
                if isFolder {
                    // Recursive Move
                    try await client.renameFolderRecursive(oldPrefix: oldKey, newPrefix: newKey)
                } else {
                    // Simple File Move
                    try await client.copyObject(sourceKey: oldKey, destinationKey: newKey)
                    try await client.deleteObject(key: oldKey)
                }

                log("Renamed \(oldKey) to \(newKey)")
                DispatchQueue.main.async { self.loadObjects() }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.showToast("Rename Failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    // Stats
    func calculateFolderStats(folderKey: String) async -> (Int, Int64)? {
        guard let client = client else { return nil }
        do {
            return try await client.calculateFolderStats(prefix: folderKey)
        } catch {
            log("[Stats Error] \(error.localizedDescription)")
            return nil
        }
    }

    private func saveConfig() {
        UserDefaults.standard.set(accessKey, forKey: "accessKey")
        UserDefaults.standard.set(bucket, forKey: "bucket")
        UserDefaults.standard.set(region, forKey: "region")
        UserDefaults.standard.set(endpoint, forKey: "endpoint")
        UserDefaults.standard.set(usePathStyle, forKey: "usePathStyle")
        KeychainHelper.shared.save(secretKey, service: kService, account: kAccount)
    }

    var formattedStats: String {
        let count = objects.count
        let totalSize = objects.reduce(0) { $0 + $1.size }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        let sizeString = formatter.string(fromByteCount: totalSize)
        return "\(count) items • \(sizeString)"
    }

    private func saveFileToDisk(data: Data, filename: String) {
        #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    try? data.write(to: url)
                }
            }
        #else
            // iOS: Save to temporary and trigger share
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            do {
                try data.write(to: tempURL)
                log("[iOS] Ready to share: \(tempURL.lastPathComponent)")
                DispatchQueue.main.async {
                    self.pendingDownloadURL = tempURL
                }
            } catch {
                log("[iOS] Failed to save file: \(error.localizedDescription)")
            }
        #endif
    }
}
