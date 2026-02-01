import Foundation

extension S3Client {

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
            try signRequest(request: &request, method: "GET", payload: "")
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

    func listObjectVersions(key: String) async throws -> [S3Version] {
        let baseUrl = try generateDownloadURL(key: "")
        var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "versions", value: nil), URLQueryItem(name: "prefix", value: key),
        ]
        var request = URLRequest(url: components.url!)
        try signRequest(request: &request, method: "GET", payload: "")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw S3Error.invalidResponse }
        if !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw S3Error.apiError(httpResponse.statusCode, "ListVersions Failed: \(body)")
        }
        let parser = S3VersionParser(expectedKey: key)
        return parser.parse(data: data).filter { $0.key == key }
    }
}
