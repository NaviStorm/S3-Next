import Foundation

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
