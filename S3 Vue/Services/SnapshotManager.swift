import Foundation

/// Gère la lecture et l'écriture des snapshots sur le disque local
class SnapshotManager {
    static let shared = SnapshotManager()

    private let fileManager = FileManager.default

    private var snapshotsDirectory: URL? {
        guard
            let appSupport = fileManager.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        else {
            return nil
        }
        let url = appSupport.appendingPathComponent("S3 Vue/Snapshots", isDirectory: true)

        // Créer le dossier s'il n'existe pas
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }

        return url
    }

    /// Enregistre un nouveau snapshot sur le disque
    func save(_ snapshot: S3Snapshot) throws {
        guard let dir = snapshotsDirectory else {
            throw NSError(
                domain: "SnapshotManager", code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Impossible d'accéder au dossier Application Support"
                ])
        }

        let filename = "\(snapshot.bucket)_\(snapshot.id.uuidString).json"
        let fileURL = dir.appendingPathComponent(filename)

        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL)
    }

    /// Charge tous les snapshots disponibles pour un bucket spécifique
    func loadSnapshots(for bucket: String) -> [S3Snapshot] {
        guard let dir = snapshotsDirectory else { return [] }

        do {
            let files = try fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
            let bucketFiles = files.filter {
                $0.lastPathComponent.hasPrefix(bucket + "_") && $0.pathExtension == "json"
            }

            return bucketFiles.compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(S3Snapshot.self, from: data)
            }.sorted(by: { $0.timestamp > $1.timestamp })  // Plus récent en premier

        } catch {
            return []
        }
    }

    /// Supprime un snapshot spécifique
    func delete(_ snapshot: S3Snapshot) {
        guard let dir = snapshotsDirectory else { return }
        let filename = "\(snapshot.bucket)_\(snapshot.id.uuidString).json"
        let fileURL = dir.appendingPathComponent(filename)
        try? fileManager.removeItem(at: fileURL)
    }
}
