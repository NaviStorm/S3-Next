import Foundation

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
