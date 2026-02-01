import Foundation

extension S3Client {
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
            try signRequest(request: &request, method: "GET", payload: "")

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

    func deleteObject(key: String, versionId: String? = nil) async throws {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        try signRequest(request: &request, method: "DELETE", payload: "")
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
            try signRequest(request: &request, method: "GET", payload: "")
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
        try signRequest(request: &request, method: "PUT", payload: bodyData)
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

    func headObject(key: String, versionId: String? = nil) async throws -> [String: String] {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var request = URLRequest(url: url)
        try signRequest(request: &request, method: "HEAD", payload: "")

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
        try signRequest(request: &request, method: "GET", payload: "")

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
        try signRequest(request: &request, method: "GET", payload: "")
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
        request.setValue(range, forHTTPHeaderField: "Range")
        try signRequest(request: &request, method: "GET", payload: "")

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
        request.setValue(isPublic ? "public-read" : "private", forHTTPHeaderField: "x-amz-acl")
        try signRequest(request: &request, method: "PUT", payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "SetACL Failed: \(errorBody)")
        }
    }

    func getObjectRetention(key: String, versionId: String? = nil) async throws
        -> S3ObjectRetention?
    {
        let url = try generateDownloadURL(key: key, versionId: versionId)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "retention", value: nil)]

        var request = URLRequest(url: components.url!)
        try signRequest(request: &request, method: "GET", payload: "")

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
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try signRequest(request: &request, method: "PUT", payload: body)

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
        try signRequest(request: &request, method: "GET", payload: "")

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
        request.httpBody = body
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        try signRequest(request: &request, method: "PUT", payload: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw S3Error.apiError(httpResponse.statusCode, "PutLegalHold Failed: \(bodyStr)")
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

        try signRequest(request: &request, method: "PUT", payload: "")
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
        try signRequest(request: &request, method: "GET", payload: "")
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

    func parseListObjectsResponse(data: Data, prefix: String) -> ([S3Object], String) {
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
        try signRequest(request: &request, method: "GET", payload: "")

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
