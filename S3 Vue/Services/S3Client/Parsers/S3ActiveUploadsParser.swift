import Foundation

class S3ActiveUploadsParser: NSObject, XMLParserDelegate {
    var activeUploads: [S3ActiveUpload] = []
    private var currentElement = ""
    private var currentKey = ""
    private var currentUploadId = ""
    private var currentInitiatedString = ""

    func parse(data: Data) -> [S3ActiveUpload] {
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
        } else if currentElement == "Initiated" {
            currentInitiatedString += cleaned
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Upload" {
            let date = parseDate(currentInitiatedString)
            activeUploads.append(
                S3ActiveUpload(key: currentKey, uploadId: currentUploadId, initiated: date))
            currentKey = ""
            currentUploadId = ""
            currentInitiatedString = ""
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
