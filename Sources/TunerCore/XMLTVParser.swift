import Foundation

public enum XMLTVTime {
    /// Parses `YYYYMMDDHHMMSS` with an optional ` ±HHMM` offset. No offset means UTC.
    public static func parse(_ s: String) -> Date? {
        let b = Array(s.utf8)
        guard b.count >= 14 else { return nil }
        func num(_ from: Int, _ count: Int) -> Int? {
            var v = 0
            for i in from..<(from + count) {
                let d = Int(b[i]) - 48
                guard d >= 0, d <= 9 else { return nil }
                v = v * 10 + d
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2),
              let h = num(8, 2), let mi = num(10, 2), let sec = num(12, 2),
              (1...12).contains(mo), d >= 1, d <= daysIn(month: mo, year: y), h < 24, mi < 60, sec < 61
        else { return nil }

        var offset = 0
        var i = 14
        while i < b.count, b[i] == 0x20 { i += 1 }
        if i < b.count {
            guard b.count - i == 5, b[i] == 0x2B || b[i] == 0x2D,
                  let oh = num(i + 1, 2), let om = num(i + 3, 2), om < 60
            else { return nil }
            offset = (oh * 3600 + om * 60) * (b[i] == 0x2D ? -1 : 1)
        }

        // Days from civil date (proleptic Gregorian), epoch 1970-01-01.
        let yy = mo <= 2 ? y - 1 : y
        let era = yy / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let seconds = days * 86_400 + h * 3600 + mi * 60 + sec - offset
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Gregorian: a date such as 31 February is refused, not carried into March.
    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
            return leap ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }
}

public enum XMLTVParser {
    /// Streams the file; never holds the whole document in memory. Throws only if the file cannot be opened
    /// or the XML is broken before any element was delivered; a truncated tail ends the parse with what was
    /// read, and a summary that is not `complete`.
    public static func parse(fileAt url: URL,
                             onChannel: (ParsedGuideChannel) throws -> Void,
                             onProgramme: (ParsedProgramme) throws -> Void) throws -> XMLTVSummary {
        guard let stream = InputStream(url: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        stream.open()
        defer { stream.close() }
        if let error = stream.streamError { throw error }

        return try withoutActuallyEscaping(onChannel) { onChannel in
            try withoutActuallyEscaping(onProgramme) { onProgramme in
                let delegate = Delegate(onChannel: onChannel, onProgramme: onProgramme)
                let parser = XMLParser(stream: stream)
                parser.delegate = delegate
                let ok = parser.parse()
                if let error = delegate.callbackError { throw error }
                var summary = delegate.summary
                if !ok, summary.channels + summary.programmes + summary.skipped == 0 {
                    throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
                }
                summary.complete = ok
                return summary
            }
        }
    }

    final class Delegate: NSObject, XMLParserDelegate {
        let onChannel: (ParsedGuideChannel) throws -> Void
        let onProgramme: (ParsedProgramme) throws -> Void
        var summary = XMLTVSummary(channels: 0, programmes: 0, skipped: 0)
        var callbackError: Error?

        private var channel: ParsedGuideChannel?
        private var programme: ProgrammeDraft?
        private var text = ""
        private var capturing = false

        private struct ProgrammeDraft {
            var channelID: String?
            var start: Date?
            var stop: Date?
            var title: String?
            var subTitle: String?
            var desc: String?
            var categories: [String] = []
        }

        init(onChannel: @escaping (ParsedGuideChannel) throws -> Void,
             onProgramme: @escaping (ParsedProgramme) throws -> Void) {
            self.onChannel = onChannel
            self.onProgramme = onProgramme
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes attrs: [String: String]) {
            switch name {
            case "channel":
                channel = ParsedGuideChannel(id: attrs["id"] ?? "", displayNames: [], iconURL: nil)
            case "programme":
                programme = ProgrammeDraft(
                    channelID: attrs["channel"],
                    start: attrs["start"].flatMap(XMLTVTime.parse),
                    stop: attrs["stop"].flatMap(XMLTVTime.parse))
            case "icon":
                if channel != nil, channel?.iconURL == nil, let src = attrs["src"], !src.isEmpty {
                    channel?.iconURL = src
                }
            case "display-name" where channel != nil,
                 "title" where programme != nil,
                 "sub-title" where programme != nil,
                 "desc" where programme != nil,
                 "category" where programme != nil:
                text = ""
                capturing = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturing { text += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if capturing { text += String(decoding: CDATABlock, as: UTF8.self) }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            switch name {
            case "display-name" where capturing && channel != nil:
                let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { channel?.displayNames.append(v) }
                capturing = false
            case "title" where capturing && programme != nil:
                let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if programme?.title == nil, !v.isEmpty { programme?.title = v }
                capturing = false
            case "sub-title" where capturing && programme != nil:
                let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if programme?.subTitle == nil, !v.isEmpty { programme?.subTitle = v }
                capturing = false
            case "desc" where capturing && programme != nil:
                let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if programme?.desc == nil, !v.isEmpty { programme?.desc = v }
                capturing = false
            case "category" where capturing && programme != nil:
                let v = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { programme?.categories.append(v) }
                capturing = false
            case "channel":
                defer { channel = nil }
                guard let c = channel else { return }
                if c.id.isEmpty { summary.skipped += 1; return }
                deliver(parser) { try onChannel(c) }
                summary.channels += 1
            case "programme":
                defer { programme = nil }
                guard let p = programme else { return }
                guard let channelID = p.channelID, !channelID.isEmpty,
                      let start = p.start, let stop = p.stop, stop > start,
                      let title = p.title
                else { summary.skipped += 1; return }
                let parsed = ParsedProgramme(channelID: channelID, start: start, stop: stop, title: title,
                                             subTitle: p.subTitle, desc: p.desc, categories: p.categories)
                deliver(parser) { try onProgramme(parsed) }
                summary.programmes += 1
            default:
                break
            }
        }

        /// After a callback has thrown, nothing more is delivered, whether or not the aborted parser
        /// still reports elements.
        private func deliver(_ parser: XMLParser, _ body: () throws -> Void) {
            guard callbackError == nil else { return }
            do { try body() } catch {
                callbackError = error
                parser.abortParsing()
            }
        }
    }
}
