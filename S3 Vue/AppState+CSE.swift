import Foundation

extension S3AppState {

    // MARK: - Key Management

    func createEncryptionKey(alias: String) {
        let keyData = CryptoService.shared.generateSymmetricKey()
        KeychainHelper.shared.saveData(keyData, service: "com.s3vue.keys", account: alias)

        if !encryptionAliases.contains(alias) {
            encryptionAliases.append(alias)
            UserDefaults.standard.set(encryptionAliases, forKey: "encryptionAliases")
        }
        showToast("Clé '\(alias)' créée avec succès", type: .success)
    }

    func deleteEncryptionKey(alias: String) {
        KeychainHelper.shared.delete(service: "com.s3vue.keys", account: alias)
        encryptionAliases.removeAll { $0 == alias }
        UserDefaults.standard.set(encryptionAliases, forKey: "encryptionAliases")
        if selectedEncryptionAlias == alias { selectedEncryptionAlias = nil }
        showToast("Clé '\(alias)' supprimée", type: .info)
    }

    // MARK: - CSE Helpers

    func encryptIfRequested(data: Data, keyAlias: String?) throws -> (Data, [String: String]) {
        guard let alias = keyAlias else { return (data, [:]) }

        guard
            let keyData = KeychainHelper.shared.readData(service: "com.s3vue.keys", account: alias)
        else {
            throw NSError(
                domain: "S3AppState", code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey: "Clé '\(alias)' introuvable dans le Keychain."
                ])
        }

        log("[CSE] Encrypting with alias: \(alias)")
        let encryptedData = try CryptoService.shared.encryptData(data: data, keyData: keyData)

        let metadata = [
            "cse-enabled": "true",
            "cse-key-alias": alias,
        ]

        return (encryptedData, metadata)
    }

    func decryptIfNeeded(data: Data, metadata: [String: String]) throws -> Data {
        let isCSE =
            metadata["x-amz-meta-cse-enabled"] == "true" || metadata["cse-enabled"] == "true"
        let keyAlias = metadata["x-amz-meta-cse-key-alias"] ?? metadata["cse-key-alias"]

        guard isCSE, let alias = keyAlias else { return data }

        log("[CSE] Detecting encryption (alias: \(alias))")
        guard
            let keyData = KeychainHelper.shared.readData(service: "com.s3vue.keys", account: alias)
        else {
            throw NSError(
                domain: "S3AppState", code: 403,
                userInfo: [
                    NSLocalizedDescriptionKey: "Clé de déchiffrement '\(alias)' introuvable."
                ])
        }

        let decryptedData = try CryptoService.shared.decryptData(
            combinedData: data, keyData: keyData)
        log("[CSE] Decryption successful")
        return decryptedData
    }
}
