import CommonCrypto
import CryptoKit
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

        // Auto-fix pour Next.ink
        if endpoint.contains("next.ink") {
            // Test de la région fr1 si southwest1 échoue pour l'utilisateur
            if region == "us-east-1" || region.isEmpty || region == "fr1" {  // Added || region == "fr1"
                self.region = "southwest1"
                print("[S3Client] Next.ink detected: Using region 'southwest1'")
            } else {
                self.region = region
            }
        } else {
            self.region = region
        }

        self.bucket = bucket
        self.endpoint = endpoint
        self.usePathStyle = usePathStyle

        print(
            "[S3Client] Initialized: Bucket=\(bucket), Region=\(self.region), Endpoint=\(endpoint), PathStyle=\(usePathStyle)"
        )
    }

    private func awsEncode(_ string: String, encodeSlash: Bool = true) -> String {
        // Strict set of allowed characters for S3 V4
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var finalAllowed = allowed
        if !encodeSlash { finalAllowed.insert(charactersIn: "/") }

        // addingPercentEncoding correctly handles all characters not in finalAllowed, including '%'
        return string.addingPercentEncoding(withAllowedCharacters: finalAllowed) ?? string
    }

    // MARK: - Public API

    func listObjects(prefix: String = "") async throws -> ([S3Object], String) {
        var allObjects: [S3Object] = []
        var continuationToken: String? = nil
        var isTruncated = true

        while isTruncated {
            let encodedPrefix = awsEncode(prefix)
            var urlString: String

            if !endpoint.isEmpty {
                var baseUrl = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
                if baseUrl.hasSuffix("/") { baseUrl = String(baseUrl.dropLast()) }

                if usePathStyle {
                    urlString =
                        "\(baseUrl)/\(bucket)?delimiter=%2F&list-type=2&prefix=\(encodedPrefix)"
                } else {
                    if let schemeRange = baseUrl.range(of: "://") {
                        let scheme = baseUrl[..<schemeRange.upperBound]
                        let host = baseUrl[schemeRange.upperBound...]
                        urlString =
                            "\(scheme)\(bucket).\(host)/?delimiter=%2F&list-type=2&prefix=\(encodedPrefix)"
                    } else {
                        urlString =
                            "https://\(bucket).\(endpoint)/?delimiter=%2F&list-type=2&prefix=\(encodedPrefix)"
                    }
                }
            } else {
                let host = "\(bucket).s3.\(region).amazonaws.com"
                urlString = "https://\(host)/?delimiter=%2F&list-type=2&prefix=\(encodedPrefix)"
            }

            if let token = continuationToken {
                urlString += "&continuation-token=\(awsEncode(token))"
            }

            print("[S3] URL: \(urlString)")

            guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            try signRequest(request: &request, payload: "")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw S3Error.invalidResponse
            }

            print("[S3] Status: \(httpResponse.statusCode)")

            if !(200...299).contains(httpResponse.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "Unknown error"
                print("[S3] Error: \(body)")
                throw S3Error.apiError(httpResponse.statusCode, "ListObjects Failed: \(body)")
            }

            let parser = S3XMLParser(prefix: prefix)
            let objects = parser.parse(data: data)
            allObjects.append(contentsOf: objects)

            print("[S3] Page: \(objects.count) objects. Total: \(allObjects.count)")
            print(
                "[S3] Truncated: \(parser.isTruncated), nextToken: \(parser.nextContinuationToken ?? "nil")"
            )

            if parser.isTruncated {
                continuationToken = parser.nextContinuationToken
                if continuationToken == nil {
                    print(
                        "[S3] WARNING: isTruncated refers to true but nextContinuationToken is nil. Breaking."
                    )
                    isTruncated = false
                }
            } else {
                isTruncated = false
            }
        }

        return (allObjects, "")
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

        let (components, host) = try buildComponents(key: key)
        let canonicalUri = components.path

        // Nettoyage final du URI pour la signature
        var safeUri = canonicalUri
        if !safeUri.hasPrefix("/") { safeUri = "/" + safeUri }
        safeUri = safeUri.replacingOccurrences(of: "//", with: "/")

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

        var componentsForUrl = components
        if !endpoint.isEmpty {
            let base = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if let baseUri = URL(string: base) {
                componentsForUrl.scheme = baseUri.scheme
                componentsForUrl.port = baseUri.port
            }
        } else {
            componentsForUrl.scheme = "https"
        }

        var finalQueryItems = queryItems
        finalQueryItems.append(URLQueryItem(name: "X-Amz-Signature", value: signature))
        componentsForUrl.queryItems = finalQueryItems

        guard let finalUrl = componentsForUrl.url else { throw S3Error.invalidUrl }
        return finalUrl
    }

    func generatePresignedPost(
        keyPrefix: String, expirationSeconds: Int, maxSize: Int64, acl: String? = nil
    ) throws
        -> (url: URL, fields: [String: String])
    {
        let date = Date()
        let dateFormatterShort = DateFormatter()
        dateFormatterShort.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatterShort.dateFormat = "yyyyMMdd"
        let datestamp = dateFormatterShort.string(from: date)

        dateFormatterShort.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let amzDate = dateFormatterShort.string(from: date)

        // Expiration date in ISO8601
        let expirationDate = date.addingTimeInterval(TimeInterval(expirationSeconds))
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let expirationStr = isoFormatter.string(from: expirationDate)

        let credentialScope = "\(datestamp)/\(region)/s3/aws4_request"
        let credential = "\(accessKey)/\(credentialScope)"

        // Construct conditions
        var conditions: [Any] = [
            ["bucket": bucket],
            ["starts-with", "$key", keyPrefix],
            ["content-length-range", 0, maxSize],
            ["x-amz-algorithm": "AWS4-HMAC-SHA256"],
            ["x-amz-credential": credential],
            ["x-amz-date": amzDate],
        ]

        if let acl = acl {
            conditions.append(["acl": acl])
        }

        // Construct policy JSON
        let policy: [String: Any] = [
            "expiration": expirationStr,
            "conditions": conditions,
        ]

        let policyData = try JSONSerialization.data(withJSONObject: policy)
        let policyBase64 = policyData.base64EncodedString()

        // Sign the policy
        let kDate = hmac(key: "AWS4\(secretKey)".data(using: .utf8)!, data: datestamp)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: "s3")
        let kSigning = hmac(key: kService, data: "aws4_request")
        let signatureData = hmac(key: kSigning, data: policyBase64)
        let signature = signatureData.map { String(format: "%02x", $0) }.joined()

        var fields: [String: String] = [
            "key": keyPrefix + "${filename}",
            "x-amz-algorithm": "AWS4-HMAC-SHA256",
            "x-amz-credential": credential,
            "x-amz-date": amzDate,
            "policy": policyBase64,
            "x-amz-signature": signature,
        ]

        if let acl = acl {
            fields["acl"] = acl
        }

        let (postComponents, _) = try buildComponents(key: "")
        guard let url = postComponents.url else { throw S3Error.invalidUrl }

        print("[S3] generatePresignedPost - Region: \(region)")
        print("[S3] generatePresignedPost - Host: \(postComponents.host ?? "nil")")
        print("[S3] generatePresignedPost - URL: \(url.absoluteString)")

        return (url, fields)
    }

    func generateDownloadURL(key: String, versionId: String? = nil) throws -> URL {
        var (components, _) = try buildComponents(key: key)

        if let vId = versionId {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "versionId", value: vId))
            components.queryItems = items
        }

        guard let url = components.url else { throw S3Error.invalidUrl }
        return url
    }

    private func buildComponents(key: String) throws -> (components: URLComponents, host: String) {
        let encodedKey = awsEncode(key, encodeSlash: false)
        let baseUrlStr = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
        guard let baseUrl = URL(string: baseUrlStr) else {
            throw S3Error.invalidUrl
        }

        let baseHost = baseUrl.host ?? ""
        var components = URLComponents()
        components.scheme = baseUrl.scheme ?? "https"
        components.port = baseUrl.port

        let actualHost: String
        let actualPath: String

        let isNextInk = endpoint.contains("next.ink")

        if bucket.isEmpty {
            actualHost = baseHost
            actualPath = "/"
        } else if usePathStyle || isNextInk {
            // Path Style (obligatoire pour Next.ink car le Virtual Host renvoie NoSuchBucket)
            actualHost = baseHost
            // Important: pour le POST (key vide), le slash final /bucket/ est souvent obligatoire
            actualPath = encodedKey.isEmpty ? "/\(bucket)/" : "/\(bucket)/\(encodedKey)"

            if isNextInk {
                print("[S3-DEBUG] Next.ink: Forced Path-Style Mode: \(actualHost)\(actualPath)")
            }
        } else {
            // Virtual Host Style
            if baseHost.isEmpty {
                actualHost = "\(bucket).s3.\(region).amazonaws.com"
            } else {
                actualHost = "\(bucket).\(baseHost)"
            }
            actualPath = encodedKey.isEmpty ? "/" : "/\(encodedKey)"
        }

        components.host = actualHost
        // Utiliser percentEncodedPath pour éviter que URLComponents ne ré-encode nos pourcentages (%)
        let cleanPath = actualPath.replacingOccurrences(of: "//", with: "/")
        components.percentEncodedPath = cleanPath

        return (components, actualHost)
    }

    func listBuckets() async throws -> [String] {
        var urlString: String
        if !endpoint.isEmpty {
            urlString = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if urlString.hasSuffix("/") { urlString = String(urlString.dropLast()) }
        } else {
            urlString = "https://s3.\(region).amazonaws.com"
        }

        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "ListBuckets Failed: \(body)")
        }

        return S3BucketParser().parse(data: data)
    }

    func createBucket(objectLockEnabled: Bool = false, acl: String? = nil) async throws {
        let url = try generateDownloadURL(key: "")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        var bodyData = Data()
        if region != "us-east-1" && !endpoint.isEmpty && endpoint.contains("amazonaws.com") {
            // AWS S3 standard region doesn't and often errors if provided.
            // But non-us-east-1 standard AWS might need LocationConstraint.
            let xml = """
                <CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                   <LocationConstraint>\(region)</LocationConstraint>
                </CreateBucketConfiguration>
                """
            bodyData = xml.data(using: .utf8)!
        }

        if objectLockEnabled {
            request.setValue("true", forHTTPHeaderField: "x-amz-bucket-object-lock-enabled")
        }
        if let aclValue = acl {
            request.setValue(aclValue, forHTTPHeaderField: "x-amz-acl")
        }

        try signRequest(request: &request, payload: bodyData)
        request.httpBody = bodyData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "CreateBucket Failed: \(body)")
        }
    }

    func deleteBucket() async throws {
        let url = try generateDownloadURL(key: "")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "DeleteBucket Failed: \(body)")
        }
    }

    func deleteObject(key: String, versionId: String? = nil) async throws {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            let versionInfo = versionId != nil ? " (Version: \(versionId!))" : ""
            throw S3Error.apiError(httpResponse.statusCode, "Delete Failed\(versionInfo): \(body)")
        }
    }

    func createFolder(key: String) async throws {
        // Ensure key ends with /
        let folderKey = key.hasSuffix("/") ? key : key + "/"
        try await putObject(key: folderKey, data: Data())
    }

    func deleteRecursive(prefix: String, onProgress: (@Sendable (Int, Int) -> Void)? = nil)
        async throws
    {
        let allObjectsToDelete = try await listAllObjects(prefix: prefix)
        // Sort by key length descending to delete children before parents
        let sortedObjects = allObjectsToDelete.sorted { $0.key.count > $1.key.count }
        var count = 0
        for obj in sortedObjects {
            try Task.checkCancellation()
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

    func fetchHistory(prefix: String, from startDate: Date, to endDate: Date) async throws
        -> [S3Version]
    {
        let allVersions = try await listAllVersions(prefix: prefix)
        return allVersions.filter { ver in
            ver.lastModified >= startDate && ver.lastModified <= endDate
        }
    }

    func listAllVersions(prefix: String) async throws -> [S3Version] {
        var allVersions: [S3Version] = []
        var keyMarker: String? = nil
        var versionIdMarker: String? = nil
        var isTruncated = true

        while isTruncated {
            try Task.checkCancellation()
            let baseUrl = try generateDownloadURL(key: "")
            var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
            var queryItems = [
                URLQueryItem(name: "versions", value: nil),
                URLQueryItem(name: "prefix", value: prefix),
            ]
            if let km = keyMarker {
                queryItems.append(URLQueryItem(name: "key-marker", value: km))
            }
            if let vm = versionIdMarker {
                queryItems.append(URLQueryItem(name: "version-id-marker", value: vm))
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
                throw S3Error.apiError(httpResponse.statusCode, "ListAllVersions Failed: \(body)")
            }

            let parser = S3VersionParser()
            let pageVersions = parser.parse(data: data)
            allVersions.append(contentsOf: pageVersions)

            if parser.isTruncated {
                keyMarker = parser.nextKeyMarker
                versionIdMarker = parser.nextVersionIdMarker
            } else {
                isTruncated = false
            }
        }
        return allVersions
    }

    func listAllObjects(prefix: String) async throws -> [S3Object] {
        var allObjects: [S3Object] = []
        var continuationToken: String? = nil
        var isTruncated = true
        while isTruncated {
            try Task.checkCancellation()
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

    func putObject(
        key: String, data: Data?, metadata: [String: String] = [:], contentType: String? = nil,
        acl: String? = nil
    ) async throws {
        let url = try generateDownloadURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        // Add custom metadata
        for (mKey, mValue) in metadata {
            request.setValue(mValue, forHTTPHeaderField: "x-amz-meta-\(mKey)")
        }

        // Add content type if specified
        if let contentType = contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        // Add ACL if specified
        if let acl = acl {
            request.setValue(acl, forHTTPHeaderField: "x-amz-acl")
        }

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

    // MARK: - Multipart Upload

    func createMultipartUpload(key: String, metadata: [String: String] = [:]) async throws -> String
    {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploads", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        for (mKey, mValue) in metadata {
            request.setValue(mValue, forHTTPHeaderField: "x-amz-meta-\(mKey)")
        }

        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "CreateMultipart Failed: \(body)")
        }

        let parser = S3MultipartUploadParser()
        guard let uploadId = parser.parse(data: data) else {
            throw S3Error.apiError(500, "Failed to parse UploadId from response")
        }
        return uploadId
    }

    func uploadPart(key: String, uploadId: String, partNumber: Int, data: Data) async throws
        -> String
    {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "partNumber", value: "\(partNumber)"),
            URLQueryItem(name: "uploadId", value: uploadId),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        try signRequest(request: &request, payload: data)
        request.httpBody = data
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let attemptedURL = request.url?.absoluteString ?? "Unknown URL"
            throw S3Error.apiError(
                httpResponse.statusCode, "UploadPart Failed for URL: \(attemptedURL)")
        }

        guard
            let etag = httpResponse.allHeaderFields["Etag"] as? String
                ?? httpResponse.allHeaderFields["ETag"] as? String
        else {
            throw S3Error.apiError(500, "No ETag in UploadPart response")
        }

        return etag.replacingOccurrences(of: "\"", with: "")
    }

    func completeMultipartUpload(key: String, uploadId: String, parts: [Int: String]) async throws {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadId", value: uploadId)]

        var xmlBody = "<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">"
        let sortedNumbers = parts.keys.sorted()
        for num in sortedNumbers {
            xmlBody += "<Part><PartNumber>\(num)</PartNumber><ETag>\"\(parts[num]!)\"</ETag></Part>"
        }
        xmlBody += "</CompleteMultipartUpload>"

        let bodyData = xmlBody.data(using: .utf8)!
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        try signRequest(request: &request, payload: bodyData)
        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "CompleteMultipart Failed: \(body)")
        }
    }

    func abortMultipartUpload(key: String, uploadId: String) async throws {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadId", value: uploadId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "DELETE"
        try signRequest(request: &request, payload: "")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            throw S3Error.apiError(httpResponse.statusCode, "AbortMultipart Failed")
        }
    }

    func listMultipartUploads() async throws -> [S3ActiveUpload] {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploads", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            throw S3Error.apiError(httpResponse.statusCode, "ListUploads Failed")
        }

        return S3ActiveUploadsParser().parse(data: data)
    }

    func listParts(key: String, uploadId: String) async throws -> [Int: (etag: String, size: Int64)]
    {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploadId", value: uploadId)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            throw S3Error.apiError(httpResponse.statusCode, "ListParts Failed")
        }

        return S3PartsParser().parse(data: data)
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
        let parser = S3VersionParser(expectedKey: key)
        return parser.parse(data: data).filter { $0.key == key }
    }

    func headObject(key: String, versionId: String? = nil) async throws -> [String: String] {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        try signRequest(request: &request, payload: "")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            throw S3Error.apiError(httpResponse.statusCode, "Head Failed")
        }

        var metadata: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyStr = key as? String {
                metadata[keyStr.lowercased()] = value as? String
            }
        }
        return metadata
    }

    func getObject(key: String, versionId: String? = nil) async throws -> (Data, [String: String]) {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "GetObject Failed: \(body)")
        }

        var metadata: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyStr = key as? String, let valueStr = value as? String {
                metadata[keyStr.lowercased()] = valueStr
            }
        }
        return (data, metadata)
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

    func fetchObjectRange(key: String, versionId: String? = nil, range: String) async throws -> (
        Data, [String: String]
    ) {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(range, forHTTPHeaderField: "Range")
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        // 206 Partial Content is expected for Range requests
        if !(200...299).contains(httpResponse.statusCode) && httpResponse.statusCode != 206 {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "Download Range Failed: \(body)")
        }

        var metadata: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            if let keyStr = key as? String {
                metadata[keyStr.lowercased()] = value as? String
            }
        }
        return (data, metadata)
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

    // MARK: - Object Lock & Legal Hold

    func getObjectRetention(key: String, versionId: String? = nil) async throws
        -> S3ObjectRetention?
    {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "retention", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if httpResponse.statusCode == 404 { return nil }
        if !(200...299).contains(httpResponse.statusCode) { return nil }

        return S3RetentionParser().parse(data: data)
    }

    func putObjectRetention(
        key: String, versionId: String? = nil, mode: S3RetentionMode, until: Date
    ) async throws {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "retention", value: nil)]

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateStr = formatter.string(from: until)

        let xml = """
            <Retention xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Mode>\(mode.rawValue)</Mode>
               <RetainUntilDate>\(dateStr)</RetainUntilDate>
            </Retention>
            """
        let body = xml.data(using: .utf8)!

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try signRequest(request: &request, payload: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw S3Error.apiError(httpResponse.statusCode, "PutRetention Failed: \(bodyStr)")
        }
    }

    func getObjectLegalHold(key: String, versionId: String? = nil) async throws -> Bool {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "legal-hold", value: nil)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if httpResponse.statusCode == 404 { return false }
        if !(200...299).contains(httpResponse.statusCode) { return false }

        return S3LegalHoldParser().parse(data: data)
    }

    func putObjectLegalHold(key: String, versionId: String? = nil, enabled: Bool) async throws {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "legal-hold", value: nil)]

        let status = enabled ? "ON" : "OFF"
        let xml = """
            <LegalHold xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Status>\(status)</Status>
            </LegalHold>
            """
        let body = xml.data(using: .utf8)!

        var request = URLRequest(url: components.url!)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try signRequest(request: &request, payload: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw S3Error.apiError(httpResponse.statusCode, "PutLegalHold Failed: \(bodyStr)")
        }
    }

    func getBucketObjectLockConfiguration() async throws -> Bool {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "object-lock", value: nil)]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if httpResponse.statusCode == 404 || httpResponse.statusCode == 403 { return false }
        if !(200...299).contains(httpResponse.statusCode) { return false }
        let bodyString = String(data: data, encoding: .utf8) ?? ""
        return bodyString.contains("<ObjectLockEnabled>Enabled</ObjectLockEnabled>")
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
            try Task.checkCancellation()
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
        // x-amz-copy-source must be URL encoded. Standard S3: /bucket/key_fully_encoded
        let encodedKeyPart = awsEncode(safeSourceKey, encodeSlash: true)
        let headerValue = "/\(bucket)/\(encodedKeyPart)"
        request.setValue(headerValue, forHTTPHeaderField: "x-amz-copy-source")

        print("[S3] Copying from: \(headerValue) to: \(destinationKey)")

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

        print("[S3] Canonical Request:\n\(canonicalRequest)")

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

    // MARK: - Bucket Lifecycle

    func getBucketLifecycle() async throws -> [S3LifecycleRule] {
        let urlString =
            usePathStyle
            ? "\(endpoint)/\(bucket)?lifecycle"
            : (endpoint.hasPrefix("https://")
                ? "https://\(bucket).\(endpoint.dropFirst(8))?lifecycle"
                : "http://\(bucket).\(endpoint.dropFirst(7))?lifecycle")

        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if httpResponse.statusCode == 404 { return [] }
        if !(200...299).contains(httpResponse.statusCode) { return [] }

        return S3LifecycleParser().parse(data: data)
    }

    func putBucketLifecycle(rules: [S3LifecycleRule]) async throws {
        let urlString =
            usePathStyle
            ? "\(endpoint)/\(bucket)?lifecycle"
            : (endpoint.hasPrefix("https://")
                ? "https://\(bucket).\(endpoint.dropFirst(8))?lifecycle"
                : "http://\(bucket).\(endpoint.dropFirst(7))?lifecycle")

        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<LifecycleConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">\n"

        for rule in rules {
            xml += "  <Rule>\n"
            xml += "    <ID>\(rule.id)</ID>\n"
            xml += "    <Status>\(rule.status.rawValue)</Status>\n"
            xml += "    <Prefix>\(rule.prefix)</Prefix>\n"

            for transition in rule.transitions {
                xml += "    <Transition>\n"
                if let days = transition.days {
                    xml += "      <Days>\(days)</Days>\n"
                }
                xml += "      <StorageClass>\(transition.storageClass)</StorageClass>\n"
                xml += "    </Transition>\n"
            }

            if let expiration = rule.expiration {
                xml += "    <Expiration>\n"
                if let days = expiration.days {
                    xml += "      <Days>\(days)</Days>\n"
                }
                xml += "    </Expiration>\n"
            }

            if let abortDays = rule.abortIncompleteMultipartUploadDays {
                xml += "    <AbortIncompleteMultipartUpload>\n"
                xml += "      <DaysAfterInitiation>\(abortDays)</DaysAfterInitiation>\n"
                xml += "    </AbortIncompleteMultipartUpload>\n"
            }

            xml += "  </Rule>\n"
        }

        xml += "</LifecycleConfiguration>"

        let body = xml.data(using: .utf8)!

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        // Important: Calculate Content-MD5 for Lifecycle updates (often required)
        let md5 = Insecure.MD5.hash(data: body)
        let md5Base64 = Data(md5).base64EncodedString()
        request.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")

        try signRequest(request: &request, payload: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw S3Error.apiError(httpResponse.statusCode, "PutLifecycle Failed: \(bodyStr)")
        }
    }

    private func parseListObjectsResponse(data: Data, prefix: String) -> ([S3Object], String) {
        let parser = S3XMLParser(prefix: prefix)
        let objects = parser.parse(data: data)
        return (objects, "")
    }

    func listFolders(prefix: String, recursive: Bool = false) async throws -> [String] {
        let url = try generateDownloadURL(key: "")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        var queryItems = [
            URLQueryItem(name: "list-type", value: "2"),
            URLQueryItem(name: "prefix", value: prefix),
        ]

        if !recursive {
            queryItems.append(URLQueryItem(name: "delimiter", value: "/"))
        }

        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw S3Error.apiError(httpResponse.statusCode, "ListFolders Failed: \(body)")
        }

        if recursive {
            let parser = S3RecursiveFolderParser(rootPrefix: prefix)
            return parser.parse(data: data)
        } else {
            let parser = S3FolderParser()
            return parser.parse(data: data)
        }
    }

}

class S3FolderParser: NSObject, XMLParserDelegate {
    private var folders: [String] = []
    private var currentElement = ""
    private var inCommonPrefixes = false
    private var currentPrefix = ""

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return folders
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "CommonPrefixes" {
            inCommonPrefixes = true
        }
        if inCommonPrefixes && elementName == "Prefix" {
            currentPrefix = ""
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "CommonPrefixes" {
            inCommonPrefixes = false
        }
        if inCommonPrefixes && elementName == "Prefix" {
            if !currentPrefix.isEmpty {
                folders.append(currentPrefix)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inCommonPrefixes && currentElement == "Prefix" {
            currentPrefix += string
        }
    }
}

class S3RecursiveFolderParser: NSObject, XMLParserDelegate {
    private var folders: Set<String> = []
    private var currentElement = ""
    private var rootPrefix: String
    private var currentKey = ""

    init(rootPrefix: String) {
        self.rootPrefix = rootPrefix
        super.init()
    }

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Array(folders).sorted()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Key" {
            currentKey = ""
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Key" {
            processKey(currentKey)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "Key" {
            currentKey += string
        }
    }

    private func processKey(_ key: String) {
        let validKey = key

        if !rootPrefix.isEmpty && !validKey.hasPrefix(rootPrefix) {
            return
        }

        if let lastSlashIndex = validKey.lastIndex(of: "/") {
            let folderPath = String(validKey[...lastSlashIndex])

            if folderPath == rootPrefix { return }

            folders.insert(folderPath)

            var path = folderPath
            while path.count > rootPrefix.count {
                let temp = String(path.dropLast())
                if let prevSlash = temp.lastIndex(of: "/") {
                    path = String(temp[...prevSlash])
                    if path.hasPrefix(rootPrefix) && path != rootPrefix {
                        folders.insert(path)
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }
    }
}
