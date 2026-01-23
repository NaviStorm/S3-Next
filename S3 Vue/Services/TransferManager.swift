import Combine
import Foundation
import SwiftUI

public final class TransferManager: ObservableObject {
    @Published var transferTasks: [TransferTask] = []
    private var activeTasks: [UUID: Task<Void, Never>] = [:]

    // Callbacks to communicate with AppState
    var onTransferCompleted: ((TransferType) -> Void)?
    var onTransferError: ((String) -> Void)?
    var logHandler: ((String) -> Void)?

    private func log(_ message: String) {
        logHandler?(message)
    }

    func cancelTask(id: UUID) {
        if let task = activeTasks[id] {
            task.cancel()
            activeTasks.removeValue(forKey: id)
            if let index = transferTasks.firstIndex(where: { $0.id == id }) {
                transferTasks[index].status = .cancelled
            }
            log("[TransferManager] Cancelled: \(id)")
        }
    }

    func uploadFile(url: URL, targetKey: String, client: S3Client, keyAlias: String?) {
        log("[TransferManager] Upload File Start: \(url.lastPathComponent)")

        let transferTask = TransferTask(
            type: .upload, name: url.lastPathComponent, progress: 0, status: .inProgress,
            totalFiles: 1,
            completedFiles: 0)
        let taskId = transferTask.id
        DispatchQueue.main.async { self.transferTasks.append(transferTask) }

        let task = Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            do {
                let data = try Data(contentsOf: url)

                // Handle Encryption (Note: we need to pass encryptIfRequested logic or duplicate it)
                // For now, let's assume we pass the final data and metadata or we do it here.
                // To keep it clean, let's keep encryption logic here as well.
                let (finalData, metadata) = try encryptDataIfNeeded(data: data, keyAlias: keyAlias)

                try await client.putObject(key: targetKey, data: finalData, metadata: metadata)

                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].completedFiles = 1
                        self.transferTasks[index].progress = 1.0
                        self.transferTasks[index].status = .completed
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.log("[TransferManager] Upload SUCCESS: \(targetKey)")
                    self.onTransferCompleted?(.upload)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferError?("Upload Failed: \(error.localizedDescription)")
                }
                log("[TransferManager] Upload ERROR: \(error.localizedDescription)")
            }
        }
        activeTasks[taskId] = task
    }

    func uploadFolder(url: URL, targetPrefix: String, client: S3Client, keyAlias: String?) {
        let folderName = url.lastPathComponent
        log("[TransferManager] Upload Folder Start: \(folderName)")

        let transferTask = TransferTask(
            type: .upload, name: folderName, progress: 0, status: .inProgress, totalFiles: 0,
            completedFiles: 0)
        let taskId = transferTask.id
        DispatchQueue.main.async { self.transferTasks.append(transferTask) }

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

                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].totalFiles = allFiles.count
                    }
                }

                var uploadCount = 0
                for fileURL in allFiles {
                    try Task.checkCancellation()
                    let fileURLPath = fileURL.path.precomposedStringWithCanonicalMapping
                    let baseUrlPath = url.path.precomposedStringWithCanonicalMapping

                    let relativePath = fileURLPath.replacingOccurrences(
                        of: baseUrlPath + "/", with: "")
                    let s3Key = targetPrefix + relativePath

                    let data = try Data(contentsOf: fileURL)
                    let (finalData, metadata) = try encryptDataIfNeeded(
                        data: data, keyAlias: keyAlias)

                    try await client.putObject(key: s3Key, data: finalData, metadata: metadata)
                    uploadCount += 1

                    await MainActor.run {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].completedFiles = uploadCount
                            self.transferTasks[index].progress =
                                Double(uploadCount) / Double(allFiles.count)
                        }
                    }
                }

                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferCompleted?(.upload)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                log("[TransferManager] Folder Upload ERROR: \(error.localizedDescription)")
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferError?("Échec de l'envoi du dossier")
                }
            }
        }
        activeTasks[taskId] = task
    }

    func downloadFile(
        key: String, versionId: String? = nil, client: S3Client,
        completion: @escaping (Data, String) -> Void
    ) {
        let filename = key.components(separatedBy: "/").last ?? "download"

        let downloadTask = TransferTask(
            type: .download, name: filename, progress: 0, status: .inProgress, totalFiles: 1,
            completedFiles: 0)
        let taskId = downloadTask.id
        DispatchQueue.main.async { self.transferTasks.append(downloadTask) }

        log("[TransferManager] Download START: \(key)")

        let task = Task {
            do {
                let metadata = try await client.headObject(key: key, versionId: versionId)
                var (data, _) = try await client.fetchObjectData(key: key, versionId: versionId)

                // Decrypt
                data = try decryptDataIfNeeded(data: data, metadata: metadata)

                await MainActor.run {
                    completion(data, filename)
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].completedFiles = 1
                        self.transferTasks[index].progress = 1.0
                        self.transferTasks[index].status = .completed
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.log("[TransferManager] Download SUCCESS: \(key)")
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferError?("Download Failed: \(error.localizedDescription)")
                }
                log("[TransferManager] Download ERROR: \(error.localizedDescription)")
            }
        }
        activeTasks[taskId] = task
    }

    func downloadFolder(key: String, client: S3Client, completion: @escaping (URL, String) -> Void)
    {
        let folderName = key.split(separator: "/").last ?? "download"
        let transferTask = TransferTask(
            type: .download, name: String(folderName), progress: 0, status: .inProgress,
            totalFiles: 0, completedFiles: 0)
        let taskId = transferTask.id
        DispatchQueue.main.async { self.transferTasks.append(transferTask) }

        log("[TransferManager] Download Folder Start: \(key)")

        let task = Task {
            do {
                let allObjects = try await client.listAllObjects(prefix: key)
                let filesToDownload = allObjects.filter { !$0.isFolder }

                log("[TransferManager] Found \(filesToDownload.count) files")

                await MainActor.run {
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

                    await MainActor.run {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].completedFiles = completedCount
                            self.transferTasks[index].progress =
                                Double(completedCount) / Double(filesToDownload.count)
                        }
                    }
                    log("[TransferManager] Saved \(relativePath)")
                }

                await MainActor.run {
                    completion(targetFolder, String(folderName))
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferCompleted?(.download)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                log("[TransferManager] Download Folder ERROR: \(error.localizedDescription)")
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferError?("Échec du téléchargement")
                }
            }
        }
        activeTasks[taskId] = task
    }

    func deleteFolder(key: String, client: S3Client) {
        log("[TransferManager] Delete Folder Start: \(key)")

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
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferCompleted?(.delete)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferError?("Delete Folder Failed: \(error.localizedDescription)")
                }
            }
        }
        activeTasks[taskId] = deleteTask
    }

    func renameFolder(oldKey: String, newKey: String, client: S3Client) {
        log("[TransferManager] Rename Folder Start: \(oldKey) -> \(newKey)")

        let task = TransferTask(
            type: .rename,
            name:
                "\(oldKey.components(separatedBy: "/").dropLast().last ?? "Folder") -> \(newKey.components(separatedBy: "/").dropLast().last ?? "New")",
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
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].totalFiles = total
                            self.transferTasks[index].completedFiles = completed
                            self.transferTasks[index].progress = Double(completed) / Double(total)
                        }
                    }
                }
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .completed
                        self.transferTasks[index].progress = 1.0
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferCompleted?(.rename)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .cancelled
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                }
            } catch {
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = .failed
                        self.transferTasks[index].errorMessage = error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.onTransferError?("Rename Folder Failed: \(error.localizedDescription)")
                }
            }
        }
        activeTasks[taskId] = renameTask
    }

    // Encryption Helpers (Extracted from AppState)
    private func encryptDataIfNeeded(data: Data, keyAlias: String?) throws -> (
        Data, [String: String]
    ) {
        guard let alias = keyAlias else { return (data, [:]) }

        if let keyData = KeychainHelper.shared.readData(service: "com.s3vue.keys", account: alias) {
            let encrypted = try CryptoService.shared.encryptData(data: data, keyData: keyData)
            let metadata = [
                "cse-enabled": "true",
                "cse-key-alias": alias,
            ]
            return (encrypted, metadata)
        } else {
            throw NSError(
                domain: "TransferManager", code: 403,
                userInfo: [NSLocalizedDescriptionKey: "Clé '\(alias)' introuvable"])
        }
    }

    private func decryptDataIfNeeded(data: Data, metadata: [String: String]) throws -> Data {
        let isCSE = metadata["x-amz-meta-cse-enabled"] == "true"
        let keyAlias = metadata["x-amz-meta-cse-key-alias"]

        if isCSE, let alias = keyAlias {
            if let keyData = KeychainHelper.shared.readData(
                service: "com.s3vue.keys", account: alias)
            {
                return try CryptoService.shared.decryptData(combinedData: data, keyData: keyData)
            } else {
                throw NSError(
                    domain: "TransferManager", code: 403,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Clé '\(alias)' introuvable pour le déchiffrement"
                    ])
            }
        }
        return data
    }
}
