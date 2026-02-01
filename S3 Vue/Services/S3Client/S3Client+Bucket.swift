import CryptoKit
import Foundation

extension S3Client {
    func listBuckets() async throws -> [String] {
        var urlString: String
        log("[S3-DEBUG] Starting listBuckets. Region: \(region), Endpoint: \(endpoint)")

        if !endpoint.isEmpty {
            urlString = endpoint.hasPrefix("http") ? endpoint : "https://\(endpoint)"
            if urlString.hasSuffix("/") { urlString = String(urlString.dropLast()) }
        } else {
            urlString = "https://s3.\(region).amazonaws.com"
        }
        log("[S3-DEBUG] listBuckets URL: \(urlString)")

        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }
        var request = URLRequest(url: url)
        log("[S3-DEBUG] Signing request for listBuckets...")

        try signRequest(request: &request, method: "GET", payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            log("[S3-DEBUG] listBuckets: Invalid Response (not HTTP)")
            throw S3Error.invalidResponse
        }

        if !(200...299).contains(httpResponse.statusCode) {
            log("[S3-DEBUG] listBuckets: HTTP Error \(httpResponse.statusCode)")
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

        try signRequest(request: &request, method: "PUT", payload: bodyData)
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

        try signRequest(request: &request, method: "DELETE", payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw S3Error.apiError(httpResponse.statusCode, "DeleteBucket Failed: \(body)")
        }
    }

    func getBucketObjectLockConfiguration() async throws -> Bool {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "object-lock", value: nil)]
        var request = URLRequest(url: components.url!)
        try signRequest(request: &request, method: "GET", payload: "")
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
        try signRequest(request: &request, method: "GET", payload: "")
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

        let status = enabled ? "Enabled" : "Suspended"
        let xmlBody =
            "<VersioningConfiguration xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Status>\(status)</Status></VersioningConfiguration>"
        let bodyData = xmlBody.data(using: .utf8)!

        request.httpBody = bodyData
        request.setValue("\(bodyData.count)", forHTTPHeaderField: "Content-Length")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try signRequest(request: &request, method: "PUT", payload: bodyData)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "PutVersioning Failed: \(errorBody)")
        }
    }

    func getBucketLifecycle() async throws -> [S3LifecycleRule] {
        let urlString =
            usePathStyle
            ? "\(endpoint)/\(bucket)?lifecycle"
            : (endpoint.hasPrefix("https://")
                ? "https://\(bucket).\(endpoint.dropFirst(8))?lifecycle"
                : "http://\(bucket).\(endpoint.dropFirst(7))?lifecycle")

        guard let url = URL(string: urlString) else { throw S3Error.invalidUrl }

        var request = URLRequest(url: url)
        try signRequest(request: &request, method: "GET", payload: "")

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
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")

        // Important: Calculate Content-MD5 for Lifecycle updates (often required)
        let md5 = Insecure.MD5.hash(data: body)
        let md5Base64 = Data(md5).base64EncodedString()
        request.setValue(md5Base64, forHTTPHeaderField: "Content-MD5")

        try signRequest(request: &request, method: "PUT", payload: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw S3Error.apiError(httpResponse.statusCode, "PutLifecycle Failed: \(bodyStr)")
        }
    }
}
