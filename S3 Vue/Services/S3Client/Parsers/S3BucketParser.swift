import Foundation

class S3BucketParser: NSObject, XMLParserDelegate {
    private var buckets: [String] = []
    private var currentElement = ""
    private var currentName = ""

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return buckets
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Bucket" {
            currentName = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "Name" {
            currentName += string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Bucket" {
            if !currentName.isEmpty {
                buckets.append(currentName)
            }
        }
    }
}
