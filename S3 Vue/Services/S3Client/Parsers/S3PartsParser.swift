import Foundation

class S3PartsParser: NSObject, XMLParserDelegate {
    var parts: [Int: (etag: String, size: Int64)] = [:]
    private var currentElement = ""
    private var currentPartNumber: Int? = nil
    private var currentETag: String? = nil
    private var currentSize: Int64? = nil

    func parse(data: Data) -> [Int: (etag: String, size: Int64)] {
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
        } else if currentElement == "Size" {
            currentSize = Int64(cleaned)
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Part" {
            if let num = currentPartNumber, let etag = currentETag, let size = currentSize {
                parts[num] = (etag, size)
            }
            currentPartNumber = nil
            currentETag = nil
            currentSize = nil
        }
    }
}
