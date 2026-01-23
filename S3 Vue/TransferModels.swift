import Foundation
import SwiftUI

public enum TransferType: String, Codable {
    case upload
    case download
    case rename
    case delete
}

public enum TransferStatus: String, Codable {
    case pending
    case inProgress
    case completed
    case failed
    case cancelled
}

public struct TransferTask: Identifiable {
    public let id = UUID()
    public let type: TransferType
    public let name: String
    public var progress: Double  // 0.0 to 1.0
    public var status: TransferStatus
    public var errorMessage: String?
    public var totalFiles: Int
    public var completedFiles: Int
}
