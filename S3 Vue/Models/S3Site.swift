import Foundation

struct S3Site: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var accessKey: String
    var region: String
    var bucket: String
    var endpoint: String
    var usePathStyle: Bool

    init(
        id: UUID = UUID(),
        name: String,
        accessKey: String,
        region: String,
        bucket: String,
        endpoint: String,
        usePathStyle: Bool
    ) {
        self.id = id
        self.name = name
        self.accessKey = accessKey
        self.region = region
        self.bucket = bucket
        self.endpoint = endpoint
        self.usePathStyle = usePathStyle
    }
}
