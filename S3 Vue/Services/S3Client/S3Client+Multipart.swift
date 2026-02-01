import Foundation

extension S3Client {
    // MARK: - Multipart Upload

    func createMultipartUpload(key: String, metadata: [String: String] = [:]) async throws -> String
    {
        let url = try generateDownloadURL(key: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "uploads", value: nil)]

        var request = URLRequest(url: components.url!)
        for (mKey, mValue) in metadata {
            request.setValue(mValue, forHTTPHeaderField: "x-amz-meta-\(mKey)")
        }

        try signRequest(request: &request, method: "POST", payload: "")
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
        try signRequest(request: &request, method: "PUT", payload: data)
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
        try signRequest(request: &request, method: "POST", payload: bodyData)
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
        try signRequest(request: &request, method: "DELETE", payload: "")

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
        try signRequest(request: &request, method: "GET", payload: "")

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
        try signRequest(request: &request, method: "GET", payload: "")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }

        if !(200...299).contains(httpResponse.statusCode) {
            throw S3Error.apiError(httpResponse.statusCode, "ListParts Failed")
        }

        return S3PartsParser().parse(data: data)
    }
}
