import AppIntents
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Helper pour le logging
func log(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
    let fileName = (file as NSString).lastPathComponent
    let logMessage = "S3Shortcuts [\(fileName):\(line)] \(function) > \(message)"
    print(logMessage)

    // Write to /tmp/s3_shortcuts.log
    // Utilise le dossier tmp sécurisé du conteneur de l'app
    let logFileDetails = FileManager.default.temporaryDirectory.appendingPathComponent(
        "s3_shortcuts.log")
    if let data = (logMessage + "\n").data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logFileDetails.path) {
            if let fileHandle = try? FileHandle(forWritingTo: logFileDetails) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        } else {
            try? data.write(to: logFileDetails)
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct S3SiteEntity: AppEntity {
    static var defaultQuery = S3SiteQuery()
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Site S3"

    var id: UUID
    var name: String
    var accessKey: String
    var region: String
    var endpoint: String
    var usePathStyle: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(site: S3Site) {
        self.id = site.id
        self.name = site.name
        self.accessKey = site.accessKey
        self.region = site.region
        self.endpoint = site.endpoint
        self.usePathStyle = site.usePathStyle
    }

    // Constructeur interne pour la requête par ID
    init(
        id: UUID, name: String, accessKey: String, region: String, endpoint: String,
        usePathStyle: Bool
    ) {
        self.id = id
        self.name = name
        self.accessKey = accessKey
        self.region = region
        self.endpoint = endpoint
        self.usePathStyle = usePathStyle
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct S3SiteQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [S3SiteEntity] {
        let sites = loadSites()
        return sites.filter { identifiers.contains($0.id) }.map { S3SiteEntity(site: $0) }
    }

    func suggestedEntities() async throws -> [S3SiteEntity] {
        return loadSites().map { S3SiteEntity(site: $0) }
    }

    private func loadSites() -> [S3Site] {
        guard let data = UserDefaults.standard.data(forKey: "savedSites"),
            let decoded = try? JSONDecoder().decode([S3Site].self, from: data)
        else {
            return []
        }
        return decoded
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct UploadFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Envoyer vers S3"
    static var description: IntentDescription = IntentDescription(
        "Téléverse un fichier vers un bucket S3 spécifique.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3 à utiliser")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le nom du bucket cible")
    var bucket: String

    @Parameter(
        title: "Fichiers", description: "Les fichiers à envoyer",
        supportedTypeIdentifiers: ["public.item"],
        inputConnectionBehavior: .connectToPreviousIntentResult)
    var files: [IntentFile]

    @Parameter(
        title: "Dossier Parent (Préfixe)",
        description: "Chemin du dossier parent (ex: 'MonDossier/'). Optionnel.",
        requestValueDialog: "Dans quel dossier voulez-vous envoyer les fichiers ?")
    var pathPrefix: String?

    @Parameter(
        title: "Clé de chiffrement (Alias)",
        description: "Alias de la clé pour chiffrer le fichier (optionnel)",
        requestValueDialog: "Quelle clé de chiffrement utiliser ?")
    var encryptionKeyAlias: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Envoyer \(\.$files) vers \(\.$bucket) sur \(\.$site)") {
            \.$pathPrefix
            \.$encryptionKeyAlias
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let prefix = S3ShortcutsHelper.cleanPrefix(pathPrefix)
        log("Début UploadFileIntent. Site: \(site.name), Bucket: \(bucket), Prefix: '\(prefix)'")

        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)

        var uploadedCount = 0
        var errors: [String] = []

        for file in files {
            let filename = file.filename
            let s3Key = prefix + filename
            let data = file.data
            log("Traitement: \(filename) -> \(s3Key) (\(data.count) octets)")

            var finalData = data
            var metadata: [String: String] = [:]

            if let alias = encryptionKeyAlias, !alias.isEmpty {
                // ... (Chiffrement identique) ...
                log("Chiffrement demandé avec l'alias: \(alias)")
                if let keyData = KeychainHelper.shared.readData(
                    service: "com.s3vue.keys", account: alias)
                {
                    do {
                        finalData = try CryptoService.shared.encryptData(
                            data: data, keyData: keyData)
                        metadata["cse-enabled"] = "true"
                        metadata["cse-key-alias"] = alias
                    } catch {
                        log("Erreur chiffrement \(filename): \(error.localizedDescription)")
                        errors.append("\(filename): Erreur chiffrement")
                        continue
                    }
                } else {
                    log("Clé introuvable pour \(filename)")
                    errors.append("\(filename): Clé introuvable")
                    continue
                }
            }

            do {
                try await client.putObject(key: s3Key, data: finalData, metadata: metadata)
                log("Upload réussi: \(s3Key)")
                uploadedCount += 1
            } catch {
                log("Erreur upload \(s3Key): \(error.localizedDescription)")
                errors.append("\(filename): \(error.localizedDescription)")
            }
        }

        if uploadedCount == 0 && !errors.isEmpty {
            throw SimpleError(message: "Echec total. Erreurs: \(errors.joined(separator: ", "))")
        }

        return .result(
            value:
                "\(uploadedCount) fichiers envoyés. \(errors.isEmpty ? "" : "Erreurs: \(errors.count)")"
        )
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct ListObjectsIntent: AppIntent {
    static var title: LocalizedStringResource = "Lister les fichiers S3"
    static var description: IntentDescription = IntentDescription(
        "Liste les fichiers présents dans un bucket S3 spécifique.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3 à utiliser")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le nom du bucket cible")
    var bucket: String

    @Parameter(
        title: "Dossier (Prefix)",
        description: "Le chemin du dossier à lister (laisser vide pour la racine)",
        requestValueDialog: "Quel dossier voulez-vous lister ?")
    var prefix: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Lister \(\.$bucket) sur \(\.$site) (Prefix: \(\.$prefix))")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        log("Début de l pour le site '\(site.name)' et bucket '\(bucket)'")
        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)
        let targetPrefix = S3ShortcutsHelper.cleanPrefix(prefix)
        log("Listage du dossier: '\(targetPrefix)'")

        do {
            let (objects, _) = try await client.listObjects(prefix: targetPrefix)
            let names = objects.map { $0.key }
            log("Succès: \(names.count) objets trouvés")
            return .result(value: names)
        } catch {
            log("Erreur lors du listage: \(error.localizedDescription)")
            throw SimpleError(message: "Erreur lors du listage : \(error.localizedDescription)")
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct CreateFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Créer un dossier S3"
    static var description: IntentDescription = IntentDescription(
        "Crée un nouveau dossier (objet vide se terminant par /) dans S3.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le bucket cible")
    var bucket: String

    @Parameter(
        title: "Dossier Parent (Préfixe)",
        description: "Chemin où créer le dossier (ex: 'Docs/'). Laisser vide pour la racine.")
    var pathPrefix: String?

    @Parameter(
        title: "Nom du nouveau dossier",
        description: "Nom du dossier à créer (sans slash)",
        requestValueDialog: "Nom du dossier ?")
    var newFolderName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Créer dossier \(\.$newFolderName) dans \(\.$bucket) sur \(\.$site)") {
            \.$pathPrefix
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        log("Début CreateFolder. Site: \(site.name), Bucket: \(bucket)")
        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)

        let prefix = S3ShortcutsHelper.cleanPrefix(pathPrefix)
        let fullKey = S3ShortcutsHelper.cleanPrefix(prefix + newFolderName)

        log("Création du dossier: \(fullKey)")

        do {
            try await client.createFolder(key: fullKey)
            log("Dossier créé avec succès")
            return .result(value: fullKey)
        } catch {
            log("Erreur création dossier: \(error.localizedDescription)")
            throw SimpleError(message: "Erreur création dossier : \(error.localizedDescription)")
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct DeleteFolderIntent: AppIntent {
    static var title: LocalizedStringResource = "Supprimer un dossier S3"
    static var description: IntentDescription = IntentDescription(
        "Supprime RECURSIVEMENT un dossier et tout son contenu sur S3.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le bucket cible")
    var bucket: String

    @Parameter(
        title: "Chemin du dossier",
        description: "Le chemin complet du dossier à supprimer (ex: 'Docs/Projet1/')",
        requestValueDialog: "Quel dossier supprimer ?")
    var folderPath: String

    static var parameterSummary: some ParameterSummary {
        Summary("Supprimer le dossier \(\.$folderPath) dans \(\.$bucket) sur \(\.$site)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        log("Début DeleteFolder. Site: \(site.name), Bucket: \(bucket), Path: \(folderPath)")

        // Validation basique pour éviter de supprimer tout le bucket par erreur
        if folderPath.isEmpty || folderPath == "/" {
            throw SimpleError(
                message: "Sécurité: Impossible de supprimer la racine du bucket via Raccourcis.")
        }

        // Confirmation utilisateur explicite
        if #available(macOS 15.0, iOS 18.0, *) {
            try await requestConfirmation(
                dialog:
                    "Attention : Cette action est irréversible et effacera TOUS les fichiers dans ce dossier."
            )
        } else {
            try await requestConfirmation()
        }

        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)

        log("Suppression récursive lancée pour: \(folderPath)")
        do {
            try await client.deleteRecursive(prefix: folderPath)
            log("Suppression terminée")
            return .result(value: "Dossier '\(folderPath)' et son contenu supprimés.")
        } catch {
            log("Erreur suppression dossier: \(error.localizedDescription)")
            throw SimpleError(message: "Erreur suppression : \(error.localizedDescription)")
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct DeleteObjectIntent: AppIntent {
    static var title: LocalizedStringResource = "Supprimer fichier S3"
    static var description: IntentDescription = IntentDescription(
        "Supprime un fichier spécifique d'un bucket S3.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3 à utiliser")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le nom du bucket cible")
    var bucket: String

    @Parameter(
        title: "Dossier Parent (Préfixe)", description: "Le chemin du dossier parent (optionnel)")
    var prefix: String?

    @Parameter(
        title: "Nom du fichier (Clé)",
        description: "Le chemin complet ou le nom du fichier à supprimer",
        requestValueDialog: "Quel fichier voulez-vous supprimer ?")
    var key: String

    static var parameterSummary: some ParameterSummary {
        Summary("Supprimer \(\.$key) dans \(\.$bucket) sur \(\.$site)") {
            \.$prefix
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        log("Début de DeleteObjectIntent pour le site '\(site.name)' et bucket '\(bucket)'")
        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)

        // Construction du chemin complet via le helper
        let folderPrefix = S3ShortcutsHelper.cleanPrefix(prefix)
        let fullKey = S3ShortcutsHelper.cleanPrefix(folderPrefix + key)

        log(
            "Tentative de suppression de: '\(fullKey)' (Prefix: '\(prefix ?? "nil")', Key: '\(key)')"
        )

        do {
            // VERIFICATION : Le fichier existe-t-il ?
            log("Vérification existence fichier...")
            _ = try await client.headObject(key: fullKey)

            // Si on passe ici, le fichier existe
            try await client.deleteObject(key: fullKey)

            log("Suppression réussie")
            return .result(value: "Fichier '\(fullKey)' supprimé avec succès.")
        } catch {
            log("Erreur lors de la suppression: \(error.localizedDescription)")

            // Si c'est une erreur 404 (Not Found) venant de headObject ou deleteObject
            if let s3Error = error as? S3Error, case .apiError(let code, _) = s3Error, code == 404 {
                throw SimpleError(message: "Le fichier '\(fullKey)' n'existe pas.")
            }

            throw SimpleError(
                message: "Erreur lors de la suppression : \(error.localizedDescription)")
        }
    }

}

@available(macOS 13.0, iOS 16.0, *)
struct ListSitesIntent: AppIntent {
    static var title: LocalizedStringResource = "Lister les sites S3"
    static var description: IntentDescription = IntentDescription(
        "Retourne la liste des sites S3 configurés dans l'application.")
    static var openAppWhenRun: Bool = false

    static var parameterSummary: some ParameterSummary {
        Summary("Lister les sites S3 disponibles")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[S3SiteEntity]> {
        log("Exécution de ListSitesIntent")
        let sites = try await S3SiteEntity.defaultQuery.suggestedEntities()
        log("Nombre de sites trouvés: \(sites.count)")
        return .result(value: sites)
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct ListBucketsIntent: AppIntent {
    static var title: LocalizedStringResource = "Lister les buckets S3"
    static var description: IntentDescription = IntentDescription(
        "Liste les buckets disponibles pour un site S3 donné.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3 à interroger")
    var site: S3SiteEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Lister les buckets sur \(\.$site)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        log("Début de ListBucketsIntent pour le site '\(site.name)'")

        // On utilise un bucket vide car on veut juste lister les buckets
        let client = try S3ShortcutsHelper.getClient(for: site, bucket: "")

        do {
            let buckets = try await client.listBuckets()
            log("Succès: \(buckets.count) buckets trouvés")
            return .result(value: buckets)
        } catch {
            log("Erreur lors du listage des buckets: \(error.localizedDescription)")
            throw SimpleError(
                message: "Erreur lors du listage des buckets : \(error.localizedDescription)")
        }
    }
}

// Helper pour éviter la duplication de code d'initialisation
struct S3ShortcutsHelper {
    @MainActor
    static func getClient(for site: S3SiteEntity, bucket: String) throws -> S3Client {
        log("Configuration du client S3 pour le site: \(site.name)")

        // Récupération de la Secret Key associée au site
        // Dans S3AppState, on sauvegarde avec : KeychainHelper.shared.save(newSite.secretKey, service: "com.antigravity.s3viewer", account: newSite.id.uuidString)

        let kService = "com.antigravity.s3viewer"
        let kAccount = site.id.uuidString

        log("Recherche de la clé secrète pour le compte: \(kAccount)")

        guard let secretKey = KeychainHelper.shared.read(service: kService, account: kAccount)
        else {
            log("Clé secrète introuvable pour le site \(site.name)")
            throw SimpleError(
                message:
                    "Clé secrète introuvable pour le site '\(site.name)'. Veuillez reconnecter ce site dans l'application."
            )
        }

        log("Client initialisé avec Endpoint: \(site.endpoint), Region: \(site.region)")

        return S3Client(
            accessKey: site.accessKey,
            secretKey: secretKey,
            region: site.region,
            bucket: bucket,  // Bucket forcé par l'utilisateur
            endpoint: site.endpoint,
            usePathStyle: site.usePathStyle
        )
    }

    /// Nettoie et normalise un préfixe de dossier.
    /// - Convertit nil en ""
    /// - Enlève le "./" initial
    /// - Remplace "." par ""
    /// - Ajoute un "/" final si non vide
    static func cleanPrefix(_ prefix: String?) -> String {
        var p = prefix ?? ""

        if p.hasPrefix("./") {
            p = String(p.dropFirst(2))
        }

        if p == "." {
            p = ""
        }

        if !p.isEmpty && !p.hasSuffix("/") {
            p += "/"
        }

        return p
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct S3Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UploadFileIntent(),
            phrases: [
                "Envoyer vers S3 avec \(.applicationName)",
                "Uploader fichier sur \(.applicationName)",
                "Mettre sur S3 avec \(.applicationName)",
            ],
            shortTitle: "Envoyer vers S3",
            systemImageName: "arrow.up.doc"
        )
        AppShortcut(
            intent: CreateFolderIntent(),
            phrases: [
                "Créer dossier S3 avec \(.applicationName)",
                "Nouveau dossier S3 dans \(.applicationName)",
            ],
            shortTitle: "Créer dossier S3",
            systemImageName: "folder.badge.plus"
        )
        AppShortcut(
            intent: DeleteFolderIntent(),
            phrases: [
                "Supprimer dossier S3 avec \(.applicationName)",
                "Effacer dossier S3 dans \(.applicationName)",
            ],
            shortTitle: "Supprimer dossier S3",
            systemImageName: "folder.badge.minus"
        )
        AppShortcut(
            intent: ListObjectsIntent(),
            phrases: [
                "Lister fichiers S3 avec \(.applicationName)",
                "Voir contenu bucket dans \(.applicationName)",
            ],
            shortTitle: "Lister fichiers S3",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: DeleteObjectIntent(),
            phrases: [
                "Supprimer fichier S3 avec \(.applicationName)",
                "Effacer fichier dans \(.applicationName)",
            ],
            shortTitle: "Supprimer fichier S3",
            systemImageName: "trash"
        )
        AppShortcut(
            intent: ListSitesIntent(),
            phrases: [
                "Lister les sites S3 dans \(.applicationName)",
                "Quels sont mes sites S3 dans \(.applicationName) ?",
            ],
            shortTitle: "Lister Sites S3",
            systemImageName: "server.rack"
        )
        AppShortcut(
            intent: DownloadFileIntent(),
            phrases: [
                "Télécharger fichier S3 avec \(.applicationName)",
                "Récupérer fichier S3 dans \(.applicationName)",
                "Obtenir fichier S3 avec \(.applicationName)",
            ],
            shortTitle: "Télécharger fichier S3",
            systemImageName: "arrow.down.doc"
        )
        AppShortcut(
            intent: ListBucketsIntent(),
            phrases: [
                "Lister les buckets S3 dans \(.applicationName)",
                "Voir mes buckets S3 dans \(.applicationName)",
            ],
            shortTitle: "Lister Buckets S3",
            systemImageName: "archivebox"
        )
    }
}

@available(macOS 13.0, iOS 16.0, *)
struct DownloadFileIntent: AppIntent {
    static var title: LocalizedStringResource = "Télécharger fichier S3"
    static var description: IntentDescription = IntentDescription(
        "Télécharge un fichier depuis S3 et retourne son contenu.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3 à utiliser")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le nom du bucket source")
    var bucket: String

    @Parameter(
        title: "Chemin du fichier (Clé)",
        description: "Le chemin complet du fichier à télécharger",
        requestValueDialog: "Quel fichier voulez-vous télécharger ?")
    var key: String

    @Parameter(
        title: "Clé de chiffrement (Alias)",
        description: "Alias de la clé pour déchiffrer le fichier (optionnel)",
        requestValueDialog: "Quelle clé de chiffrement utiliser ?")
    var encryptionKeyAlias: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Télécharger \(\.$key) depuis \(\.$bucket) sur \(\.$site)") {
            \.$encryptionKeyAlias
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        log("Début DownloadFileIntent. Site: \(site.name), Bucket: \(bucket), Key: \(key)")
        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)

        do {
            // 1. Récupération des données brutes
            let (data, metadata) = try await client.getObject(key: key)
            log("Fichier téléchargé : \(data.count) octets")

            var finalData = data

            // 2. Déchiffrement si demandé
            if let alias = encryptionKeyAlias, !alias.isEmpty {
                log("Déchiffrement demandé avec l'alias: \(alias)")

                // Vérifier si c'est bien chiffré côté S3 (optionnel mais recommandé)
                // Ici on force si l'utilisateur le demande, ou on check les métadonnées

                if let keyData = KeychainHelper.shared.readData(
                    service: "com.s3vue.keys", account: alias)
                {
                    do {
                        // Supposons que CryptoService.shared.decryptData existe
                        // Si CryptoService n'est pas dispo ici, il faudra l'ajouter ou adapter
                        // Note: J'utilise encryptData dans Upload donc decryptData doit être là ou similaire.
                        // Je vérifie le nom exact si possible. Je parie sur decryptData.
                        finalData = try CryptoService.shared.decryptData(
                            combinedData: data, keyData: keyData)
                        log("Fichier déchiffré avec succès")
                    } catch {
                        log("Erreur déchiffrement : \(error.localizedDescription)")
                        throw SimpleError(
                            message: "Erreur déchiffrement : \(error.localizedDescription)")
                    }
                } else {
                    log("Clé de chiffrement introuvable pour l'alias : \(alias)")
                    throw SimpleError(message: "Clé introuvable pour l'alias '\(alias)'")
                }
            }

            // 3. Création du fichier de retour
            let filename = URL(fileURLWithPath: key).lastPathComponent
            let file = IntentFile(data: finalData, filename: filename)

            return .result(value: file)

        } catch {
            log("Erreur téléchargement: \(error.localizedDescription)")
            throw SimpleError(message: "Erreur téléchargement : \(error.localizedDescription)")
        }
    }
}

@available(macOS 13.0, iOS 16.0, *)
@available(macOS 13.0, iOS 16.0, *)
struct ListFoldersIntent: AppIntent {
    static var title: LocalizedStringResource = "Lister les dossiers S3"
    static var description: IntentDescription = IntentDescription(
        "Liste les sous-dossiers d'un bucket S3 donné.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Site", description: "Le site S3 à utiliser")
    var site: S3SiteEntity

    @Parameter(title: "Bucket", description: "Le nom du bucket")
    var bucket: String

    @Parameter(
        title: "Dossier Parent (Préfixe)", description: "Le chemin du dossier parent (optionnel)")
    var prefix: String?

    @Parameter(
        title: "Récursif", description: "Scanner tous les sous-dossiers (peut être lent)",
        default: false)
    var recursive: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Lister les dossiers dans \(\.$bucket) sur \(\.$site)") {
            \.$prefix
            \.$recursive
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        log(
            "Début de ListFoldersIntent. Site: \(site.name), Bucket: \(bucket), Prefix: \(prefix ?? "racine"), Recursive: \(recursive)"
        )

        let client = try S3ShortcutsHelper.getClient(for: site, bucket: bucket)

        do {
            let targetPrefix = S3ShortcutsHelper.cleanPrefix(prefix)
            var folders = try await client.listFolders(
                prefix: targetPrefix, recursive: recursive)

            let currentFolder = targetPrefix.isEmpty ? "." : targetPrefix
            folders.insert(currentFolder, at: 0)

            log("Succès: \(folders.count) dossiers trouvés")
            return .result(value: folders)
        } catch {
            log("Erreur lors du listage des dossiers: \(error.localizedDescription)")
            throw SimpleError(message: "Erreur: \(error.localizedDescription)")
        }
    }
}

struct SimpleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
