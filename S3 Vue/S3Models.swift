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

struct S3Object: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let size: Int64
    let lastModified: Date
    let isFolder: Bool
}

struct S3Version: Identifiable, Hashable {
    var id: String { versionId }
    let key: String
    let versionId: String
    let isLatest: Bool
    let lastModified: Date
    let size: Int64
    let isDeleteMarker: Bool
}

enum ToastType {
    case info
    case error
    case success
    case warning

    var color: Color {
        switch self {
        case .info: return .blue
        case .error: return .red
        case .success: return .green
        case .warning: return .orange
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}
