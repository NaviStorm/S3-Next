import Foundation
import SwiftUI

enum TransferType: String, Codable {
    case upload
    case download
}

enum TransferStatus: String, Codable {
    case pending
    case inProgress
    case completed
    case failed
}

struct TransferTask: Identifiable {
    let id = UUID()
    let type: TransferType
    let name: String
    var progress: Double  // 0.0 to 1.0
    var status: TransferStatus
    var errorMessage: String?
    var totalFiles: Int
    var completedFiles: Int
}
