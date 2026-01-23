import Foundation

/// Représente l'état d'un objet S3 à un instant T (Métadonnées uniquement)
struct S3ObjectSnapshot: Codable, Equatable {
    let key: String
    let size: Int64
    let lastModified: Date
    let eTag: String?
    let isFolder: Bool

    init(from object: S3Object) {
        self.key = object.key
        self.size = object.size
        self.lastModified = object.lastModified
        self.eTag = object.eTag
        self.isFolder = object.isFolder
    }
}

/// Représente une "photo" complète d'un bucket S3
struct S3Snapshot: Codable, Identifiable {
    let id: UUID
    let bucket: String
    let timestamp: Date
    let objectCount: Int

    /// Dictionnaire indexé par `key` pour des comparaisons en O(1)
    let objects: [String: S3ObjectSnapshot]

    init(bucket: String, objects: [S3Object]) {
        self.id = UUID()
        self.bucket = bucket
        self.timestamp = Date()
        self.objectCount = objects.count

        // On transforme la liste en dictionnaire pour les performances de comparaison
        var dict: [String: S3ObjectSnapshot] = [:]
        for obj in objects {
            dict[obj.key] = S3ObjectSnapshot(from: obj)
        }
        self.objects = dict
    }

    /// Nom d'affichage pour l'interface
    var displayName: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

/// Résultat d'une comparaison entre deux snapshots
struct SnapshotDiff {
    let added: [S3ObjectSnapshot]
    let removed: [S3ObjectSnapshot]
    let modified: [S3ObjectSnapshot]

    var hasChanges: Bool {
        !added.isEmpty || !removed.isEmpty || !modified.isEmpty
    }
}
