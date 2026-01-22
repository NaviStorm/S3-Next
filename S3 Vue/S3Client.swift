import CommonCrypto
import Foundation

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

    private func awsEncode(_ string: String, encodeSlash: Bool = true) -> String {
        let nfcString = string.precomposedStringWithCanonicalMapping
        // S3 V4 requires strict encoding: A-Z, a-z, 0-9, hyphen (-), underscore (_), period (.), and tilde (~)
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var finalAllowed = allowed
        if !encodeSlash { finalAllowed.insert(charactersIn: "/") }

        return nfcString.addingPercentEncoding(withAllowedCharacters: finalAllowed) ?? nfcString
    }

    // MARK: - Public API

    func listObjects(prefix: String = "") async throws -> ([S3Object], String) {
        let encodedPrefix = awsEncode(prefix)

        let urlString: String
        if !endpoint.isEmpty {
            var baseUrl = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if baseUrl.hasSuffix("/") { baseUrl = String(baseUrl.dropLast()) }

            if usePathStyle {
                urlString = "\(baseUrl)/\(bucket)?delimiter=%2F&prefix=\(encodedPrefix)"
            } else {
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
            let host = "\(bucket).s3.\(region).amazonaws.com"
            urlString = "https://\(host)/?delimiter=%2F&list-type=2&prefix=\(encodedPrefix)"
        }

        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "ListObjects Failed: \(body)")
        }

        return parseListObjectsResponse(data: data, prefix: prefix)
    }

    func calculateFolderStats(prefix: String) async throws -> (Int, Int64) {
        let allObjects = try await listAllObjects(prefix: prefix)
        let totalCount = allObjects.filter { !$0.isFolder }.count
        let totalSize = allObjects.reduce(0) { $0 + $1.size }
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

        let encodedKey = awsEncode(key, encodeSlash: false)
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

        if !canonicalUri.hasPrefix("/") { canonicalUri = "/" + canonicalUri }
        canonicalUri = canonicalUri.replacingOccurrences(of: "//", with: "/")

        let credentialScope = "\(datestamp)/\(region)/s3/aws4_request"
        let queryItems = [
            URLQueryItem(name: "X-Amz-Algorithm", value: "AWS4-HMAC-SHA256"),
            URLQueryItem(name: "X-Amz-Credential", value: "\(accessKey)/\(credentialScope)"),
            URLQueryItem(name: "X-Amz-Date", value: amzDate),
            URLQueryItem(name: "X-Amz-Expires", value: "\(expirationSeconds)"),
            URLQueryItem(name: "X-Amz-SignedHeaders", value: "host"),
        ]

        let sortedQueryItems = queryItems.sorted { $0.name < $1.name }
        let canonicalQueryString = sortedQueryItems.map {
            "\(awsEncode($0.name))=\(awsEncode($0.value ?? ""))"
        }.joined(separator: "&")
        let canonicalHeaders = "host:\(host)\n"
        let signedHeaders = "host"
        let payloadHash = "UNSIGNED-PAYLOAD"
        let canonicalRequest =
            "GET\n\(canonicalUri)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"

        let algorithm = "AWS4-HMAC-SHA256"
        let stringToSign =
            "\(algorithm)\n\(amzDate)\n\(credentialScope)\n\(sha256(canonicalRequest.data(using: .utf8)!))"

        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: datestamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).map { String(format: "%02x", $0) }
            .joined()

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
        var finalQueryItems = queryItems
        finalQueryItems.append(URLQueryItem(name: "X-Amz-Signature", value: signature))
        components.queryItems = finalQueryItems

        guard let finalUrl = components.url else { throw S3Error.invalidUrl }
        return finalUrl
    }

    func generateDownloadURL(key: String, versionId: String? = nil) throws -> URL {
        let encodedKey = awsEncode(key, encodeSlash: false)
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
        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }
        return url
    }

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

    func deleteRecursive(prefix: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil)
        async throws
    {
        let allObjectsToDelete = try await listAllObjects(prefix: prefix)
        // Sort by key length descending to delete children before parents
        let sortedObjects = allObjectsToDelete.sorted { $0.key.count > $1.key.count }
        var count = 0
        for obj in sortedObjects {
            try await deleteObject(key: obj.key)
            count += 1
            onProgress?(count, sortedObjects.count)
        }

        // Also ensure the prefix itself is deleted if it was returned by listAllObjects
        // or if it's a folder object not returned.
        if prefix.hasSuffix("/") {
            try? await deleteObject(key: prefix)
        }
    }

    func listAllObjects(prefix: String) async throws -> [S3Object] {
        var allObjects: [S3Object] = []
        var continuationToken: String? = nil
        var isTruncated = true
        while isTruncated {
            // Important: Use root URL with query params for list
            let baseUrl = try generateDownloadURL(key: "")
            var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let t = continuationToken {
                queryItems.append(URLQueryItem(name: "continuation-token", value: t))
            }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.httpMethod = "GET"
            try signRequest(request: &request, payload: "")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw S3Error.invalidResponse
            }

            if !(200...299).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<no body>"
                throw S3Error.apiError(httpResponse.statusCode, "ListAllObjects Failed: \(body)")
            }

            // use filterPrefix: false to include the directory itself in deletion/rename
            let parser = S3XMLParser(prefix: prefix, filterPrefix: false)
            let pageObjects = parser.parse(data: data)
            allObjects.append(contentsOf: pageObjects)
            if parser.isTruncated {
                continuationToken = parser.nextContinuationToken
            } else {
                isTruncated = false
            }
        }
        return allObjects
    }

    func putObject(key: String, data: Data?) async throws {
        let url = try generateDownloadURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let bodyData = data ?? Data()
        try signRequest(request: &request, payload: bodyData)
        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body =
                String(data: responseData, encoding: .utf8)
                ?? "Put Failed: \(httpResponse.statusCode)"
            throw S3Error.apiError(httpResponse.statusCode, body)
        }
    }

    func listObjectVersions(key: String) async throws -> [S3Version] {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "versions", value: nil), URLQueryItem(name: "prefix", value: key),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "ListVersions Failed: \(body)")
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
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "GetACL Failed: \(body)")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("uri=\"http://acs.amazonaws.com/groups/global/AllUsers\"")
            && body.contains("<Permission>READ</Permission>")
    }

    func setObjectACL(key: String, isPublic: Bool) async throws {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "acl", value: nil)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.setValue(isPublic ? "public-read" : "private", forHTTPHeaderField: "x-amz-acl")
        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "SetACL Failed: \(errorBody)")
        }
    }

    func getBucketVersioning() async throws -> Bool {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "versioning", value: nil)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "GetVersioning Failed: \(body)")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return body.contains("<Status>Enabled</Status>")
    }

    func putBucketVersioning(enabled: Bool) async throws {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "versioning", value: nil)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        let status = enabled ? "Enabled" : "Suspended"
        let xmlBody =
            "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Status>\(status)</Status></VersioningConfiguration>"
        let bodyData = xmlBody.data(using: .utf8)!
        try signRequest(request: &request, payload: bodyData)
        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "PutVersioning Failed: \(errorBody)")
        }
    }

    func renameFolderRecursive(
        oldPrefix: String, newPrefix: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws {
        let allObjects = try await listAllObjects(prefix: oldPrefix)
        let sortedObjects = allObjects.sorted { $0.key.count > $1.key.count }
        var count = 0
        for obj in sortedObjects {
            let oldKey = obj.key
            if oldKey.hasPrefix(oldPrefix) {
                let suffix = oldKey.dropFirst(oldPrefix.count)
                let newKey = newPrefix + suffix
                try await copyObject(sourceKey: oldKey, destinationKey: newKey)
                try await deleteObject(key: oldKey)
                count += 1
                onProgress?(count, sortedObjects.count)
            }
        }
    }

    func copyObject(sourceKey: String, destinationKey: String) async throws {
        let url = try generateDownloadURL(key: destinationKey)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let safeSourceKey = sourceKey.first == "/" ? String(sourceKey.dropFirst()) : sourceKey
        // x-amz-copy-source must be URL encoded, but the slash between bucket and key must be literal.
        // We encode the key part fully (including slashes).
        let encodedKeyPart = awsEncode(safeSourceKey, encodeSlash: true)
        let headerValue = "\(bucket)/\(encodedKeyPart)"
        request.setValue(headerValue, forHTTPHeaderField: "x-amz-copy-source")
        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "Copy Failed: \(body)")
        }
    }

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
                throw S3Error.apiError(httpResponse.statusCode, "Download Failed: \(body)")
            }
        }
        return (data, logs)
    }

    private func signRequest(request: inout URLRequest, payload: Any) throws {
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let amzDate = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "yyyyMMdd"
        let datestamp = dateFormatter.string(from: date)

        guard let url = request.url, let host = url.host else { return }
        let method = request.httpMethod ?? "GET"

        // Canonical URI
        // Important: Foundation's url.path STRIPS the trailing slash.
        // S3 signature MUST include it if the request has one.
        var canonicalUri = url.path
        if canonicalUri.isEmpty { canonicalUri = "/" }
        if !canonicalUri.hasPrefix("/") { canonicalUri = "/" + canonicalUri }

        let originalCleanUrl = url.absoluteString.components(separatedBy: "?")[0]
        if originalCleanUrl.hasSuffix("/") && !canonicalUri.hasSuffix("/") {
            canonicalUri += "/"
        }

        // AWS V4: URI must be percent-encoded but NOT the slashes.
        let safeCanonicalUri = awsEncode(canonicalUri, encodeSlash: false)

        // Canonical Query String
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        let canonicalQueryString =
            queryItems
            .sorted { $0.name < $1.name }
            .map { item in
                let encodedName = awsEncode(item.name)
                let encodedValue = awsEncode(item.value ?? "")
                return "\(encodedName)=\(encodedValue)"
            }.joined(separator: "&")

        // Payload Hash
        let payloadData = (payload as? Data) ?? (payload as? String)?.data(using: .utf8) ?? Data()
        let payloadHash = sha256(payloadData)

        // Headers to sign
        var headersToSign: [String: String] = [:]
        headersToSign["host"] = host
        headersToSign["x-amz-date"] = amzDate
        headersToSign["x-amz-content-sha256"] = payloadHash

        if let allHeaders = request.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                let lowerKey = key.lowercased()
                if lowerKey.hasPrefix("x-amz-") || lowerKey == "content-type" {
                    headersToSign[lowerKey] = value
                }
            }
        }

        let sortedHeaderKeys = headersToSign.keys.sorted()
        let canonicalHeaders = sortedHeaderKeys.map {
            "\($0):\((headersToSign[$0] ?? "").trimmingCharacters(in: .whitespaces))\n"
        }.joined()
        let signedHeaders = sortedHeaderKeys.joined(separator: ";")

        let canonicalRequest =
            "\(method)\n\(safeCanonicalUri)\n\(canonicalQueryString)\n\(canonicalHeaders)\n\(signedHeaders)\n\(payloadHash)"

        let credentialScope = "\(datestamp)/\(region)/s3/aws4_request"
        let stringToSign =
            "AWS4-HMAC-SHA256\n\(amzDate)\n\(credentialScope)\n\(sha256(canonicalRequest.data(using: .utf8)!))"

        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: datestamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signature = hmac(key: kSigning, data: stringToSign).map { String(format: "%02x", $0) }
            .joined()

        let authHeader =
            "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"

        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        request.setValue(host, forHTTPHeaderField: "Host")

        // Fix: Explicitly set the encoded query in the request URL to ensure it matches what we signed.
        if !canonicalQueryString.isEmpty {
            var finalComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            finalComponents.percentEncodedQuery = canonicalQueryString
            request.url = finalComponents.url
        }
    }

    private func sha256(_ data: Data) -> String {
        var context = CC_SHA256_CTX()
        CC_SHA256_Init(&context)

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            if let baseAddress = buffer.baseAddress {
                var offset = 0
                let totalLength = data.count
                while offset < totalLength {
                    let chunkSize = min(totalLength - offset, Int(UInt32.max))
                    CC_SHA256_Update(&context, baseAddress + offset, CC_LONG(chunkSize))
                    offset += chunkSize
                }
            }
        }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256_Final(&hash, &context)
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

    private func parseListObjectsResponse(data: Data, prefix: String) -> ([S3Object], String) {
        let parser = S3XMLParser(prefix: prefix)
        let objects = parser.parse(data: data)
        return (objects, "")
    }
}
