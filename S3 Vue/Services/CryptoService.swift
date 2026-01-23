import CryptoKit
import Foundation

public final class CryptoService {
    public static let shared = CryptoService()
    private init() {}

    /// Génère une nouvelle clé symétrique de 256 bits
    public func generateSymmetricKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Chiffre des données avec AES-GCM et retourne les données combinées
    public func encryptData(data: Data, keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(
                domain: "CryptoService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Échec du chiffrement combiné"])
        }
        return combined
    }

    /// Déchiffre des données avec AES-GCM
    public func decrypt(combinedData: Data, keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    /// Chiffre un fichier et retourne les données combinées (nonce + ciphertext + tag)
    public func encryptFile(at url: URL, keyData: Data) throws -> Data {
        let data = try Data(contentsOf: url)
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.seal(data, using: key)
        guard let combined = sealedBox.combined else {
            throw NSError(
                domain: "CryptoService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Échec du chiffrement combiné"])
        }
        return combined
    }

    /// Déchiffre des données combinées et retourne les données originales
    public func decryptData(combinedData: Data, keyData: Data) throws -> Data {
        let key = SymmetricKey(data: keyData)
        let sealedBox = try AES.GCM.SealedBox(combined: combinedData)
        return try AES.GCM.open(sealedBox, using: key)
    }
}
