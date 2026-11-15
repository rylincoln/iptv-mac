import Foundation

public enum MatchKind: String, Sendable { case id, name, normalizedName }

public enum NameNormalizer {
    private static let suffixes: Set<String> = ["hd", "fhd", "uhd", "sd", "4k"]

    public static func normalize(_ s: String) -> String {
        var text = Substring(s.lowercased())
        text = removingCountryPrefix(text)

        var tokens: [Substring] = []
        text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).forEach { tokens.append($0) }
        if tokens.count > 1, let last = tokens.last, suffixes.contains(String(last)) {
            tokens.removeLast()
        }
        return tokens.joined(separator: " ")
    }

    /// Removes one leading `^\s*(us|usa)?\s*:\s*`.
    private static func removingCountryPrefix(_ text: Substring) -> Substring {
        var i = text.startIndex
        func skipSpaces() { while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) } }
        skipSpaces()
        for word in ["usa", "us"] where text[i...].hasPrefix(word) {
            var j = text.index(i, offsetBy: word.count)
            while j < text.endIndex, text[j].isWhitespace { j = text.index(after: j) }
            if j < text.endIndex, text[j] == ":" { i = j; break }
        }
        skipSpaces()
        guard i < text.endIndex, text[i] == ":" else { return text }
        i = text.index(after: i)
        skipSpaces()
        return text[i...]
    }
}

public struct MatchCandidate: Sendable {
    public var ref: Int64
    public var id: String
    public var displayNames: [String]
    public var hasProgrammes: Bool

    public init(ref: Int64, id: String, displayNames: [String], hasProgrammes: Bool) {
        self.ref = ref
        self.id = id
        self.displayNames = displayNames
        self.hasProgrammes = hasProgrammes
    }
}

public struct MatchQuery: Sendable {
    public var channelID: Int64
    public var tvgID: String?
    public var name: String
    public var tvgName: String?

    public init(channelID: Int64, tvgID: String?, name: String, tvgName: String?) {
        self.channelID = channelID
        self.tvgID = tvgID
        self.name = name
        self.tvgName = tvgName
    }
}

public struct Match: Equatable, Sendable {
    public var guideRef: Int64
    public var kind: MatchKind

    public init(guideRef: Int64, kind: MatchKind) {
        self.guideRef = guideRef
        self.kind = kind
    }
}

public enum Matcher {
    public static func match(_ channels: [MatchQuery], against guide: [MatchCandidate]) -> [Int64: Match] {
        // Indexes map a key to guide positions; built once, so matching is linear.
        var byID: [String: [Int]] = [:]
        var byName: [String: [Int]] = [:]
        var byNormalized: [String: [Int]] = [:]

        func add(_ index: inout [String: [Int]], _ key: String, _ position: Int) {
            guard !key.isEmpty else { return }
            if index[key]?.last != position { index[key, default: []].append(position) }
        }

        for (position, candidate) in guide.enumerated() {
            add(&byID, candidate.id, position)
            add(&byName, candidate.id, position)
            add(&byNormalized, NameNormalizer.normalize(candidate.id), position)
            for name in candidate.displayNames {
                add(&byName, name, position)
                add(&byNormalized, NameNormalizer.normalize(name), position)
            }
        }

        func resolve(_ positions: Set<Int>) -> Int64?? {
            // nil: rule found nothing, try the next rule. .some(nil): ambiguous, stop.
            if positions.isEmpty { return nil }
            if positions.count == 1, let p = positions.first { return .some(guide[p].ref) }
            let withProgrammes = positions.filter { guide[$0].hasProgrammes }
            if withProgrammes.count == 1, let p = withProgrammes.first { return .some(guide[p].ref) }
            return .some(nil)
        }

        var result: [Int64: Match] = [:]
        for channel in channels {
            let names = [channel.name, channel.tvgName].compactMap { $0 }.filter { !$0.isEmpty }

            var rule1: Set<Int> = []
            if let tvgID = channel.tvgID, let hits = byID[tvgID] { rule1.formUnion(hits) }

            var rule2: Set<Int> = []
            for name in names { if let hits = byName[name] { rule2.formUnion(hits) } }

            var rule3: Set<Int> = []
            for name in names {
                let key = NameNormalizer.normalize(name)
                if let hits = byNormalized[key] { rule3.formUnion(hits) }
            }

            for (positions, kind) in [(rule1, MatchKind.id), (rule2, .name), (rule3, .normalizedName)] {
                guard let outcome = resolve(positions) else { continue }
                if let ref = outcome { result[channel.channelID] = Match(guideRef: ref, kind: kind) }
                break
            }
        }
        return result
    }
}
