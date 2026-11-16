/// How channel names are read for searching. Playlist names are untidy in regular ways: letters
/// run into digits ("ESPN2"), a region is put in front ("US: NBC"), a picture quality behind
/// ("NBC FHD").
public enum ChannelName {
    /// The runs of letters and digits in `text`.
    public static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// `word` divided where letters meet digits: "ESPN2" is "ESPN" and "2". Names and what is
    /// typed are both divided so, and "espn 2" and "espn2" each find "ESPN2" and "ESPN 2".
    public static func parts(of word: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var digits = false
        for character in word {
            let isDigit = character.isNumber
            if !current.isEmpty, isDigit != digits {
                parts.append(current)
                current = ""
            }
            current.append(character)
            digits = isDigit
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// `text` with every word divided as `parts(of:)` does, for the search index.
    public static func divided(_ text: String) -> String {
        words(in: text).flatMap(parts).joined(separator: " ")
    }

    /// Words that say how good the picture is, not which channel it is.
    private static let qualityWords: Set<String> = [
        "hd", "fhd", "uhd", "sd", "hq", "4k", "8k", "hevc", "h265", "h264", "1080p", "1080", "720p", "720",
    ]

    /// How long the name is without a region in front or picture quality behind: what search ranks
    /// "the shorter name" by, so "USA  NBC 4 NY FHD" is no further from "nbc" than "NBC 4 NY" is.
    /// A region is two or three letters at the very start, followed by a colon, bar or dash, or by
    /// two spaces. Never 0 for a name with any letter or digit in it.
    public static func coreLength(_ name: String) -> Int {
        var words = words(in: name).map { $0.lowercased() }
        if words.count > 1, hasRegion(name) { words.removeFirst() }
        let core = words.filter { !qualityWords.contains($0) }
        let kept = core.isEmpty ? words : core
        return kept.reduce(0) { $0 + $1.count } + max(kept.count - 1, 0)
    }

    private static func hasRegion(_ name: String) -> Bool {
        var letters = 0
        var spaces = 0
        for character in name.drop(while: { $0 == " " }) {
            if spaces == 0, character.isLetter {
                letters += 1
                if letters > 3 { return false }
            } else if character == " " {
                spaces += 1
                if spaces == 2 { return letters >= 2 }
            } else {
                return letters >= 2 && (character == ":" || character == "|" || character == "-")
            }
        }
        return false
    }
}
