import Foundation

class S3XMLParser: NSObject, XMLParserDelegate {
    private let prefix: String
    private let filterPrefix: Bool
    private var objects: [S3Object] = []

    private var currentElement = ""
    private var currentKey = ""
    private var currentSize: Int64 = 0
    private var currentLastModifiedString = ""
    private var currentETag = ""
    private var currentPrefixValue = ""
    private var inContents = false
    private var isTruncatedString = ""

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
            currentETag = ""
        } else if elementName == "CommonPrefixes" {
            currentPrefixValue = ""
        } else if elementName == "IsTruncated" {
            isTruncatedString = ""
        } else if elementName == "NextContinuationToken" {
            if nextContinuationToken == nil { nextContinuationToken = "" }
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
            } else if currentElement == "ETag" {
                currentETag += string
            }
        } else {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentElement == "IsTruncated" {
                isTruncatedString += cleaned
            } else if currentElement == "NextContinuationToken" {
                if !cleaned.isEmpty {
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
            let eTag = currentETag.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")

            // Support pour certains providers S3 qui renvoient des clés relatives au préfixe
            if !prefix.isEmpty && !key.hasPrefix(prefix) {
                key = prefix + key
            }

            // Include prefix itself if filterPrefix is false
            if !key.isEmpty && (filterPrefix ? key != prefix : true) {
                objects.append(
                    S3Object(
                        key: key, size: currentSize, lastModified: date, eTag: eTag, isFolder: false
                    ))
            }
        } else if elementName == "CommonPrefixes" {
            var folderKey = currentPrefixValue.trimmingCharacters(in: .init(charactersIn: "\n\r"))

            // Support pour chemins relatifs sur CommonPrefixes
            if !prefix.isEmpty && !folderKey.hasPrefix(prefix) {
                folderKey = prefix + folderKey
            }

            if !folderKey.isEmpty && (filterPrefix ? folderKey != prefix : true) {
                objects.append(
                    S3Object(
                        key: folderKey, size: 0, lastModified: Date(), eTag: nil, isFolder: true)
                )
            }
        } else if elementName == "IsTruncated" {
            isTruncated = (isTruncatedString.lowercased() == "true")
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

    var isTruncated = false
    var nextKeyMarker: String? = nil
    var nextVersionIdMarker: String? = nil
    private var isTruncatedString = ""

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
        } else if elementName == "IsTruncated" {
            isTruncatedString = ""
        } else if elementName == "NextKeyMarker" {
            if nextKeyMarker == nil { nextKeyMarker = "" }
        } else if elementName == "NextVersionIdMarker" {
            if nextVersionIdMarker == nil { nextVersionIdMarker = "" }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inVersion || inDeleteMarker {
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
        } else {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if currentElement == "IsTruncated" {
                isTruncatedString += cleaned
            } else if currentElement == "NextKeyMarker" {
                nextKeyMarker? += cleaned
            } else if currentElement == "NextVersionIdMarker" {
                nextVersionIdMarker? += cleaned
            }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Version" || elementName == "DeleteMarker" {
            let date = parseDate(
                currentLastModifiedString.trimmingCharacters(in: .whitespacesAndNewlines))
            let key = currentKey.trimmingCharacters(in: .init(charactersIn: "\n\r"))

            versions.append(
                S3Version(
                    key: key, versionId: currentVersionId, isLatest: currentIsLatest,
                    lastModified: date, size: currentSize,
                    isDeleteMarker: (elementName == "DeleteMarker")))
            inVersion = false
            inDeleteMarker = false
        } else if elementName == "IsTruncated" {
            isTruncated = (isTruncatedString.lowercased() == "true")
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

class S3MultipartUploadParser: NSObject, XMLParserDelegate {
    var uploadId: String? = nil
    private var currentElement = ""

    func parse(data: Data) -> String? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return uploadId
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "UploadId" {
            let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                if uploadId == nil { uploadId = "" }
                uploadId? += cleaned
            }
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "UploadId" {
            currentElement = ""
        }
    }
}

class S3PartsParser: NSObject, XMLParserDelegate {
    var parts: [Int: String] = [:]
    private var currentElement = ""
    private var currentPartNumber: Int? = nil
    private var currentETag: String? = nil

    func parse(data: Data) -> [Int: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return parts
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return }
        if currentElement == "PartNumber" {
            currentPartNumber = Int(cleaned)
        } else if currentElement == "ETag" {
            currentETag = cleaned.replacingOccurrences(of: "\"", with: "")
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Part" {
            if let num = currentPartNumber, let etag = currentETag {
                parts[num] = etag
            }
            currentPartNumber = nil
            currentETag = nil
        }
    }
}

class S3ActiveUploadsParser: NSObject, XMLParserDelegate {
    var activeUploads: [String: String] = [:]  // Key: UploadId
    private var currentElement = ""
    private var currentKey = ""
    private var currentUploadId = ""

    func parse(data: Data) -> [String: String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return activeUploads
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return }
        if currentElement == "Key" {
            currentKey += cleaned
        } else if currentElement == "UploadId" {
            currentUploadId += cleaned
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Upload" {
            activeUploads[currentKey] = currentUploadId
            currentKey = ""
            currentUploadId = ""
        }
    }
}
