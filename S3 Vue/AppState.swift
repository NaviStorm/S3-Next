import Combine
import Foundation
import SwiftUI

public final class S3AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Toast
    @Published var toastMessage: String?
    @Published var toastType: ToastType = .info

    // Transfer Tasks
    @Published var transferTasks: [TransferTask] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

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

    func cancelTask(id: UUID) {
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks.removeValue(forKey: id)
            if let index = transferTasks.firstIndex(where: { $0.id == id }) {
                transferTasks[index].status = .cancelled
            }
            log("[Task] Cancelled: \(id)")
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
    @Published var selectedObjectMetadata: [String: String] = [:]
    @Published var quickLookURL: URL? = nil
    @Published var isACLLoading = false
    @Published var isMetadataLoading = false

    // CSE (Client Side Encryption)
    @Published var encryptionAliases: [String] = []
    @Published var selectedEncryptionAlias: String? = {
        UserDefaults.standard.string(forKey: "selectedEncryptionAlias")
    }()
    {
        didSet {
            UserDefaults.standard.set(selectedEncryptionAlias, forKey: "selectedEncryptionAlias")
        }
    }

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

        // Load CSE aliases
        if let savedAliases = UserDefaults.standard.stringArray(forKey: "encryptionAliases") {
            encryptionAliases = savedAliases
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
        let filename = key.components(separatedBy: "/").last ?? "download"

        var downloadTask = TransferTask(
            type: .download, name: filename, progress: 0, status: .inProgress, totalFiles: 1,
            completedFiles: 0)
        let taskId = downloadTask.id
        transferTasks.append(downloadTask)

        // Global isLoading is no longer set to true for transfers to avoid blocking the UI

        let logSuffix = versionId != nil ? " (Version: \(versionId!))" : ""
        log("[Download START] \(key)\(logSuffix)")

        let task = Task {
            do {
                // Fetch metadata first to check for encryption
                let metadata = try await client.headObject(key: key, versionId: versionId)
                var (data, _) = try await client.fetchObjectData(key: key, versionId: versionId)

                // Decrypt if needed
                data = try decryptIfNeeded(data: data, metadata: metadata)

                DispatchQueue.main.async {
                    self.saveFileToDisk(data: data, filename: filename)
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].completedFiles = 1
                        self.transferTasks[index].progress = 1.0
                        self.transferTasks[index].status = .completed
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.log("[Download SUCCESS] \(key)")
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast("Download Failed: \(error.localizedDescription)", type: .error)
                }
                self.log("[Download ERROR] \(error.localizedDescription)")
            }
        }
        activeTasks[taskId] = task
    }

    func previewFile(key: String, versionId: String? = nil) {
        guard let client = client else { return }
        let filename = key.components(separatedBy: "/").last ?? "preview"

        var previewTask = TransferTask(
            type: .download, name: filename, progress: 0, status: .inProgress, totalFiles: 1,
            completedFiles: 0)
        let taskId = previewTask.id
        transferTasks.append(previewTask)

        log("[Preview START] \(key)")

        let task = Task {
            do {
                // Metadata check for CSE
                let metadata = try await client.headObject(key: key, versionId: versionId)
                let isCSE = metadata["x-amz-meta-cse-enabled"] == "true"
                let keyAlias = metadata["x-amz-meta-cse-key-alias"]

                var (data, _) = try await client.fetchObjectData(key: key, versionId: versionId)

                if isCSE, let alias = keyAlias {
                    if let keyData = KeychainHelper.shared.readData(
                        service: "com.s3vue.keys", account: alias)
                    {
                        data = try CryptoService.shared.decryptData(
                            combinedData: data, keyData: keyData)
                        log("[CSE] Preview decryption successful")
                    } else {
                        throw NSError(
                            domain: "S3AppState", code: 403,
                            userInfo: [NSLocalizedDescriptionKey: "Clé introuvable"])
                    }
                }

                // Save to unique temp folder
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: tempDir, withIntermediateDirectories: true)
                let tempURL = tempDir.appendingPathComponent(filename)

                try data.write(to: tempURL)

                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].completedFiles = 1
                        self.transferTasks[index].progress = 1.0
                        self.transferTasks[index].status = .completed
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.quickLookURL = tempURL
                    self.log("[Preview SUCCESS] \(key) at \(tempURL.path)")
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast(
                        "Échec de l'aperçu : \(error.localizedDescription)", type: .error)
                }
                self.log("[Preview ERROR] \(error.localizedDescription)")
            }
        }
        activeTasks[taskId] = task
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

    func loadMetadata(for key: String) {
        guard let client = client else { return }
        isMetadataLoading = true
        selectedObjectMetadata = [:]

        Task {
            do {
                let metadata = try await client.headObject(key: key)
                DispatchQueue.main.async {
                    self.selectedObjectMetadata = metadata
                    self.isMetadataLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isMetadataLoading = false
                    self.log("[Metadata] Failed to load metadata: \(error.localizedDescription)")
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
        guard let client = client else {
            log("[Upload File] Error: Client is nil")
            return
        }
        log("[Upload File] Start: \(url.lastPathComponent)")

        let filename = url.lastPathComponent
        let prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"
        let key = prefix + filename

        var transferTask = TransferTask(
            type: .upload, name: filename, progress: 0, status: .inProgress, totalFiles: 1,
            completedFiles: 0)
        let taskId = transferTask.id
        transferTasks.append(transferTask)

        // Global isLoading is no longer set to true for transfers to avoid blocking the UI

        let task = Task {
            // Security scoped resource check (for sandbox)
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                var data = try Data(contentsOf: url)
                log("[Upload START] \(filename) (\(data.count) bytes)")

                // Handle Encryption via helper
                let (finalData, metadata) = try encryptIfRequested(
                    data: data, keyAlias: self.selectedEncryptionAlias)

                try await client.putObject(key: key, data: finalData, metadata: metadata)

                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].completedFiles = 1
                        self.transferTasks[index].progress = 1.0
                        self.transferTasks[index].status = .completed
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    // Reset selected alias after upload (on demand)
                    self.selectedEncryptionAlias = nil
                    self.log("[Upload SUCCESS] \(key)")
                    self.loadObjects()
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast("Upload Failed: \(error.localizedDescription)", type: .error)
                }
                self.log("[Upload ERROR] \(error.localizedDescription)")
            }
        }
        activeTasks[taskId] = task
    }

    func uploadFolder(url: URL) {
        guard let client = client else { return }

        let folderName = url.lastPathComponent
        let s3Prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"
        let targetPrefix = s3Prefix + folderName + "/"

        var transferTask = TransferTask(
            type: .upload, name: folderName, progress: 0, status: .inProgress, totalFiles: 0,
            completedFiles: 0)
        let taskId = transferTask.id
        transferTasks.append(transferTask)

        // Global isLoading is no longer set to true for transfers to avoid blocking the UI

        log("[Upload Folder START] \(folderName) -> \(targetPrefix)")

        log("[Upload Folder START] \(folderName) -> \(targetPrefix)")

        let task = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let fileManager = FileManager.default
                let enumerator = fileManager.enumerator(
                    at: url, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])

                var allFiles: [URL] = []
                while let fileURL = enumerator?.nextObject() as? URL {
                    let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    if resourceValues.isRegularFile == true {
                        allFiles.append(fileURL)
                    }
                }

                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].totalFiles = allFiles.count
                    }
                }

                var uploadCount = 0
                for fileURL in allFiles {
                    try Task.checkCancellation()
                    // Normaliser les chemins pour corriger les problèmes d'accents sur macOS (NFD vs NFC)
                    let fileURLPath = fileURL.path.precomposedStringWithCanonicalMapping
                    let baseUrlPath = url.path.precomposedStringWithCanonicalMapping

                    let relativePath = fileURLPath.replacingOccurrences(
                        of: baseUrlPath + "/", with: "")
                    let s3Key = targetPrefix + relativePath

                    log("[Upload Folder] Uploading: \(relativePath)...")
                    let data = try Data(contentsOf: fileURL)

                    // Handle Encryption
                    let (finalData, metadata) = try encryptIfRequested(
                        data: data, keyAlias: self.selectedEncryptionAlias)

                    try await client.putObject(key: s3Key, data: finalData, metadata: metadata)
                    uploadCount += 1

                    DispatchQueue.main.async {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].completedFiles = uploadCount
                            self.transferTasks[index].progress =
                                Double(uploadCount) / Double(allFiles.count)
                        }
                    }
                }

                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    // Reset selected alias after upload (on demand)
                    self.selectedEncryptionAlias = nil
                    self.showToast("Dossier envoyé avec succès", type: .success)
                    self.loadObjects()
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                log("[Upload Folder ERROR] \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast("Échec de l'envoi du dossier", type: .error)
                }
            }
        }
        activeTasks[taskId] = task
    }

    func downloadFolder(key: String) {
        guard let client = client else { return }

        let folderName = key.split(separator: "/").last ?? "download"
        var transferTask = TransferTask(
            type: .download, name: String(folderName), progress: 0, status: .inProgress,
            totalFiles: 0, completedFiles: 0)
        let taskId = transferTask.id
        transferTasks.append(transferTask)

        // Global isLoading is no longer set to true for transfers to avoid blocking the UI

        log("[Download Folder START] \(key)")

        let task = Task {
            do {
                let allObjects = try await client.listAllObjects(prefix: key)
                let filesToDownload = allObjects.filter { !$0.isFolder }

                log("[Download Folder] Found \(filesToDownload.count) files")

                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].totalFiles = filesToDownload.count
                    }
                }

                // We need a base directory to save into
                let fileManager = FileManager.default
                let tempBase = fileManager.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString, isDirectory: true)
                let targetFolder = tempBase.appendingPathComponent(
                    String(folderName), isDirectory: true)

                try fileManager.createDirectory(at: targetFolder, withIntermediateDirectories: true)

                var completedCount = 0
                for obj in filesToDownload {
                    try Task.checkCancellation()
                    let relativePath = obj.key.replacingOccurrences(of: key, with: "")
                    let localURL = targetFolder.appendingPathComponent(relativePath)

                    // Ensure subdirectory exists
                    try fileManager.createDirectory(
                        at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)

                    let (data, _) = try await client.fetchObjectData(key: obj.key)
                    try Task.checkCancellation()
                    try data.write(to: localURL)
                    completedCount += 1

                    DispatchQueue.main.async {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].completedFiles = completedCount
                            self.transferTasks[index].progress =
                                Double(completedCount) / Double(filesToDownload.count)
                        }
                    }
                    log("[Download Folder] Saved \(relativePath)")
                }

                DispatchQueue.main.async {
                    self.saveFolderToDisk(url: targetFolder)
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast("Dossier téléchargé", type: .success)
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                log("[Download Folder ERROR] \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast("Échec du téléchargement", type: .error)
                }
            }
        }
        activeTasks[taskId] = task
    }

    private func saveFolderToDisk(url: URL) {
        #if os(macOS)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Choisir"
            panel.message = "Le dossier sera copié dans l'emplacement choisi."

            panel.begin { response in
                if response == .OK, let destination = panel.url {
                    do {
                        // Use the original folder name if possible, or target URL's last component
                        let folderName = url.lastPathComponent
                        let finalDest = destination.appendingPathComponent(folderName)

                        if FileManager.default.fileExists(atPath: finalDest.path) {
                            try FileManager.default.removeItem(at: finalDest)
                        }
                        try FileManager.default.copyItem(at: url, to: finalDest)
                        self.showToast("Dossier '\(folderName)' sauvegardé !", type: .success)
                    } catch {
                        self.log("[macOS] Folder Save Error: \(error.localizedDescription)")
                        self.showToast(
                            "Erreur de sauvegarde : \(error.localizedDescription)", type: .error)
                    }
                }
            }
        #else
            // iOS: Share the folder via Share Sheet
            DispatchQueue.main.async {
                self.pendingDownloadURL = url
            }
        #endif
    }

    func deleteObject(key: String) {
        guard let client = client else { return }
        log("[DELETE] Single Object: \(key)")
        // Global isLoading is no longer set to true for single deletes
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

        let task = TransferTask(
            type: .delete,
            name: key,
            progress: 0,
            status: .inProgress,
            totalFiles: 0,
            completedFiles: 0
        )
        let taskId = task.id
        DispatchQueue.main.async { self.transferTasks.append(task) }

        let deleteTask = Task {
            do {
                try await client.deleteRecursive(prefix: key) { completed, total in
                    DispatchQueue.main.async {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].totalFiles = total
                            self.transferTasks[index].completedFiles = completed
                            self.transferTasks[index].progress = Double(completed) / Double(total)
                        }
                    }
                }
                log("[DELETE SUCCESS] Recursive Folder: \(key)")
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.loadObjects()
                    self.showToast("Dossier supprimé", type: .success)
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                log("[DELETE ERROR] Recursive Folder \(key): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.showToast(
                        "Delete Folder Failed: \(error.localizedDescription)", type: .error)
                }
            }
        }
        activeTasks[taskId] = deleteTask
    }

    func renameObject(oldKey: String, newName: String, isFolder: Bool) {
        guard let client = client else { return }
        log("[RENAME] From: \(oldKey) To Name: \(newName)")

        // Correct parent path calculation
        let parentPath: String
        let normalizedOldKey =
            oldKey.hasSuffix("/") && isFolder ? String(oldKey.dropLast()) : oldKey
        if let lastSlashIndex = normalizedOldKey.lastIndex(of: "/") {
            parentPath = String(normalizedOldKey[...lastSlashIndex])
        } else {
            parentPath = ""
        }

        var newKey = (parentPath + newName).precomposedStringWithCanonicalMapping
        if isFolder { newKey += "/" }

        if isFolder {
            let task = TransferTask(
                type: .rename,
                name: "\(oldKey) -> \(newName)",
                progress: 0,
                status: .inProgress,
                totalFiles: 0,
                completedFiles: 0
            )
            let taskId = task.id
            DispatchQueue.main.async { self.transferTasks.append(task) }

            let renameTask = Task {
                do {
                    try await client.renameFolderRecursive(oldPrefix: oldKey, newPrefix: newKey) {
                        completed, total in
                        DispatchQueue.main.async {
                            if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }
                            ) {
                                self.transferTasks[index].totalFiles = total
                                self.transferTasks[index].completedFiles = completed
                                self.transferTasks[index].progress =
                                    Double(completed) / Double(total)
                            }
                        }
                    }
                    log("Renamed folder \(oldKey) to \(newKey)")
                    DispatchQueue.main.async {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].status = .completed
                            self.transferTasks[index].progress = 1.0
                        }
                        self.activeTasks.removeValue(forKey: taskId)
                        self.loadObjects()
                        self.showToast("Dossier renommé avec succès", type: .success)
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].status = .cancelled
                        }
                        self.activeTasks.removeValue(forKey: taskId)
                    }
                } catch {
                    log("[RENAME ERROR] \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].status = .failed
                            self.transferTasks[index].errorMessage = error.localizedDescription
                        }
                        self.activeTasks.removeValue(forKey: taskId)
                        self.showToast(
                            "Rename Folder Failed: \(error.localizedDescription)", type: .error)
                    }
                }
            }
            activeTasks[taskId] = renameTask
        } else {
            // File rename is two steps (copy+delete), but fast.
            Task {
                do {
                    try await client.copyObject(sourceKey: oldKey, destinationKey: newKey)
                    try await client.deleteObject(key: oldKey)
                    log("Renamed file \(oldKey) to \(newKey)")
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.loadObjects()
                        self.showToast("Fichier renommé avec succès", type: .success)
                    }
                } catch {
                    log("[RENAME ERROR] \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.isLoading = false
                        self.showToast("Rename Failed: \(error.localizedDescription)", type: .error)
                    }
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

    func copyPresignedURL(for key: String, expires: Int) {
        guard let client = client else { return }
        do {
            let url = try client.generatePresignedURL(key: key, expirationSeconds: expires)
            let urlString = url.absoluteString

            #if os(macOS)
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(urlString, forType: .string)
            #else
                UIPasteboard.general.string = urlString
            #endif

            let hours = expires / 3600
            showToast("Lien de partage (\(hours)h) copié !", type: .success)
            log("Presigned URL copied for \(key) (expires in \(hours)h)")
        } catch {
            showToast(
                "Échec de la génération du lien : \(error.localizedDescription)", type: .error)
            log("[Presigned URL] ERROR: \(error.localizedDescription)")
        }
    }
}
