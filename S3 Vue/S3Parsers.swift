import Foundation

class S3XMLParser: NSObject, XMLParserDelegate {
    private let prefix: String
    private let filterPrefix: Bool
    private var objects: [S3Object] = []

    private var currentElement = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentLastModifiedString = ""
    private var currentPrefixValue = ""
    private var inContents = false

    var isTruncated = false
    var nextContinuationToken: String? = nil

    init(prefix: String, filterPrefix: Bool = true) {
        self.prefix = prefix
        self.filterPrefix = filterPrefix
    }

    func parse(data: Data) -> [S3Object] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return objects
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
            currentPrefixValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inContents {
            if currentElement == "Key" {
                currentKey += string
            } else if currentElement == "Size" {
                let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { currentSize = Int64(cleaned) ?? 0 }
            } else if currentElement == "LastModified" {
                currentLastModifiedString += string
            }
        } else {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentElement == "IsTruncated" {
                if !cleaned.isEmpty { isTruncated = (cleaned.lowercased() == "true") }
            } else if currentElement == "NextContinuationToken" {
                if !cleaned.isEmpty {
                    if nextContinuationToken == nil { nextContinuationToken = "" }
                    nextContinuationToken? += cleaned
                }
            } else if currentElement == "Prefix" {
                currentPrefixValue += string
            }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Contents" {
            inContents = false
            let date = parseDate(
                currentLastModifiedString.trimmingCharacters(in: .whitespacesAndNewlines))
            var key = currentKey.trimmingCharacters(in: .init(charactersIn: "\n\r"))

            // Support pour certains providers S3 qui renvoient des clés relatives au préfixe
            if !prefix.isEmpty && !key.hasPrefix(prefix) {
                key = prefix + key
            }

            // Include prefix itself if filterPrefix is false
            if !key.isEmpty && (filterPrefix ? key != prefix : true) {
                objects.append(
                    S3Object(key: key, size: currentSize, lastModified: date, isFolder: false))
            }
        } else if elementName == "CommonPrefixes" {
            var folderKey = currentPrefixValue.trimmingCharacters(in: .init(charactersIn: "\n\r"))

            // Support pour chemins relatifs sur CommonPrefixes
            if !prefix.isEmpty && !folderKey.hasPrefix(prefix) {
                folderKey = prefix + folderKey
            }

            if !folderKey.isEmpty && (filterPrefix ? folderKey != prefix : true) {
                objects.append(
                    S3Object(key: folderKey, size: 0, lastModified: Date(), isFolder: true))
            }
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

class S3VersionParser: NSObject, XMLParserDelegate {
    private let expectedKey: String
    private var versions: [S3Version] = []
    private var currentElement = ""
    private var currentKey = ""
    private var currentVersionId = ""
    private var currentIsLatest = false
    private var currentLastModifiedString = ""
    private var currentSize: Int64 = 0
    private var inVersion = false
    private var inDeleteMarker = false

    init(expectedKey: String = "") {
        self.expectedKey = expectedKey
    }

    func parse(data: Data) -> [S3Version] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return versions
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
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "Key" {
            currentKey += string
        } else if currentElement == "VersionId" {
            currentVersionId += string
        } else if currentElement == "IsLatest" {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { currentIsLatest = (cleaned.lowercased() == "true") }
        } else if currentElement == "LastModified" {
            currentLastModifiedString += string
        } else if currentElement == "Size" {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { currentSize = Int64(cleaned) ?? 0 }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Version" || elementName == "DeleteMarker" {
            let date = parseDate(
                currentLastModifiedString.trimmingCharacters(in: .whitespacesAndNewlines))
            var key = currentKey.trimmingCharacters(in: .init(charactersIn: "\n\r"))

            // Support pour clés relatives : si la clé reçue est juste le nom, on utilise expectedKey
            if !expectedKey.isEmpty && !key.hasPrefix(expectedKey) && key.count < expectedKey.count
            {
                // Si expectedKey est "folder/file.txt" et key est "file.txt"
                key = expectedKey
            }

            versions.append(
                S3Version(
                    key: key, versionId: currentVersionId, isLatest: currentIsLatest,
                    lastModified: date, size: currentSize,
                    isDeleteMarker: (elementName == "DeleteMarker")))
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
