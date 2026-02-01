import Foundation

class S3RetentionParser: NSObject, XMLParserDelegate {
    var retention: S3ObjectRetention?
    private var currentElement = ""
    private var modeString = ""
    private var dateString = ""

    func parse(data: Data) -> S3ObjectRetention? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return retention
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
        if currentElement == "Mode" {
            modeString += cleaned
        } else if currentElement == "RetainUntilDate" {
            dateString += cleaned
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Retention" {
            if let mode = S3RetentionMode(rawValue: modeString) {
                let date = parseDate(dateString)
                retention = S3ObjectRetention(mode: mode, retainUntilDate: date)
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
