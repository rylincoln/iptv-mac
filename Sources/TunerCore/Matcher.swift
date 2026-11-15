import Foundation

public enum MatchKind: String, Sendable { case id, name, normalizedName }

public enum NameNormalizer {
    private static let suffixes: Set<String> = ["hd", "fhd", "uhd", "sd", "4k"]

    public static func normalize(_ s: String) -> String {
        var text = Substring(s.lowercased())
        text = removingCountryPrefix(text)

        var tokens = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
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
    /// What one rule found for a channel.
    private enum Outcome {
        /// Nothing: the next rule is tried.
        case noCandidate
        /// Several candidates and no tie-break: no link, and no later rule is tried.
        case ambiguous
        case linked(guideRef: Int64)
    }

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

        func outcome(_ positions: Set<Int>) -> Outcome {
            if positions.isEmpty { return .noCandidate }
            if positions.count == 1, let p = positions.first { return .linked(guideRef: guide[p].ref) }
            let withProgrammes = positions.filter { guide[$0].hasProgrammes }
            if withProgrammes.count == 1, let p = withProgrammes.first { return .linked(guideRef: guide[p].ref) }
            return .ambiguous
        }

        func positions(_ index: [String: [Int]], _ keys: [String]) -> Set<Int> {
            var found: Set<Int> = []
            for key in keys { if let hits = index[key] { found.formUnion(hits) } }
            return found
        }

        var result: [Int64: Match] = [:]
        for channel in channels {
            // A rule's keys are worked out only when every earlier rule found nothing: most channels are
            // decided by id, and normalising is the costly part.
            var kind = MatchKind.id
            var found = Outcome.noCandidate
            if let tvgID = channel.tvgID, let hits = byID[tvgID] { found = outcome(Set(hits)) }
            if case .noCandidate = found {
                let names = [channel.name, channel.tvgName].compactMap { $0 }.filter { !$0.isEmpty }
                kind = .name
                found = outcome(positions(byName, names))
                if case .noCandidate = found {
                    kind = .normalizedName
                    found = outcome(positions(byNormalized, names.map(NameNormalizer.normalize)))
                }
            }
            if case .linked(let ref) = found { result[channel.channelID] = Match(guideRef: ref, kind: kind) }
        }
        return result
    }
}
