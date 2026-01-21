import Foundation
import SwiftUI
import CommonCrypto

@main
struct S3_VueApp: App {
    @StateObject private var appState = S3AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .commands {
            CommandMenu("Debug") {
                OpenDebugWindowButton()
            }
        }
        
        Window("Debug Logs", id: "debug-logs") {
            DebugView()
                .environmentObject(appState)
        }
    }
}

struct OpenDebugWindowButton: View {
    @Environment(\.openWindow) var openWindow
    
    var body: some View {
        Button("Show Debug Logs") {
            openWindow(id: "debug-logs")
        }
        .keyboardShortcut("d", modifiers: [.command, .shift])
    }
}

enum S3Error: Error, LocalizedError {
    case invalidUrl
    case requestFailed(Error)
    case invalidResponse
    case apiError(Int, String)
    
    var errorDescription: String? {
        switch self {
        case .invalidUrl: return "Invalid URL configuration."
        case .requestFailed(let error): return "Network request failed: \(error.localizedDescription)"
        case .invalidResponse: return "Invalid server response."
        case .apiError(let statusCode, let body): return "API Error \(statusCode): \(body)"
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

class S3Client {
    private let accessKey: String
    private let secretKey: String
    private let region: String
    private let bucket: String
    private let endpoint: String
    private let usePathStyle: Bool
    
    init(accessKey: String, secretKey: String, region: String, bucket: String, endpoint: String, usePathStyle: Bool) {
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
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~") // Standard unreserved characters
        // Do NOT include '/' or '@' or ':' in allowed, so they get percent-encoded
        
        let encodedPrefix = prefix.addingPercentEncoding(withAllowedCharacters: allowed) ?? prefix
        
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
                     urlString = "https://\(bucket).\(endpoint)/?delimiter=%2F&prefix=\(encodedPrefix)"
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
             if let codeRange = body.range(of: "<Code[^>]*>", options: .regularExpression), let codeEnd = body.range(of: "</Code>") {
                 let code = body[codeRange.upperBound..<codeEnd.lowerBound]
                 errorMsg += ": \(code)"
             }
             if let msgRange = body.range(of: "<Message[^>]*>", options: .regularExpression), let msgEnd = body.range(of: "</Message>") {
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

    func generateDownloadURL(key: String) throws -> URL {
         // Percent encode key
         let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
         
         let urlString: String
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
         
         guard let url = URL(string: urlString) else {
             throw S3Error.invalidUrl
         }
         return url
    }
    
    func fetchObjectData(key: String) async throws -> (Data, String) {
        let url = try generateDownloadURL(key: key)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        try signRequest(request: &request, payload: "")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        var logs = "Download Key: \(key)\nURL: \(url.absoluteString)\n"
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
    
    private func signRequest(request: inout URLRequest, payload: String) throws {
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
        
        // CRITICAL FIX: URL.path returns DECODED string (e.g. "foo bar").
        // AWS Signature requires the EXACT encoded path (e.g. "foo%20bar") as sent.
        // We must re-encode the path segment by segment.
        let rawPath = url.path
        let pathComponents = rawPath.components(separatedBy: "/")
        
        // Allowed characters for S3 Path: Alphanumerics, -._~ (and / is delimiter)
        // We need to encode everything else.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        
        let encodedComponents = pathComponents.map { component -> String in
            return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
        }
        
        let canonicalUri = encodedComponents.joined(separator: "/")
        // Note: joined(separator: "/") might collapse leading/trailing slashes incorrectly if empty components exist?
        // simple URL.path "/foo/bar" -> ["", "foo", "bar"] -> joined -> "/foo/bar". Correct.
        // Root "/" -> ["", ""] -> joined -> "/". Correct.
        
        let canonicalQuery = url.query ?? "" // Simplified
        
        // Headers need to be lowercase and sorted
        // We MUST include host and x-amz-date
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(host, forHTTPHeaderField: "host")
        // Content-SHA256 is required for S3
        let payloadHash = sha256(payload)
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
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
        \(sha256(canonicalRequest))
        """
        
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
        let signature = hmac(key: kSigning, data: stringToSign).map { String(format: "%02x", $0) }.joined()
        
        // 4. Authorization Header
        let authorization = "\(algorithm) Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
    }
    
    // MARK: - Helpers
    
    private func sha256(_ string: String) -> String {
        guard let data = string.data(using: .utf8) else { return "" }
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
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count, dataBytes.baseAddress, dataToSign.count, &result)
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
    
    private let inputPrefix: String
    
    init(prefix: String) {
        self.inputPrefix = prefix
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
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
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
            if currentElement == "Key" { currentKey += string }
            else if currentElement == "Size" { 
                // Filter out newlines/spaces if any
                let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    currentSize = Int64(cleaned) ?? currentSize 
                }
            }
            else if currentElement == "LastModified" { currentLastModifiedString += string }
        } else if inCommonPrefixes {
            if currentElement == "Prefix" { currentPrefix += string }
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
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "Contents" {
            inContents = false
            let finalKey = currentKey.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Filter out the folder placeholder itself (e.g. "folder/")
            if !finalKey.isEmpty {
                 let normalizedKey = finalKey.hasSuffix("/") ? String(finalKey.dropLast()) : finalKey
                 let normalizedInput = inputPrefix.hasSuffix("/") ? String(inputPrefix.dropLast()) : inputPrefix
                 
                 if normalizedKey != normalizedInput {
                    // Parse Date
                    let dateString = currentLastModifiedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    var date = Date() // Default to now if fail
                    
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
                    
                    objects.append(S3Object(key: finalKey, size: currentSize, lastModified: date, isFolder: false))
                 }
            }
        } else if elementName == "CommonPrefixes" {
            inCommonPrefixes = false
            let finalPrefix = currentPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Normalize for comparison (remove trailing slashes)
            let normFinal = finalPrefix.hasSuffix("/") ? String(finalPrefix.dropLast()) : finalPrefix
            let normInput = inputPrefix.hasSuffix("/") ? String(inputPrefix.dropLast()) : inputPrefix
            
            debugLog += "[\(Date().formatted(date: .omitted, time: .standard))] Check: '\(normFinal)' vs Input: '\(normInput)'\n"
            
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
                    objects.append(S3Object(key: finalPrefix, size: 0, lastModified: Date(), isFolder: true))
                }
            }
        }
    }
}
