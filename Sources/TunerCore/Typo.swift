/// Mends a mistyped word from the words that exist: "espm" is taken for "espn".
public enum Typo {
    /// Each of `terms` that begins no word of `vocabulary` replaced by the nearest word in it; nil
    /// if no term needed mending or one could not be mended. A term of fewer than three characters,
    /// or all digits, is left alone. Near means one edit (a character wrong, missing, extra, or two
    /// swapped) for a term of up to five characters, two for a longer one. Among equally near
    /// words the one in the most names wins. `vocabulary`: lowercase words with how many names
    /// hold each.
    public static func mended(_ terms: [String], vocabulary: [(word: String, count: Int)]) -> [String]? {
        var changed = false
        var result: [String] = []
        for term in terms {
            let typed = Array(term.lowercased())
            if typed.count < 3 || typed.allSatisfy(\.isNumber) || vocabulary.contains(where: { $0.word.hasPrefix(term.lowercased()) }) {
                result.append(term)
                continue
            }
            let allowed = typed.count <= 5 ? 1 : 2
            var best: (word: String, distance: Int, count: Int)?
            for entry in vocabulary {
                let word = Array(entry.word)
                guard abs(word.count - typed.count) <= allowed else { continue }
                let distance = edits(typed, word, atMost: allowed)
                guard distance <= allowed else { continue }
                if let current = best,
                   (current.distance, -current.count, current.word) <= (distance, -entry.count, entry.word) {
                    continue
                }
                best = (entry.word, distance, entry.count)
            }
            guard let best else { return nil }
            result.append(best.word)
            changed = true
        }
        return changed ? result : nil
    }

    /// The edits between two words (Damerau-Levenshtein, adjacent swaps counted as one), or more
    /// than `limit` once it is certain to exceed it.
    static func edits(_ a: [Character], _ b: [Character], atMost limit: Int) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var twoBack = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var least = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = min(value, twoBack[j - 2] + 1)
                }
                current[j] = value
                least = min(least, value)
            }
            if least > limit { return limit + 1 }
            (twoBack, previous, current) = (previous, current, twoBack)
        }
        return previous[b.count]
    }
}
