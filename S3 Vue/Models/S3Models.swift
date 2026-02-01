import Foundation
import SwiftUI

public enum S3Error: Error, LocalizedError {
    case invalidUrl
    case requestFailed(Error)
    case invalidResponse
    case apiError(Int, String)

    public var errorDescription: String? {
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

public struct S3ActiveUpload: Identifiable, Hashable {
    public var id: String { uploadId }
    public let key: String
    public let uploadId: String
    public let initiated: Date
}

public enum S3RetentionMode: String, Codable {
    case governance = "GOVERNANCE"
    case compliance = "COMPLIANCE"
}

public struct S3ObjectRetention: Hashable {
    public let mode: S3RetentionMode
    public let retainUntilDate: Date
}

public struct S3LegalHold: Hashable {
    public let status: Bool  // true = ON, false = OFF
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

// MARK: - Lifecycle Policies

public enum S3LifecycleStatus: String, Codable {
    case enabled = "Enabled"
    case disabled = "Disabled"
}

public struct S3LifecycleTransition: Hashable {
    public var days: Int?
    public var storageClass: String

    public init(days: Int? = nil, storageClass: String) {
        self.days = days
        self.storageClass = storageClass
    }
}

public struct S3LifecycleExpiration: Hashable {
    public var days: Int?

    public init(days: Int? = nil) {
        self.days = days
    }
}

public struct S3LifecycleRule: Identifiable, Hashable {
    public var id: String
    public var status: S3LifecycleStatus
    public var prefix: String
    public var transitions: [S3LifecycleTransition]
    public var expiration: S3LifecycleExpiration?
    public var abortIncompleteMultipartUploadDays: Int?

    public init(
        id: String = UUID().uuidString,
        status: S3LifecycleStatus = .enabled,
        prefix: String = "",
        transitions: [S3LifecycleTransition] = [],
        expiration: S3LifecycleExpiration? = nil,
        abortIncompleteMultipartUploadDays: Int? = 7
    ) {
        self.id = id
        self.status = status
        self.prefix = prefix
        self.transitions = transitions
        self.expiration = expiration
        self.abortIncompleteMultipartUploadDays = abortIncompleteMultipartUploadDays
    }
}
