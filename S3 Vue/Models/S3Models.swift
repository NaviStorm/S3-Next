import Foundation
import SwiftUI

enum S3Error: Error, LocalizedError {
    case invalidUrl
    case requestFailed(Error)
    case invalidResponse
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidUrl: return "Configuration d'URL invalide."
        case .requestFailed(let error):
            return "La requête réseau a échoué : \(error.localizedDescription)"
        case .invalidResponse: return "Réponse du serveur invalide."
        case .apiError(let statusCode, let body): return "Erreur API \(statusCode) : \(body)"
        }
    }
}

public struct S3Object: Identifiable, Hashable {
    public var id: String { key }
    public let key: String
    public let size: Int64
    public let lastModified: Date
    public let eTag: String?
    public let isFolder: Bool
}

public struct S3Version: Identifiable, Hashable {
    public var id: String { key + versionId }
    public let key: String
    public let versionId: String
    public let isLatest: Bool
    public let lastModified: Date
    public let size: Int64
    public let isDeleteMarker: Bool
}

public enum ToastType {
    case info
    case error
    case success
    case warning

    public var color: Color {
        switch self {
        case .info: return .blue
        case .error: return .red
        case .success: return .green
        case .warning: return .orange
        }
    }

    public var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}
