import CommonCrypto
import Foundation
import SwiftUI

@main
struct S3_VueApp: App {
    @StateObject private var appState = S3AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #if os(macOS)
            .commands {
                CommandMenu("Débogage") {
                    OpenDebugWindowButton()
                }
            }
        #endif

        #if os(macOS)
            Window("Logs de débogage", id: "debug-logs") {
                DebugView()
                    .environmentObject(appState)
            }
        #endif

        #if os(macOS)
            Settings {
                SettingsView()
                    .environmentObject(appState)
            }
        #endif
    }
}

#if os(macOS)
    struct OpenDebugWindowButton: View {
        @Environment(\.openWindow) var openWindow

        var body: some View {
            Button("Afficher les logs de débogage") {
                openWindow(id: "debug-logs")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
        }
    }
#endif

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

    // Explicit Hashable/Equatable not strictly needed if we just rely on all fields,
    // but relying on 'key' for Identity is crucial.
    // However, if two objects have same key but different size/date (updates), they should probably be considered "updated".
    // But for SELECTION stability, ID must be Key.
    // For Equatable, we want to know if specific instance changed.
    // Default synthesized Equatable compares all stored properties.
    // computed 'id' is not stored.
    // So '==': compares key, size, lastModified, isFolder.
    // This is perfect.
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

class S3Client {
    private let accessKey: String
    private let secretKey: String
    private let region: String
    private let bucket: String
    private let endpoint: String
    private let usePathStyle: Bool

    init(
        accessKey: String, secretKey: String, region: String, bucket: String, endpoint: String,
        usePathStyle: Bool
    ) {
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.region = region
        self.bucket = bucket
        self.endpoint = endpoint
        self.usePathStyle = usePathStyle
    }

    // MARK: - Public API

    func listObjects(prefix: String = "") async throws -> ([S3Object], String) {
        // ... (lines 66-131 same)
        // I need to be careful not to delete the body. I will use a precise TargetContent.
        // Custom encoding: URLQueryAllowed BUT encode slashes '/' as %2F and '@', ':', etc.
        // AWS requires strict encoding for query params in signature
        let letAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~"))  // Standard unreserved characters
        // Do NOT include '/' or '@' or ':' in allowed, so they get percent-encoded

        let encodedPrefix =
            prefix.addingPercentEncoding(withAllowedCharacters: letAllowed) ?? prefix

        let urlString: String
        if !endpoint.isEmpty {
            var baseUrl = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if baseUrl.hasSuffix("/") { baseUrl = String(baseUrl.dropLast()) }

            if usePathStyle {
                // Path Style: https://endpoint/bucket
                // IMPORTANT: delimiter must be %2F, and NO trailing slash after bucket for the base path
                urlString = "\(baseUrl)/\(bucket)?delimiter=%2F&prefix=\(encodedPrefix)"
            } else {
                // Virtual Hosted Style
                if let schemeRange = baseUrl.range(of: "://") {
                    let scheme = baseUrl[..<schemeRange.upperBound]
                    let host = baseUrl[schemeRange.upperBound...]
                    urlString = "\(scheme)\(bucket).\(host)/?delimiter=%2F&prefix=\(encodedPrefix)"
                } else {
                    urlString =
                        "https://\(bucket).\(endpoint)/?delimiter=%2F&prefix=\(encodedPrefix)"
                }
            }
        } else {
            // Standard AWS - Virtual Hosted Style
            let host = "\(bucket).s3.\(region).amazonaws.com"
            urlString = "https://\(host)/?delimiter=%2F&list-type=2&prefix=\(encodedPrefix)"
        }

        guard let url = URL(string: urlString) else {
            throw S3Error.invalidUrl
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw S3Error.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            // ... Error parsing logic
            var errorMsg = "API Error \(httpResponse.statusCode)"
            if let codeRange = body.range(of: "<Code[^>]*>", options: .regularExpression),
                let codeEnd = body.range(of: "</Code>")
            {
                let code = body[codeRange.upperBound..<codeEnd.lowerBound]
                errorMsg += ": \(code)"
            }
            if let msgRange = body.range(of: "<Message[^>]*>", options: .regularExpression),
                let msgEnd = body.range(of: "</Message>")
            {
                let msg = body[msgRange.upperBound..<msgEnd.lowerBound]
                errorMsg += " - \(msg)"
            }
            if errorMsg == "API Error \(httpResponse.statusCode)" {
                errorMsg += " body: \(body.prefix(100))"
            }
            throw S3Error.apiError(httpResponse.statusCode, errorMsg)
        }

        return parseListObjectsResponse(data: data, prefix: prefix)
    }

    // New method for stats
    func calculateFolderStats(prefix: String) async throws -> (Int, Int64) {
        var totalCount = 0
        var totalSize: Int64 = 0
        var continuationToken: String? = nil
        var isTruncated = true

        // Loop for pagination
        while isTruncated {
            // Use URLComponents to construct query items reliably
            var components: URLComponents
            if !endpoint.isEmpty {
                var baseUrl = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
                if baseUrl.hasSuffix("/") { baseUrl = String(baseUrl.dropLast()) }

                if usePathStyle {
                    // Path style: https://endpoint/bucket
                    if let url = URL(string: "\(baseUrl)/\(bucket)") {
                        components =
                            URLComponents(url: url, resolvingAgainstBaseURL: false)
                            ?? URLComponents()
                    } else {
                        throw S3Error.invalidUrl
                    }
                } else {
                    // Virtual-host style: https://bucket.endpoint or custom
                    let hostString: String
                    if let schemeRange = baseUrl.range(of: "://") {
                        let scheme = baseUrl[..<schemeRange.upperBound]
                        let host = baseUrl[schemeRange.upperBound...]
                        hostString = "\(scheme)\(bucket).\(host)/"
                    } else {
                        hostString = "https://\(bucket).\(endpoint)/"
                    }
                    if let url = URL(string: hostString) {
                        components =
                            URLComponents(url: url, resolvingAgainstBaseURL: false)
                            ?? URLComponents()
                    } else {
                        throw S3Error.invalidUrl
                    }
                }
            } else {
                // Default AWS
                let host = "\(bucket).s3.\(region).amazonaws.com"
                if let url = URL(string: "https://\(host)/") {
                    components =
                        URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
                } else {
                    throw S3Error.invalidUrl
                }
            }

            // Add Query Items
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let token = continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: token))
            }
            components.queryItems = queryItems

            guard let url = components.url else { throw S3Error.invalidUrl }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            try signRequest(request: &request, payload: "")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw S3Error.invalidResponse
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown Error"
                print("DEBUG: Status Failed Response: \(errorBody)")
                throw S3Error.apiError(httpResponse.statusCode, "Stats Failed: \(errorBody)")
            }

            // Parse simple XML
            let parser = S3XMLParser(prefix: prefix)
            let objects = parser.parse(data: data)

            totalCount += objects.filter { !$0.isFolder }.count
            totalSize += objects.reduce(0) { $0 + $1.size }

            // Update pagination state
            isTruncated = parser.isTruncated
            continuationToken = parser.nextContinuationToken
        }

        return (totalCount, totalSize)
    }

    func generatePresignedURL(key: String, expirationSeconds: Int) throws -> URL {
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "yyyyMMdd"
        let datestamp = dateFormatter.string(from: date)

        // AWS V4 strictly requires [A-Za-z0-9.~_-] not to be encoded.
        let awsQueryEncode = { (s: String) -> String in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }

        // 1. Path & Host calculation
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        var host: String
        var canonicalUri: String

        if !endpoint.isEmpty {
            let base = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            guard let url = URL(string: base), let baseHost = url.host else {
                throw S3Error.invalidUrl
            }

            if usePathStyle {
                host = baseHost
                canonicalUri = "/\(bucket)/\(encodedKey)"
            } else {
                host = "\(bucket).\(baseHost)"
                canonicalUri = "/\(encodedKey)"
            }
        } else {
            host = "\(bucket).s3.\(region).amazonaws.com"
            canonicalUri = "/\(encodedKey)"
        }

        // Ensure canonicalUri begins with / and has no double slashes
        if !canonicalUri.hasPrefix("/") { canonicalUri = "/" + canonicalUri }
        canonicalUri = canonicalUri.replacingOccurrences(of: "//", with: "/")

        // 2. Query Parameters for Signature
        let credentialScope = "\(datestamp)/\(region)/s3/aws4_request"
        var queryItems = [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: "\(accessKey)/\(credentialScope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: "\(expirationSeconds)"),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]

        // 3. Canonical Request
        let sortedQueryItems = queryItems.sorted { $0.name < $1.name }
        let canonicalQueryString = sortedQueryItems.map {
            "\(awsQueryEncode($0.name))=\(awsQueryEncode($0.value ?? ""))"
        }.joined(separator: "&")

        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"
        let payloadHash = "UNSIGNED-PAYLOAD"

        let canonicalRequest =
            "GET\n\(canonicalUri)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"

        // 4. String to Sign
        let algorithm = "AWS4-HMAC-SHA256"
        let stringToSign =
            "\(algorithm)\n\(amzDate)\n\(credentialScope)\n\(sha256(canonicalRequest.data(using: .utf8)!))"

        // 5. Signature
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: datestamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).map { String(format: "%02x", $0) }
            .joined()

        // 6. Final URL Construction
        var finalQueryItems = queryItems
        finalQueryItems.append(URLQueryItem(name: "X-Amz-Signature", value: signature))

        var components = URLComponents()
        if !endpoint.isEmpty {
            let base = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if let baseUri = URL(string: base) {
                components.scheme = baseUri.scheme
                components.host = host
                components.port = baseUri.port
            }
        } else {
            components.scheme = "https"
            components.host = host
        }

        components.path = canonicalUri
        components.queryItems = finalQueryItems

        guard let finalUrl = components.url else { throw S3Error.invalidUrl }
        return finalUrl
    }

    func generateDownloadURL(key: String, versionId: String? = nil) throws -> URL {
        // Percent encode key
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key

        var urlString: String
        if !endpoint.isEmpty {
            var baseUrl = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if baseUrl.hasSuffix("/") { baseUrl = String(baseUrl.dropLast()) }

            if usePathStyle {
                urlString = "\(baseUrl)/\(bucket)/\(encodedKey)"
            } else {
                if let schemeRange = baseUrl.range(of: "://") {
                    let scheme = baseUrl[..<schemeRange.upperBound]
                    let host = baseUrl[schemeRange.upperBound...]
                    urlString = "\(scheme)\(bucket).\(host)/\(encodedKey)"
                } else {
                    urlString = "https://\(bucket).\(endpoint)/\(encodedKey)"
                }
            }
        } else {
            let host = "\(bucket).s3.\(region).amazonaws.com"
            urlString = "https://\(host)/\(encodedKey)"
        }

        if let vId = versionId {
            urlString += (urlString.contains("?") ? "&" : "?") + "versionId=\(vId)"
        }

        guard let url = URL(string: urlString) else {
            throw S3Error.invalidUrl
        }
        return url
    }

    // MARK: - File Operations

    func deleteObject(key: String) async throws {
        let url = try generateDownloadURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "Delete Failed: \(body)")
        }
    }

    func deleteRecursive(prefix: String) async throws {
        var allObjectsToDelete: [S3Object] = []
        var token: String? = nil
        var done = false

        print("[Debug Delete] Starting recursive list for: \(prefix)")

        // 1. Collect ALL objects across all pages
        while !done {
            let url = try generateDownloadURL(key: "")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let t = token {
                queryItems.append(URLQueryItem(name: "continuation-token", value: t))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            try signRequest(request: &request, payload: "")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                print(
                    "[Debug Delete] List failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                )
                throw S3Error.invalidResponse
            }

            let parser = S3XMLParser(prefix: prefix, filterPrefix: false)
            let pageObjects = parser.parse(data: data)
            allObjectsToDelete.append(contentsOf: pageObjects)

            if parser.isTruncated {
                token = parser.nextContinuationToken
            } else {
                done = true
            }
        }

        // 2. Sort by key length descending (deepest files first)
        // This is crucial for filesystem-like S3 providers.
        let sortedObjects = allObjectsToDelete.sorted { $0.key.count > $1.key.count }

        print("[Debug Delete] Found \(sortedObjects.count) total objects to delete.")

        // 3. Delete one by one
        for obj in sortedObjects {
            do {
                print("[Debug Delete] Deleting (\(obj.key.count)): \(obj.key)")
                try await deleteObject(key: obj.key)
            } catch {
                print("[Debug Delete] FAILED to delete \(obj.key): \(error.localizedDescription)")
                throw error
            }
        }
        print("[Debug Delete] Recursive Deletion Finished successfully for: \(prefix)")
    }

    func putObject(key: String, data: Data?) async throws {
        let url = try generateDownloadURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        let bodyData = data ?? Data()
        try signRequest(request: &request, payload: bodyData)
        request.httpBody = bodyData

        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "Put Failed: \(body)")
        }
    }

    func listObjectVersions(key: String) async throws -> [S3Version] {
        let url = try generateDownloadURL(key: "")  // Base URL
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "versions", value: nil),
            URLQueryItem(name: "prefix", value: key),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw S3Error.invalidResponse
        }

        let parser = S3VersionParser()
        return parser.parse(data: data).filter { $0.key == key }
    }

    func getObjectACL(key: String) async throws -> Bool {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "acl", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw S3Error.invalidResponse
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        // Check for "AllUsers" group with READ permission
        return body.contains("uri=\"http://acs.amazonaws.com/groups/global/AllUsers\"")
            && body.contains("<Permission>READ</Permission>")
    }

    func setObjectACL(key: String, isPublic: Bool) async throws {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "acl", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"

        // Use canned ACL for simplicity
        request.setValue(isPublic ? "public-read" : "private", forHTTPHeaderField: "x-amz-acl")

        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        guard let httpResponse = httpResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(
                httpResponse?.statusCode ?? 0, "Failed to update ACL: \(errorBody)")
        }
    }

    func getBucketVersioning() async throws -> Bool {
        let url = try generateDownloadURL(key: "")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "versioning", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw S3Error.invalidResponse
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("<Status>Enabled</Status>")
    }

    func putBucketVersioning(enabled: Bool) async throws {
        let url = try generateDownloadURL(key: "")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "versioning", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"

        let status = enabled ? "Enabled" : "Suspended"
        let xmlBody = """
            <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
              <Status>\(status)</Status>
            </VersioningConfiguration>
            """
        let bodyData = xmlBody.data(using: .utf8)!

        try signRequest(request: &request, payload: bodyData)
        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse

        guard let httpResponse = httpResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorBody = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(
                httpResponse?.statusCode ?? 0, "Failed to update versioning: \(errorBody)")
        }
    }

    func renameFolderRecursive(oldPrefix: String, newPrefix: String) async throws {
        var allObjects: [S3Object] = []
        var token: String? = nil
        var done = false

        while !done {
            let url = try generateDownloadURL(key: "")  // Base URL
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: oldPrefix),
            ]
            if let t = token {
                queryItems.append(URLQueryItem(name: "continuation-token", value: t))
            }
            // NO DELIMITER -> Recursive list
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            try signRequest(request: &request, payload: "")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                throw S3Error.invalidResponse
            }

            let parser = S3XMLParser(prefix: oldPrefix, filterPrefix: false)
            let pageObjects = parser.parse(data: data)
            allObjects.append(contentsOf: pageObjects)

            if parser.isTruncated {
                token = parser.nextContinuationToken
            } else {
                done = true
            }
        }

        // 2. Sort by key length descending (deepest files first)
        let sortedObjects = allObjects.sorted { $0.key.count > $1.key.count }

        print(
            "DEBUG RECURSIVE RENAME: Found \(sortedObjects.count) total objects to move from \(oldPrefix) to \(newPrefix)"
        )

        for obj in sortedObjects {
            let oldKey = obj.key
            // Create new key: Replace oldPrefix with newPrefix at the start
            if oldKey.hasPrefix(oldPrefix) {
                let suffix = oldKey.dropFirst(oldPrefix.count)
                let newKey = newPrefix + suffix

                print("DEBUG: Moving \(oldKey) -> \(newKey)")
                try await copyObject(sourceKey: oldKey, destinationKey: newKey)
                try await deleteObject(key: oldKey)
            }
        }
    }

    func copyObject(sourceKey: String, destinationKey: String) async throws {
        let url = try generateDownloadURL(key: destinationKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        // Sanitize source key so we don't end up with // in the path
        let safeSourceKey = sourceKey.first == "/" ? String(sourceKey.dropFirst()) : sourceKey

        var allowed = CharacterSet.urlPathAllowed  // Allow slashes
        // allowed.insert(charactersIn: "-_.~")
        let encodedSource =
            safeSourceKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? safeSourceKey

        // Attempt 6: No leading slash AND RAW slashes. "bucket/folder/file"
        // Matches LiveUI/S3 implementation.
        let headerValue = "\(bucket)/\(encodedSource)"
        request.setValue(headerValue, forHTTPHeaderField: "x-amz-copy-source")

        print("DEBUG COPY: '\(safeSourceKey)' -> Header: '\(headerValue)'")

        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            // Enhanced Error Reporting for Rename Debugging
            let debugMsg =
                "Copy Failed: \(httpResponse.statusCode). Header: [\(headerValue)]. Body: \(body)"
            print("DEBUG ERROR: \(debugMsg)")
            throw S3Error.apiError(httpResponse.statusCode, debugMsg)
        }
    }

    // MARK: - Download

    func fetchObjectData(key: String, versionId: String? = nil) async throws -> (Data, String) {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)

        var logs =
            "Download Key: \(key)\(versionId != nil ? " (Version: \(versionId!))" : "")\nURL: \(url.absoluteString)\n"
        if let httpResponse = response as? HTTPURLResponse {
            logs += "Status: \(httpResponse.statusCode)\n"
            if !(200...299).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                logs += "Error Body: \(body)\n"
                throw S3Error.apiError(httpResponse.statusCode, "Failed: \(body)")
            }
        }

        return (data, logs)
    }

    // MARK: - AWS Signature V4 Header

    private func signRequest(request: inout URLRequest, payload: Any) throws {
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let amzDate = dateFormatter.string(from: date)

        dateFormatter.dateFormat = "yyyyMMdd"
        let datestamp = dateFormatter.string(from: date)

        guard let url = request.url, let host = url.host else { return }

        // 1. Canonical Request
        let method = request.httpMethod ?? "GET"

        // 2. Compute path for signature
        // URL.path returns decoded string and strips trailing slashes.
        // We must use percentEncodedPath or absoluteString logic.

        // However, we might need to verify if we need to re-encode it?
        // Usually percentEncodedPath IS the canonical URI for S3 if we don't double encode.
        // But S3 expects "uri-encode-every-byte-except-unreserved".
        // URLComponents might leave some chars unencoded that AWS requires encoded (like + or * or others potentially).
        // But for "tmp/" it should be perfectly fine.
        // The previous logic was decoding (url.path) then re-encoding.

        // Let's stick to the previous re-encoding logic BUT use path that preserves slash.
        // Wait, if I use percentEncodedPath it's ALREADY encoded. Re-encoding it would double encode.
        // So I should DECODE it manually effectively? No.

        // The problem was `url.path` STRIPPED the slash.
        // If I use `path` from components, it should preserve it.
        // But `path` is encoded. "foo%20bar/".
        // If I split it by "/", I get "foo%20bar", "".
        // If I then re-encode "foo%20bar" -> "foo%2520bar" (DOUBLE ENCODED).

        // So I should:
        // 1. Get `path` (encoded, with slash)
        // 2. Decode it to get raw string WITH slash? "foo bar/"?
        // 3. Then re-encode using AWS rules.

        // Or simpler:
        // Use `pathComponents` but ensure we handle the trailing empty component.
        // `url.pathComponents` -> ["/", "s3-next-ink", "DiskNAS.hbk", "tmp", "/"] ??
        // Let's use the test output from debug_url.swift:
        // Path: '/.../tmp'
        // PathComponents: ["/", "s3-next-ink", "DiskNAS.hbk", "tmp"]
        // IT DROPPED THE SLASH.

        // So I CANNOT use `url.path` or `url.pathComponents`.

        // I MUST use `url.absoluteString` (or `URLComponents.path` if decode logic is available).

        let pathForSignature: String
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            // This is "encoded" path. e.g. /foo%20bar/
            // Note: URLComponents.path is DECODED. .percentEncodedPath is ENCODED.
            let rawEncoded = components.percentEncodedPath

            // AWS requires us to Normalize the path:
            // 1. Decode each segment
            // 2. Re-encode each segment with AWS rules (alphanumerics + -_.~)

            // But doing that is hard if we don't know where segments split (slash inside query param? no path is path).
            // Splitting `rawEncoded` by `/` is safe.

            let parts = rawEncoded.components(separatedBy: "/")

            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-_.~")

            let reEncodedParts = parts.map { part -> String in
                // Part is ALREADY encoded.
                // If we want to strictly follow AWS, we should: Decode -> Encode.
                // e.g. "foo%20bar" -> "foo bar" -> "foo%20bar" (or "foo%2520bar" if we are wrong).
                // Assuming standard URL encoding matches AWS mostly.
                // BUT `+` is valid in URL path but Reserved in AWS?
                // AWS S3: "Characters that must be encoded include ... + * %7E (~)".
                // `~` is Unreserved in AWS (allowed).
                // `+` should be encoded as %2B? S3 says so. URL path allows +.

                // Let's Decode then Encode.
                let decoded = part.removingPercentEncoding ?? part
                return decoded.addingPercentEncoding(withAllowedCharacters: allowed) ?? decoded
            }

            pathForSignature = reEncodedParts.joined(separator: "/")
        } else {
            pathForSignature = url.path  // Fallback
        }

        let canonicalUri = pathForSignature
        // ...

        /*
        let rawPath = url.path
        let pathComponents = rawPath.components(separatedBy: "/")
        ...
        */

        // Canonical Query String
        // Must be sorted by name, and values must be URI encoded (including / -> %2F)
        var canonicalQuery = ""
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems
        {

            let sortedItems = queryItems.sorted { $0.name < $1.name }

            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-_.~")

            let encodedItems = sortedItems.map { item -> String in
                let k = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
                let v =
                    (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(k)=\(v)"
            }
            canonicalQuery = encodedItems.joined(separator: "&")
        }

        // Headers need to be lowercase and sorted
        // We MUST include host and x-amz-date
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(host, forHTTPHeaderField: "host")
        // Content-SHA256 is required for S3
        let payloadHash: String
        if let data = payload as? Data {
            payloadHash = sha256(data)
        } else if let str = payload as? String {
            payloadHash = sha256(str.data(using: .utf8) ?? Data())
        } else {
            payloadHash = sha256(Data())
        }
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")

        let canonicalHeaders =
            "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"

        let canonicalRequest = """
            \(method)
            \(canonicalUri)
            \(canonicalQuery)
            \(canonicalHeaders)
            \(signedHeaders)
            \(payloadHash)
            """

        // 2. String to Sign
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = "\(datestamp)/\(region)/s3/aws4_request"
        let stringToSign = """
            \(algorithm)
            \(amzDate)
            \(credentialScope)
            \(sha256(canonicalRequest.data(using: .utf8)!))
            """

        // Debug Log (Print to console so we can see it in AppState debug log if we forward it,
        // but here we are in Client. We can print to stdout or use a callback mechanism if we had one.
        // For now, print to console is best for `run_command` or just user feedback.)
        print("[Debug S3] Canonical Request:\n\(canonicalRequest)")
        print("[Debug S3] String To Sign:\n\(stringToSign)")

        // 3. Signature
        // kSecret = "AWS4" + kSecret
        // kDate = HMAC("AWS4" + kSecret, Date)
        // kRegion = HMAC(kDate, Region)
        // kService = HMAC(kRegion, Service)
        // kSigning = HMAC(kService, "aws4_request")

        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: datestamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).map { String(format: "%02x", $0) }
            .joined()

        // 4. Authorization Header
        let authorization =
            "\(algorithm) Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }

    // MARK: - Helpers

    private func sha256(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func hmac(key: Data, data: String) -> Data {
        let dataToSign = data.data(using: .utf8)!
        var result = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        key.withUnsafeBytes { keyBytes in
            dataToSign.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count,
                    dataBytes.baseAddress, dataToSign.count, &result)
            }
        }
        return Data(result)
    }
    // ... (rest of file)

    // MARK: - XML Parser
    private func parseListObjectsResponse(data: Data, prefix: String) -> ([S3Object], String) {
        let parser = S3XMLParser(prefix: prefix)
        let objects = parser.parse(data: data)
        return (objects, parser.debugLog)
    }
}

class S3XMLParser: NSObject, XMLParserDelegate {
    var objects: [S3Object] = []
    var debugLog = ""

    private var currentElement = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentLastModifiedString = ""
    private var currentPrefix = ""

    // State flags
    private var inContents = false
    private var inCommonPrefixes = false

    // Pagination
    var isTruncated = false
    var nextContinuationToken: String?

    private let inputPrefix: String
    private let filterPrefix: Bool

    init(prefix: String, filterPrefix: Bool = true) {
        self.inputPrefix = prefix
        self.filterPrefix = filterPrefix
        super.init()
    }

    func parse(data: Data) -> [S3Object] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return objects.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.key < $1.key
        }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Contents" {
            inContents = true
            currentKey = ""
            currentSize = 0
            currentLastModifiedString = ""
        } else if elementName == "CommonPrefixes" {
            inCommonPrefixes = true
            currentPrefix = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Accumulate text content (handling chunked delivery)
        if inContents {
            if currentElement == "Key" {
                currentKey += string
            } else if currentElement == "Size" {
                // Filter out newlines/spaces if any
                let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    currentSize = Int64(cleaned) ?? currentSize
                }
            } else if currentElement == "LastModified" {
                currentLastModifiedString += string
            }
        } else if inCommonPrefixes {
            if currentElement == "Prefix" { currentPrefix += string }
        } else {
            // Check for top-level pagination elements
            if currentElement == "IsTruncated" {
                let val = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if val == "true" { isTruncated = true }
            } else if currentElement == "NextContinuationToken" {
                if nextContinuationToken == nil { nextContinuationToken = "" }
                nextContinuationToken? += string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // Optimized Date Formatters
    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Contents" {
            inContents = false
            let finalKey = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)

            // Filter out the folder placeholder itself (e.g. "folder/")
            if !finalKey.isEmpty {
                let normalizedKey = finalKey.hasSuffix("/") ? String(finalKey.dropLast()) : finalKey
                let normalizedInput =
                    inputPrefix.hasSuffix("/") ? String(inputPrefix.dropLast()) : inputPrefix

                if !filterPrefix || normalizedKey != normalizedInput {
                    // Parse Date
                    let dateString = currentLastModifiedString.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    var date = Date()  // Default to now if fail

                    // Attempt 1: Standard ISO8601 (Reuse static)
                    if let parsed = Self.isoFormatter.date(from: dateString) {
                        date = parsed
                    } else if let parsed = Self.fractionalFormatter.date(from: dateString) {
                        // Attempt 2: Fractional Seconds (Reuse static)
                        date = parsed
                    } else {
                        // Debug failure (Removed print to avoid console spam performance hit)
                        // print("Date Parse Failed: '\(dateString)'")
                    }

                    objects.append(
                        S3Object(
                            key: finalKey, size: currentSize, lastModified: date,
                            isFolder: finalKey.hasSuffix("/")))
                }
            }
        } else if elementName == "CommonPrefixes" {
            inCommonPrefixes = false
            let finalPrefix = currentPrefix.trimmingCharacters(in: .whitespacesAndNewlines)

            // Normalize for comparison (remove trailing slashes)
            let normFinal =
                finalPrefix.hasSuffix("/") ? String(finalPrefix.dropLast()) : finalPrefix
            let normInput =
                inputPrefix.hasSuffix("/") ? String(inputPrefix.dropLast()) : inputPrefix

            debugLog +=
                "[\(Date().formatted(date: .omitted, time: .standard))] Check: '\(normFinal)' vs Input: '\(normInput)'\n"

            // Add folder if not empty, not duplicate, AND NOT THE CURRENT FOLDER ITSELF
            if !finalPrefix.isEmpty {
                if normFinal == normInput {
                    debugLog += "-> IGNORED (SELF)\n"
                } else if objects.contains(where: {
                    let objKey = $0.key
                    let normObj = objKey.hasSuffix("/") ? String(objKey.dropLast()) : objKey
                    return normObj == normFinal
                }) {
                    debugLog += "-> IGNORED (DUPLICATE)\n"
                } else {
                    debugLog += "-> ACCEPTED\n"
                    objects.append(
                        S3Object(key: finalPrefix, size: 0, lastModified: Date(), isFolder: true))
                }
            }
        }
    }
}

class S3VersionParser: NSObject, XMLParserDelegate {
    var versions: [S3Version] = []

    private var currentElement = ""
    private var currentKey = ""
    private var currentVersionId = ""
    private var currentIsLatest = false
    private var currentLastModifiedString = ""
    private var currentSize: Int64 = 0
    private var inVersion = false
    private var inDeleteMarker = false

    func parse(data: Data) -> [S3Version] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return versions.sorted { $0.lastModified > $1.lastModified }
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Version" {
            inVersion = true
            currentKey = ""
            currentVersionId = ""
            currentIsLatest = false
            currentLastModifiedString = ""
            currentSize = 0
        } else if elementName == "DeleteMarker" {
            inDeleteMarker = true
            currentKey = ""
            currentVersionId = ""
            currentIsLatest = false
            currentLastModifiedString = ""
            currentSize = 0
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if inVersion || inDeleteMarker {
            if currentElement == "Key" {
                currentKey += cleaned
            } else if currentElement == "VersionId" {
                currentVersionId += cleaned
            } else if currentElement == "IsLatest" {
                currentIsLatest = (cleaned.lowercased() == "true")
            } else if currentElement == "LastModified" {
                currentLastModifiedString += cleaned
            } else if currentElement == "Size" {
                if !cleaned.isEmpty {
                    currentSize = Int64(cleaned) ?? currentSize
                }
            }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Version" || elementName == "DeleteMarker" {
            let date = parseDate(currentLastModifiedString)
            versions.append(
                S3Version(
                    key: currentKey,
                    versionId: currentVersionId,
                    isLatest: currentIsLatest,
                    lastModified: date,
                    size: currentSize,
                    isDeleteMarker: (elementName == "DeleteMarker")
                ))
            inVersion = false
            inDeleteMarker = false
        }
    }

    private func parseDate(_ string: String) -> Date {
        let isoFormatter = ISO8601DateFormatter()
        if let date = isoFormatter.date(from: string) { return date }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: string) ?? Date()
    }
}
