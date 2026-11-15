import Foundation

public enum M3UParser {
    private struct PendingEntry {
        var title: String
        var attributes: [(key: String, value: String)]
    }

    private static let allowedSchemes: Set<String> = ["http", "https", "file", "rtsp", "rtp", "udp"]

    public static func parse(_ text: String) -> M3UParseResult {
        var channels: [ParsedChannel] = []
        var skipped = 0
        var pending: PendingEntry?
        var extgrp: String?
        var isFirstLine = true

        for rawLine in text.utf8.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            var line = Substring(rawLine)
            if isFirstLine {
                isFirstLine = false
                while let f = line.unicodeScalars.first, f == "\u{FEFF}" {
                    line = Substring(line.unicodeScalars.dropFirst())
                }
            }
            line = trimmed(line)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXTINF:") {
                    if pending != nil { skipped += 1 }
                    pending = parseExtinf(line.dropFirst("#EXTINF:".count))
                } else if line.hasPrefix("#EXTGRP:") {
                    let g = trimmed(line.dropFirst("#EXTGRP:".count))
                    extgrp = g.isEmpty ? nil : String(g)
                }
                continue
            }

            // A URL line.
            let entry = pending
            let group = extgrp
            pending = nil
            extgrp = nil
            guard let scheme = scheme(of: line), allowedSchemes.contains(scheme) else {
                skipped += 1
                continue
            }
            channels.append(makeChannel(entry: entry, extgrp: group, url: String(line)))
        }
        if pending != nil { skipped += 1 }
        return M3UParseResult(channels: channels, skippedCount: skipped)
    }

    // MARK: - Helpers

    private static func trimmed(_ s: Substring) -> Substring {
        var s = s
        while let f = s.first, f.isWhitespace { s.removeFirst() }
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return s
    }

    /// Lowercased scheme when the line looks like `scheme://...`.
    private static func scheme(of line: Substring) -> String? {
        guard let r = line.range(of: "://") else { return nil }
        let s = line[line.startIndex..<r.lowerBound]
        guard !s.isEmpty, s.allSatisfy(isSchemeCharacter) else { return nil }
        return s.lowercased()
    }

    private static func isSchemeCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "+" || c == "-" || c == "."
    }

    private static func parseExtinf(_ body: Substring) -> PendingEntry {
        let bytes = Array(body.utf8)
        // Last comma outside double quotes separates attributes from the title.
        var inQuote = false
        var lastComma = -1
        for (i, b) in bytes.enumerated() {
            if b == UInt8(ascii: "\"") { inQuote.toggle() }
            else if b == UInt8(ascii: ",") && !inQuote { lastComma = i }
        }
        let headEnd = lastComma >= 0 ? lastComma : bytes.count
        let title = lastComma >= 0 ? String(decoding: bytes[(lastComma + 1)...], as: UTF8.self) : ""

        var attrs: [(key: String, value: String)] = []
        var i = 0
        // Skip the duration token.
        while i < headEnd, !isSpace(bytes[i]) { i += 1 }
        while i < headEnd {
            while i < headEnd, isSpace(bytes[i]) { i += 1 }
            if i >= headEnd { break }
            let keyStart = i
            while i < headEnd, bytes[i] != UInt8(ascii: "="), !isSpace(bytes[i]) { i += 1 }
            guard i < headEnd, bytes[i] == UInt8(ascii: "=") else { continue } // stray token
            let key = String(decoding: bytes[keyStart..<i], as: UTF8.self)
            i += 1
            let value: String
            if i < headEnd, bytes[i] == UInt8(ascii: "\"") {
                i += 1
                let vStart = i
                while i < headEnd, bytes[i] != UInt8(ascii: "\"") { i += 1 }
                value = String(decoding: bytes[vStart..<i], as: UTF8.self)
                if i < headEnd { i += 1 }
            } else {
                let vStart = i
                while i < headEnd, !isSpace(bytes[i]) { i += 1 }
                value = String(decoding: bytes[vStart..<i], as: UTF8.self)
            }
            if !key.isEmpty { attrs.append((key, value)) }
        }
        return PendingEntry(title: String(trimmed(Substring(title))), attributes: attrs)
    }

    private static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09
    }

    private static func makeChannel(entry: PendingEntry?, extgrp: String?, url: String) -> ParsedChannel {
        var tvgID: String?, tvgName: String?, logo: String?, group: String?
        var extra: [String: String] = [:]
        for (key, value) in entry?.attributes ?? [] {
            switch key.lowercased() {
            case "tvg-id": tvgID = value.isEmpty ? nil : value
            case "tvg-name": tvgName = value.isEmpty ? nil : value
            case "tvg-logo": logo = value.isEmpty ? nil : value
            case "group-title": group = value.isEmpty ? nil : value
            default: extra[key] = value
            }
        }
        var name = entry?.title ?? ""
        if name.isEmpty { name = tvgName ?? "" }
        // Never a path segment: a provider's URL often ends in the account's user name and password.
        if name.isEmpty { name = host(of: url) }
        return ParsedChannel(
            name: name, tvgID: tvgID, tvgName: tvgName, logoURL: logo,
            groupTitle: group ?? extgrp, streamURL: url, extraAttributes: extra)
    }

    /// Host name only: never includes credentials, port or path.
    private static func host(of url: String) -> String {
        guard let r = url.range(of: "://") else { return "" }
        var rest = url[r.upperBound...]
        if let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = rest[rest.startIndex..<end]
        }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if !rest.hasPrefix("["), let colon = rest.lastIndex(of: ":") { rest = rest[rest.startIndex..<colon] }
        return String(rest)
    }
}
