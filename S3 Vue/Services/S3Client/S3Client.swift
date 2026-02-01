import CommonCrypto
import CryptoKit
import Foundation

class S3Client {
    let accessKey: String
    let secretKey: String
    let region: String
    let bucket: String
    let endpoint: String
    let usePathStyle: Bool

    // Callback pour le logging avec contexte (Message, File, Function, Line)
    public var onLog: ((String, String, String, Int) -> Void)?

    init(
        accessKey: String, secretKey: String, region: String, bucket: String, endpoint: String,
        usePathStyle: Bool, onLog: ((String, String, String, Int) -> Void)? = nil
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

        self.onLog = onLog

        let initMsg =
            "[S3Client] Initialized: Bucket=\(bucket), Region=\(self.region), Endpoint=\(endpoint), PathStyle=\(usePathStyle)"
        print(initMsg)
        print(initMsg)
        self.onLog?(initMsg, #file, #function, #line)
    }

    // Helper interne pour logger avec le contexte
    func log(
        _ message: String, file: String = #file, function: String = #function, line: Int = #line
    ) {
        print(message)
        onLog?(message, file, function, line)
    }

    func awsEncode(_ string: String, encodeSlash: Bool = true) -> String {
        // Strict set of allowed characters for S3 V4
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var finalAllowed = allowed
        if !encodeSlash { finalAllowed.insert(charactersIn: "/") }

        // addingPercentEncoding correctly handles all characters not in finalAllowed, including '%'
        return string.addingPercentEncoding(withAllowedCharacters: finalAllowed) ?? string
    }

    // MARK: - Public API

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

    // MARK: - Object Lock & Legal Hold

    func signRequest(request: inout URLRequest, method: String, payload: Any) throws {
        request.httpMethod = method

        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        let amzDate = dateFormatter.string(from: date)
        dateFormatter.dateFormat = "yyyyMMdd"
        let datestamp = dateFormatter.string(from: date)

        guard let url = request.url, let host = url.host else { return }

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

}
