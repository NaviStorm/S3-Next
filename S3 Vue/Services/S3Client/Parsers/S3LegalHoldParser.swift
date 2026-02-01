import Foundation

class S3LegalHoldParser: NSObject, XMLParserDelegate {
    var status: Bool = false
    private var currentElement = ""
    private var statusString = ""

    func parse(data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return status
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
        if currentElement == "Status" { statusString += cleaned }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "LegalHold" {
            status = (statusString.uppercased() == "ON")
        }
    }
}
