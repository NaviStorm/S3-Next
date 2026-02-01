import Foundation

class S3LifecycleParser: NSObject, XMLParserDelegate {
    private var rules: [S3LifecycleRule] = []
    private var currentElement = ""
    private var currentRule = S3LifecycleRule()
    private var currentTransition = S3LifecycleTransition(storageClass: "")

    // Accumulators for text content
    private var currentID = ""
    private var currentStatusString = ""
    private var currentPrefix = ""
    private var currentDaysString = ""
    private var currentStorageClass = ""
    private var currentAbortDaysString = ""

    func parse(data: Data) -> [S3LifecycleRule] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rules
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "Rule" {
            currentRule = S3LifecycleRule()
            currentID = ""
            currentStatusString = ""
            currentPrefix = ""
            currentAbortDaysString = ""
        } else if elementName == "Transition" {
            currentTransition = S3LifecycleTransition(storageClass: "")
            currentDaysString = ""
            currentStorageClass = ""
        } else if elementName == "Expiration" {
            currentRule.expiration = S3LifecycleExpiration()
            currentDaysString = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return }

        switch currentElement {
        case "ID": currentID += cleaned
        case "Status": currentStatusString += cleaned
        case "Prefix": currentPrefix += cleaned
        case "Days": currentDaysString += cleaned
        case "StorageClass": currentStorageClass += cleaned
        case "DaysAfterInitiation": currentAbortDaysString += cleaned
        default: break
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "ID":
            currentRule.id = currentID
        case "Status":
            currentRule.status = S3LifecycleStatus(rawValue: currentStatusString) ?? .disabled
        case "Prefix":
            currentRule.prefix = currentPrefix
        case "Transition":
            currentTransition.days = Int(currentDaysString)
            currentTransition.storageClass = currentStorageClass
            currentRule.transitions.append(currentTransition)
        case "Expiration":
            currentRule.expiration?.days = Int(currentDaysString)
        case "AbortIncompleteMultipartUpload":
            currentRule.abortIncompleteMultipartUploadDays = Int(currentAbortDaysString)
        case "Rule":
            rules.append(currentRule)
        default:
            break
        }
    }
}
