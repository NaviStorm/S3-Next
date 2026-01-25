import Combine
import Foundation
import SwiftUI

public final class S3AppState: ObservableObject {
    @Published var isLoggedIn = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var bucketActionError: String?

    // Toast
    @Published var toastMessage: String?
    @Published var toastType: ToastType = .info

    // Transfer Management
    @Published var transferManager = TransferManager()

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
        transferManager.cancelTask(id: id)
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
    @Published var isHistoryLoading = false
    @Published var isOrphanLoading = false
    @Published var orphanUploads: [S3ActiveUpload] = []

    // Security (Object Lock & Legal Hold)
    @Published var selectedObjectRetention: S3ObjectRetention? = nil
    @Published var selectedObjectLegalHold: Bool = false
    @Published var isSecurityLoading = false
    @Published var bucketObjectLockEnabled: Bool? = nil

    // Lifecycle
    @Published var bucketLifecycleRules: [S3LifecycleRule] = []
    @Published var isLifecycleLoading = false

    // Activity History
    @Published var historyStartDate: Date =
        Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @Published var historyEndDate: Date = Date()
    @Published var historyResults: [S3Version] = []

    // Snapshots & Time Machine
    @Published var savedSnapshots: [S3Snapshot] = []
    @Published var isScanning = false
    @Published var scanProgress: Double = 0
    @Published var activeComparison: SnapshotDiff? = nil
    @Published var comparisonBaseId: UUID? = nil
    @Published var comparisonTargetId: UUID? = nil

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
    private var cancellables = Set<AnyCancellable>()

    private let kService = "com.antigravity.s3viewer"
    private let kAccount = "aws-secret"

    init() {
        loadConfig()
        setupTransferManager()
        loadSavedSnapshots()
    }

    private func setupTransferManager() {
        transferManager.logHandler = { [weak self] msg in
            self?.log(msg)
        }

        // Bridge TransferManager changes to AppState
        transferManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        transferManager.onTransferCompleted = { [weak self] type in
            if type == .upload || type == .delete || type == .rename {
                self?.loadObjects()
            }
            let msg =
                switch type {
                case .upload: "Transfert réussi"
                case .download: "Téléchargement terminé"
                case .delete: "Suppression terminée"
                case .rename: "Opération réussie"
                }
            self?.showToast(msg, type: .success)
        }
        transferManager.onTransferError = { [weak self] error in
            self?.showToast(error, type: .error)
        }
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

    @Published var availableBuckets: [String] = []

    func connect() async {
        log("connect() called. Resetting state...")
        DispatchQueue.main.async {
            self.saveConfig()  // Save immediately when user clicks Connect
            self.isLoading = true
            self.errorMessage = nil
            self.availableBuckets = []
        }

        let newClient = S3Client(
            accessKey: accessKey, secretKey: secretKey, region: region, bucket: bucket,
            endpoint: endpoint, usePathStyle: usePathStyle)

        if bucket.isEmpty {
            log("No bucket specified. Testing connection via listBuckets...")
        } else {
            log("S3Client initialized. Testing connection to bucket: \(self.bucket)...")
        }

        do {
            if bucket.isEmpty {
                let buckets = try await newClient.listBuckets()
                log("Connection test successful (Buckets listed: \(buckets.count)).")

                DispatchQueue.main.async {
                    self.client = newClient
                    self.isLoggedIn = true
                    self.isLoading = false
                    self.availableBuckets = buckets
                    self.saveConfig()
                }
            } else {
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
            }
        } catch {
            DispatchQueue.main.async {
                self.isLoading = false
                self.errorMessage = "Connection failed: \(error.localizedDescription)"
                self.log("[Connection Error] \(error.localizedDescription)")
            }
        }
    }

    func createBucket(name: String, objectLock: Bool, versioning: Bool, acl: String?) async {
        log(
            "createBucket() called for: \(name) (Versioning: \(versioning), ObjectLock: \(objectLock), ACL: \(acl ?? "none"))"
        )
        await MainActor.run {
            self.isLoading = true
            self.bucketActionError = nil
        }

        let createClient = S3Client(
            accessKey: accessKey, secretKey: secretKey, region: region, bucket: name,
            endpoint: endpoint, usePathStyle: usePathStyle)

        do {
            // 1. Create the bucket with Object Lock and ACL
            try await createClient.createBucket(objectLockEnabled: objectLock, acl: acl)
            log("Bucket created: \(name)")

            // 2. Enable versioning if requested (must be done after creation)
            if versioning {
                try await createClient.putBucketVersioning(enabled: true)
                log("Versioning enabled for: \(name)")
            }

            await MainActor.run {
                self.isLoading = false
                self.showToast("Bucket '\(name)' créé avec succès !", type: .success)
                // Automatically set as current bucket if successful creation
                self.bucket = name
                self.saveConfig()

                // Switch to the new bucket
                self.client = createClient
                self.isLoggedIn = true
                self.loadObjects()
                self.refreshVersioningStatus()
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.bucketActionError = "Failed to create bucket: \(error.localizedDescription)"
                self.log("[Create Bucket Error] \(error.localizedDescription)")
                self.showToast("Échec de création: \(error.localizedDescription)", type: .error)
            }
        }
    }

    func deleteBucket() async {
        guard let client = client else { return }

        log("deleteBucket() called for: \(self.bucket)")
        await MainActor.run {
            self.isLoading = true
        }

        do {
            try await client.deleteBucket()
            log("Bucket deleted: \(self.bucket)")

            await MainActor.run {
                self.isLoading = false
                self.showToast("Bucket '\(self.bucket)' supprimé avec succès !", type: .success)
                self.disconnect()
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                let errorMsg = error.localizedDescription
                self.log("[Delete Bucket Error] \(errorMsg)")

                if errorMsg.contains("BucketNotEmpty") {
                    self.showToast(
                        "Erreur : Le bucket n'est pas vide (versions cachées ?)", type: .error)
                } else {
                    self.showToast("Échec de suppression: \(errorMsg)", type: .error)
                }
            }
        }
    }

    func emptyAndDeleteBucket() async {
        guard let client = client else { return }
        let bucketName = self.bucket

        log("emptyAndDeleteBucket() started for: \(bucketName)")
        await MainActor.run { self.isLoading = true }

        do {
            // 1. Abort all multipart uploads
            log("[Step 1/3] Aborting all multipart uploads...")
            let uploads = try await client.listMultipartUploads()
            for upload in uploads {
                try? await client.abortMultipartUpload(key: upload.key, uploadId: upload.uploadId)
            }

            // 2. Delete all versions of all objects (including delete markers)
            log("[Step 2/3] Deleting all versions and delete markers...")
            let allVersions = try await client.listAllVersions(prefix: "")
            for version in allVersions {
                try await client.deleteObject(key: version.key, versionId: version.versionId)
            }

            // 3. Delete the bucket itself
            log("[Step 3/3] Deleting the bucket...")
            try await client.deleteBucket()

            await MainActor.run {
                self.isLoading = false
                self.showToast("Bucket '\(bucketName)' vidé et supprimé !", type: .success)
                self.disconnect()
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.log("[Force Delete Error] \(error.localizedDescription)")
                self.showToast(
                    "Échec du vidage/suppression: \(error.localizedDescription)", type: .error)
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
                            eTag: nil,
                            isFolder: true
                        )
                        // Insert at top
                        finalObjects.insert(parentObj, at: 0)
                    }

                    self.objects = finalObjects
                    self.injectRemovedObjects()
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

    func navigateToPath(at index: Int) {
        guard index >= 0 && index < currentPath.count else { return }
        currentPath = Array(currentPath.prefix(index + 1))
        log("NAVIGATING TO PATH DEPTH: \(index) (\(currentPath.last ?? "root"))")
        loadObjects()
    }

    func navigateHome() {
        currentPath.removeAll()
        loadObjects()
    }

    func downloadFile(key: String, versionId: String? = nil) {
        guard let client = client else { return }
        transferManager.downloadFile(key: key, versionId: versionId, client: client) {
            [weak self] url, filename in
            self?.saveDownloadedFile(url: url, filename: filename)
        }
    }

    func previewFile(key: String, versionId: String? = nil) {
        guard let client = client else { return }

        transferManager.downloadFile(key: key, versionId: versionId, client: client) {
            [weak self] url, filename in
            DispatchQueue.main.async {
                self?.quickLookURL = url
                self?.log("[Preview] File ready: \(url.path)")
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

    func loadBucketConfiguration() {
        guard let client = client else { return }
        Task {
            do {
                let enabled = try await client.getBucketObjectLockConfiguration()
                DispatchQueue.main.async {
                    self.bucketObjectLockEnabled = enabled
                }
            } catch {
                self.log("Error loading bucket object lock config: \(error)")
            }
        }
    }

    func loadSecurityStatus(for key: String) {
        guard let client = client else { return }
        isSecurityLoading = true
        selectedObjectRetention = nil
        selectedObjectLegalHold = false

        Task {
            do {
                let retention = try await client.getObjectRetention(key: key)
                let legalHold = try await client.getObjectLegalHold(key: key)
                DispatchQueue.main.async {
                    self.selectedObjectRetention = retention
                    self.selectedObjectLegalHold = legalHold
                    self.isSecurityLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSecurityLoading = false
                    self.log("[Security] Failed to load: \(error.localizedDescription)")
                }
            }
        }
    }

    func updateRetention(for key: String, mode: S3RetentionMode, until: Date) {
        guard let client = client else { return }
        isSecurityLoading = true

        Task {
            do {
                try await client.putObjectRetention(key: key, mode: mode, until: until)
                loadSecurityStatus(for: key)
                showToast("Rétention mise à jour", type: .success)
            } catch {
                DispatchQueue.main.async {
                    self.isSecurityLoading = false
                    self.showToast("Erreur rétention : \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func toggleLegalHold(for key: String) {
        guard let client = client else { return }
        let target = !selectedObjectLegalHold
        isSecurityLoading = true

        Task {
            do {
                try await client.putObjectLegalHold(key: key, enabled: target)
                loadSecurityStatus(for: key)
                showToast("Legal Hold \(target ? "activé" : "désactivé")", type: .success)
            } catch {
                DispatchQueue.main.async {
                    self.isSecurityLoading = false
                    self.showToast(
                        "Erreur Legal Hold : \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func loadHistory(for prefix: String) {
        guard let client = client else { return }
        isHistoryLoading = true
        historyResults = []

        log("[History] Searching prefix: \(prefix) from \(historyStartDate) to \(historyEndDate)")

        Task {
            do {
                let results = try await client.fetchHistory(
                    prefix: prefix, from: historyStartDate, to: historyEndDate)
                DispatchQueue.main.async {
                    self.historyResults = results
                    self.isHistoryLoading = false
                    self.log("[History] Found \(results.count) items.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isHistoryLoading = false
                    self.log("[History] ERROR: \(error.localizedDescription)")
                    self.showToast("Échec du chargement de l'historique", type: .error)
                }
            }
        }
    }

    func loadOrphanUploads() {
        guard let client = client else { return }
        isOrphanLoading = true
        orphanUploads = []

        Task {
            do {
                let uploads = try await client.listMultipartUploads()
                DispatchQueue.main.async {
                    self.orphanUploads = uploads
                    self.isOrphanLoading = false
                    self.log("[Orphans] Loaded \(uploads.count) active uploads.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isOrphanLoading = false
                    self.log("[Orphans] ERROR: \(error.localizedDescription)")
                }
            }
        }
    }

    func abortOrphanUpload(key: String, uploadId: String) {
        guard let client = client else { return }
        Task {
            do {
                try await client.abortMultipartUpload(key: key, uploadId: uploadId)
                DispatchQueue.main.async {
                    self.orphanUploads.removeAll { $0.uploadId == uploadId }
                    self.showToast("Transfert abandonné annulé", type: .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.showToast(
                        "Échec de l'annulation : \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func abortAllOrphanUploads() {
        guard let client = client else { return }
        let toAbort = orphanUploads
        isOrphanLoading = true

        Task {
            for upload in toAbort {
                try? await client.abortMultipartUpload(key: upload.key, uploadId: upload.uploadId)
            }
            DispatchQueue.main.async {
                self.orphanUploads = []
                self.isOrphanLoading = false
                self.showToast("Tous les transferts abandonnés ont été nettoyés", type: .success)
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
        let prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"
        let key = prefix + url.lastPathComponent

        transferManager.uploadFile(
            url: url, targetKey: key, client: client, keyAlias: self.selectedEncryptionAlias)
    }

    func uploadFolder(url: URL) {
        guard let client = client else { return }
        let s3Prefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"
        let targetPrefix = s3Prefix + url.lastPathComponent + "/"

        transferManager.uploadFolder(
            url: url, targetPrefix: targetPrefix, client: client,
            keyAlias: self.selectedEncryptionAlias)
    }

    func downloadFolder(key: String) {
        guard let client = client else { return }
        transferManager.downloadFolder(key: key, client: client) {
            [weak self] (url: URL, filename: String) in
            self?.saveFolderToDisk(url: url)
        }
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
        transferManager.deleteFolder(key: key, client: client)
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
            transferManager.renameFolder(oldKey: oldKey, newKey: newKey, client: client)
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

    func saveConfig() {
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

    private func saveDownloadedFile(url: URL, filename: String) {
        #if os(macOS)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = filename
            panel.begin { response in
                if response == .OK, let destination = panel.url {
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: url, to: destination)
                    } catch {
                        self.log("[macOS] Save Error: \(error.localizedDescription)")
                    }
                }
            }
        #else
            // iOS: trigger share sheet with the provided URL (already in temp)
            DispatchQueue.main.async {
                self.pendingDownloadURL = url
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

    // MARK: - Snapshots Logic

    func loadSavedSnapshots() {
        self.savedSnapshots = SnapshotManager.shared.loadSnapshots(for: self.bucket)
    }

    func takeSnapshot() {
        guard let client = client else { return }
        isScanning = true
        scanProgress = 0

        Task {
            do {
                log("[Snapshot] Starting full bucket scan for \(bucket)...")
                let allObjects = try await client.listAllObjects(prefix: "")

                let snapshot = S3Snapshot(bucket: self.bucket, objects: allObjects)
                try SnapshotManager.shared.save(snapshot)

                DispatchQueue.main.async {
                    self.loadSavedSnapshots()
                    self.isScanning = false
                    self.showToast("Snapshot capturé (\(allObjects.count) objets)", type: .success)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isScanning = false
                    self.showToast(
                        "Échec du snapshot : \(error.localizedDescription)", type: .error)
                }
            }
        }
    }

    func compareSnapshots(idA: UUID, idB: UUID) {
        guard let snapA = savedSnapshots.first(where: { $0.id == idA }),
            let snapB = savedSnapshots.first(where: { $0.id == idB })
        else { return }

        comparisonBaseId = idA
        comparisonTargetId = idB

        // On compare snapA (Base/Ancien) avec snapB (Cible/Récent)
        var added: [S3ObjectSnapshot] = []
        var removed: [S3ObjectSnapshot] = []
        var modified: [S3ObjectSnapshot] = []

        let keysA = Set(snapA.objects.keys)
        let keysB = Set(snapB.objects.keys)

        // Ajoutés dans B
        let addedKeys = keysB.subtracting(keysA)
        for key in addedKeys {
            if let obj = snapB.objects[key] { added.append(obj) }
        }

        // Supprimés de A
        let removedKeys = keysA.subtracting(keysB)
        for key in removedKeys {
            if let obj = snapA.objects[key] { removed.append(obj) }
        }

        // Communs : Vérifier modifications
        let commonKeys = keysA.intersection(keysB)
        for key in commonKeys {
            if let objA = snapA.objects[key], let objB = snapB.objects[key] {
                // On compare Taille et ETag
                if objA.size != objB.size || objA.eTag != objB.eTag {
                    modified.append(objB)
                }
            }
        }

        self.activeComparison = SnapshotDiff(added: added, removed: removed, modified: modified)
        log(
            "[Diff] Comparison complete: \(added.count) added, \(removed.count) removed, \(modified.count) modified."
        )

        // On injecte immédiatement les objets supprimés dans la vue actuelle
        injectRemovedObjects()
        applySort()
    }

    private func injectRemovedObjects() {
        guard let diff = activeComparison else { return }
        let currentPrefix = currentPath.isEmpty ? "" : currentPath.joined(separator: "/") + "/"

        // On filtre les objets supprimés qui appartiennent au dossier actuel
        // et on les transforme en S3Object pour l'affichage
        let removedInCurrentDir = diff.removed.filter { obj in
            let key = obj.key
            if !key.hasPrefix(currentPrefix) { return false }
            let relativeKey = String(key.dropFirst(currentPrefix.count))
            // On ne veut que les fichiers directs, pas ceux des sous-dossiers
            return !relativeKey.contains("/")
                || (relativeKey.hasSuffix("/") && relativeKey.filter { $0 == "/" }.count == 1)
        }.map { snap in
            S3Object(
                key: snap.key,
                size: snap.size,
                lastModified: snap.lastModified,
                eTag: snap.eTag,
                isFolder: snap.isFolder
            )
        }

        // Éviter les doublons si on rafraîchit
        for obj in removedInCurrentDir {
            if !self.objects.contains(where: { $0.key == obj.key }) {
                self.objects.append(obj)
            }
        }
    }

    func clearComparison() {
        activeComparison = nil
        comparisonBaseId = nil
        comparisonTargetId = nil
    }

    // MARK: - Lifecycle Management

    func loadLifecycleRules() {
        guard let client = self.client else { return }
        isLifecycleLoading = true

        Task {
            do {
                let rules = try await client.getBucketLifecycle()
                await MainActor.run {
                    self.bucketLifecycleRules = rules
                    self.isLifecycleLoading = false
                }
            } catch {
                await MainActor.run {
                    self.log("Erreur chargement Lifecycle: \(error.localizedDescription)")
                    self.isLifecycleLoading = false
                }
            }
        }
    }

    func saveLifecycleRules() {
        guard let client = self.client else { return }
        isLifecycleLoading = true

        let rulesToSave = bucketLifecycleRules

        Task {
            do {
                try await client.putBucketLifecycle(rules: rulesToSave)
                await MainActor.run {
                    self.showToast("Configuration Lifecycle mise à jour", type: .success)
                    self.isLifecycleLoading = false
                    self.loadLifecycleRules()  // Recharger pour confirmer
                }
            } catch {
                await MainActor.run {
                    self.errorMessage =
                        "Erreur mise à jour Lifecycle: \(error.localizedDescription)"
                    self.isLifecycleLoading = false
                }
            }
        }
    }

    func addLifecycleRule(_ rule: S3LifecycleRule) {
        bucketLifecycleRules.append(rule)
        saveLifecycleRules()
    }

    func deleteLifecycleRule(at index: Int) {
        guard index < bucketLifecycleRules.count else { return }
        bucketLifecycleRules.remove(at: index)
        saveLifecycleRules()
    }

    func selectBucket(named name: String) {
        log("selectBucket(named: \(name)) called.")
        DispatchQueue.main.async {
            self.bucket = name
            self.saveConfig()

            // Re-initialize client with the selected bucket
            self.client = S3Client(
                accessKey: self.accessKey, secretKey: self.secretKey, region: self.region,
                bucket: self.bucket,
                endpoint: self.endpoint, usePathStyle: self.usePathStyle)

            self.log("S3Client re-initialized for bucket: \(self.bucket)")

            self.loadObjects()
            self.refreshVersioningStatus()
        }
    }
}
