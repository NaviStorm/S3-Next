import Foundation

class S3RecursiveFolderParser: NSObject, XMLParserDelegate {
    private var folders: Set<String> = []
    private var currentElement = ""
    private var rootPrefix: String
    private var currentKey = ""

    init(rootPrefix: String) {
        self.rootPrefix = rootPrefix
        super.init()
    }

    func parse(data: Data) -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return Array(folders).sorted()
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Key" {
            currentKey = ""
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "Key" {
            processKey(currentKey)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "Key" {
            currentKey += string
        }
    }

    private func processKey(_ key: String) {
        let validKey = key

        if !rootPrefix.isEmpty && !validKey.hasPrefix(rootPrefix) {
            return
        }

        if let lastSlashIndex = validKey.lastIndex(of: "/") {
            let folderPath = String(validKey[...lastSlashIndex])

            if folderPath == rootPrefix { return }

            folders.insert(folderPath)

            var path = folderPath
            while path.count > rootPrefix.count {
                let temp = String(path.dropLast())
                if let prevSlash = temp.lastIndex(of: "/") {
                    path = String(temp[...prevSlash])
                    if path.hasPrefix(rootPrefix) && path != rootPrefix {
                        folders.insert(path)
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        }
    }
}
