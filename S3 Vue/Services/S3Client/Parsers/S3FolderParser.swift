import Foundation

class S3FolderParser: NSObject, XMLParserDelegate {
    private var folders: [String] = []
    private var currentElement = ""
    private var inCommonPrefixes = false
    private var currentPrefix = ""

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return folders
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "CommonPrefixes" {
            inCommonPrefixes = true
        }
        if inCommonPrefixes && elementName == "Prefix" {
            currentPrefix = ""
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "CommonPrefixes" {
            inCommonPrefixes = false
        }
        if inCommonPrefixes && elementName == "Prefix" {
            if !currentPrefix.isEmpty {
                folders.append(currentPrefix)
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inCommonPrefixes && currentElement == "Prefix" {
            currentPrefix += string
        }
    }
}
