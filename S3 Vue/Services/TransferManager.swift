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

        let fileSize: Int64
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: url.path)
            fileSize = attr[.size] as? Int64 ?? 0
        } catch {
            fileSize = 0
        }

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
                if fileSize > 100 * 1024 * 1024 && keyAlias == nil {
                    // MULTIPART UPLOAD (Only for unencrypted for now to keep it safe/simple)
                    try await performMultipartUpload(
                        url: url, targetKey: targetKey, client: client, taskId: taskId,
                        fileSize: fileSize)
                } else {
                    // SIMPLE PUT
                    let data = try Data(contentsOf: url)
                    let (finalData, metadata) = try encryptDataIfNeeded(
                        data: data, keyAlias: keyAlias)
                    try await client.putObject(key: targetKey, data: finalData, metadata: metadata)

                    await MainActor.run {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].progress = 1.0
                            self.transferTasks[index].status = .completed
                        }
                    }
                }

                await MainActor.run {
                    self.activeTasks.removeValue(forKey: taskId)
                    self.log("[TransferManager] Upload SUCCESS: \(targetKey)")
                    self.onTransferCompleted?(.upload)
                }
            } catch {
                let nsError = error as NSError
                let isCancel =
                    error is CancellationError
                    || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)

                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = isCancel ? .cancelled : .failed
                        self.transferTasks[index].errorMessage =
                            isCancel ? nil : error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    if !isCancel {
                        self.onTransferError?("Upload Failed: \(error.localizedDescription)")
                    }
                }
                if isCancel {
                    log("[TransferManager] Upload CANCELLED: \(targetKey)")
                } else {
                    log("[TransferManager] Upload ERROR: \(error.localizedDescription)")
                }
            }
        }
        activeTasks[taskId] = task
    }

    private func performMultipartUpload(
        url: URL, targetKey: String, client: S3Client, taskId: UUID, fileSize: Int64
    ) async throws {
        log("[TransferManager] Checking for existing multipart uploads for: \(targetKey)")

        let allActive = (try? await client.listMultipartUploads()) ?? []
        var uploadId: String
        var existingParts: [Int: String] = [:]

        if let existing = allActive.first(where: { $0.key == targetKey }) {
            let existingId = existing.uploadId
            log("[TransferManager] Found existing UploadId: \(existingId). Resuming...")
            uploadId = existingId
            let fullExisting =
                (try? await client.listParts(key: targetKey, uploadId: uploadId)) ?? [:]

            let currentPartSize = 5 * 1024 * 1024
            if let firstPart = fullExisting.values.first, firstPart.size != Int64(currentPartSize) {
                log(
                    "[TransferManager] Part size mismatch (Server: \(firstPart.size), Local: \(currentPartSize)). RESTARTING UPLOAD."
                )
                try? await client.abortMultipartUpload(key: targetKey, uploadId: uploadId)
                uploadId = try await client.createMultipartUpload(key: targetKey)
            } else {
                for (num, data) in fullExisting {
                    existingParts[num] = data.etag
                }
                log("[TransferManager] Already have \(existingParts.count) valid parts on server.")
            }
        } else {
            log("[TransferManager] Initializing New Multipart Upload...")
            uploadId = try await client.createMultipartUpload(key: targetKey)
        }

        var parts: [Int: String] = existingParts
        let partSize: Int = 5 * 1024 * 1024  // 5 Mo pour plus de fluidité UI
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var partNumber = 1
        var uploadedBytes: Int64 = 0

        do {
            while uploadedBytes < fileSize {
                try Task.checkCancellation()

                let offset = UInt64(partNumber - 1) * UInt64(partSize)
                if offset >= UInt64(fileSize) { break }

                if parts[partNumber] != nil {
                    uploadedBytes = min(fileSize, Int64(offset) + Int64(partSize))
                    partNumber += 1

                    let progress = Double(uploadedBytes) / Double(fileSize)
                    await MainActor.run {
                        if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                            self.transferTasks[index].progress = progress
                        }
                    }
                    continue
                }

                try fileHandle.seek(toOffset: offset)
                guard let data = try fileHandle.read(upToCount: partSize), !data.isEmpty else {
                    break
                }

                log("[TransferManager] Uploading part \(partNumber)...")
                let etag = try await client.uploadPart(
                    key: targetKey, uploadId: uploadId, partNumber: partNumber, data: data)
                parts[partNumber] = etag

                uploadedBytes = min(fileSize, Int64(offset) + Int64(data.count))
                partNumber += 1

                let progress = Double(uploadedBytes) / Double(fileSize)
                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].progress = progress
                    }
                }
            }

            log("[TransferManager] Finalizing upload (\(parts.count) parts)...")
            try await client.completeMultipartUpload(
                key: targetKey, uploadId: uploadId, parts: parts)

            await MainActor.run {
                if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                    self.transferTasks[index].status = .completed
                    self.transferTasks[index].progress = 1.0
                }
            }
        } catch {
            let nsError = error as NSError
            let isCancel =
                error is CancellationError
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)

            if isCancel {
                log(
                    "[TransferManager] Multipart cancelled. UploadId \(uploadId) preserved for resume."
                )
            } else {
                log("[TransferManager] Multipart ERROR on part \(partNumber): \(error)")
            }
            throw error
        }
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
        completion: @escaping (URL, String) -> Void
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
                let sizeStr = metadata["content-length"] ?? "0"
                let totalSize = Int64(sizeStr) ?? 0
                log("[TransferManager] Download START: \(key) totalSize: \(totalSize)")

                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString
                ).appendingPathExtension((filename as NSString).pathExtension)

                if totalSize > 100 * 1024 * 1024 {
                    // LARGE FILE -> RANGE DOWNLOAD
                    log("[TransferManager] Taille importante, téléchargement par segments")
                    try await performRangeDownload(
                        key: key, versionId: versionId, client: client, taskId: taskId,
                        totalSize: totalSize, destinationURL: tempURL)
                } else {
                    // SMALL FILE -> STANDARD DOWNLOAD
                    var (data, _) = try await client.fetchObjectData(key: key, versionId: versionId)
                    data = try decryptDataIfNeeded(data: data, metadata: metadata)
                    try data.write(to: tempURL)
                }

                await MainActor.run {
                    completion(tempURL, filename)
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].completedFiles = 1
                        self.transferTasks[index].progress = 1.0
                        self.transferTasks[index].status = .completed
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    self.log("[TransferManager] Download SUCCESS: \(key)")
                }
            } catch {
                let nsError = error as NSError
                let isCancel =
                    error is CancellationError
                    || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)

                await MainActor.run {
                    if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                        self.transferTasks[index].status = isCancel ? .cancelled : .failed
                        self.transferTasks[index].errorMessage =
                            isCancel ? nil : error.localizedDescription
                    }
                    self.activeTasks.removeValue(forKey: taskId)
                    if !isCancel {
                        self.onTransferError?("Download Failed: \(error.localizedDescription)")
                    }
                }
                if isCancel {
                    log("[TransferManager] Download CANCELLED: \(key)")
                } else {
                    log("[TransferManager] Download ERROR: \(error.localizedDescription)")
                }
            }
        }
        activeTasks[taskId] = task
    }

    private func performRangeDownload(
        key: String, versionId: String? = nil, client: S3Client, taskId: UUID, totalSize: Int64,
        destinationURL: URL
    ) async throws {
        log("[performRangeDownload] Téléchargement par segments")
        // Supporter la reprise : si le fichier temporaire existe déjà, on vérifie sa taille
        var downloadedBytes: Int64 = 0
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let attr = try FileManager.default.attributesOfItem(atPath: destinationURL.path)
            downloadedBytes = attr[.size] as? Int64 ?? 0
            log(
                "[TransferManager] Found existing partial download (\(downloadedBytes) bytes). Resuming..."
            )
        } else {
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        }

        let partSize: Int64 = 5 * 1024 * 1024  // 5 Mo pour fluidité UI
        let fileHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? fileHandle.close() }

        if #available(iOS 13.4, macOS 10.15.4, *) {
            try fileHandle.seekToEnd()
        } else {
            fileHandle.seekToEndOfFile()
        }

        while downloadedBytes < totalSize {
            try Task.checkCancellation()

            let end = min(downloadedBytes + partSize - 1, totalSize - 1)
            let range = "bytes=\(downloadedBytes)-\(end)"

            let (data, _) = try await client.fetchObjectRange(
                key: key, versionId: versionId, range: range)
            try fileHandle.write(contentsOf: data)

            downloadedBytes += Int64(data.count)
            let progress = Double(downloadedBytes) / Double(totalSize)

            await MainActor.run {
                if let index = self.transferTasks.firstIndex(where: { $0.id == taskId }) {
                    self.transferTasks[index].progress = progress
                }
            }
        }
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
