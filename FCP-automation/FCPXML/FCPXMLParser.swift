import Foundation

class FCPXMLParser: NSObject, XMLParserDelegate {

    struct ParsedTimeline {
        var projectName: String = ""
        var clips: [ParsedClip] = []
        var markers: [ParsedMarker] = []
        var formatInfo: FormatInfo = FormatInfo()
    }

    struct ParsedClip {
        var name: String
        var offset: TimeInterval
        var duration: TimeInterval
        var start: TimeInterval
        var assetRef: String
    }

    struct ParsedMarker {
        var start: TimeInterval
        var value: String
    }

    struct FormatInfo {
        var width: Int = 1920
        var height: Int = 1080
        var frameDuration: String = ""
    }

    private var currentTimeline = ParsedTimeline()
    private var currentElement = ""

    func parse(url: URL) throws -> ParsedTimeline {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error = parser.parserError {
            throw error
        }
        return currentTimeline
    }

    func parse(xmlString: String) throws -> ParsedTimeline {
        guard let data = xmlString.data(using: .utf8) else {
            throw NSError(domain: "FCPXMLParser", code: -1, userInfo: [NSLocalizedDescriptionKey: "XML文字列の変換に失敗"])
        }
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        if let error = parser.parserError {
            throw error
        }
        return currentTimeline
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentElement = elementName

        switch elementName {
        case "format":
            if let width = attributes["width"], let w = Int(width) {
                currentTimeline.formatInfo.width = w
            }
            if let height = attributes["height"], let h = Int(height) {
                currentTimeline.formatInfo.height = h
            }
            if let fd = attributes["frameDuration"] {
                currentTimeline.formatInfo.frameDuration = fd
            }

        case "project":
            if let name = attributes["name"] {
                currentTimeline.projectName = name
            }

        case "asset-clip":
            let clip = ParsedClip(
                name: attributes["name"] ?? "",
                offset: parseTimeValue(attributes["offset"] ?? "0s"),
                duration: parseTimeValue(attributes["duration"] ?? "0s"),
                start: parseTimeValue(attributes["start"] ?? "0s"),
                assetRef: attributes["ref"] ?? ""
            )
            currentTimeline.clips.append(clip)

        case "marker":
            let marker = ParsedMarker(
                start: parseTimeValue(attributes["start"] ?? "0s"),
                value: attributes["value"] ?? ""
            )
            currentTimeline.markers.append(marker)

        default:
            break
        }
    }

    private func parseTimeValue(_ value: String) -> TimeInterval {
        // "123.456s" or "1001/30000s" or "0s"
        let cleaned = value.replacingOccurrences(of: "s", with: "")
        if cleaned.contains("/") {
            let parts = cleaned.components(separatedBy: "/")
            if parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0 {
                return num / den
            }
        }
        return Double(cleaned) ?? 0
    }
}
