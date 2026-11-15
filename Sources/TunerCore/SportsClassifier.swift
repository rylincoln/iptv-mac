import Foundation

public enum SportsClassifier {
    /// Also matches "Sports" and "Motorsport".
    private static let sport = "sport"

    private static let keywords = [
        sport, "football", "fußball", "soccer", "baseball", "basketball", "hockey", "golf",
        "tennis", "rugby", "cricket", "boxing", "wrestling", "racing", "motorsport",
    ]

    public static func isSportsGroup(_ groupTitle: String?) -> Bool {
        guard let groupTitle else { return false }
        return groupTitle.lowercased().contains(sport)
    }

    public static func isSportsCategory(_ categories: [String]) -> Bool {
        categories.contains { category in
            let lowered = category.lowercased()
            return keywords.contains { lowered.contains($0) }
        }
    }
}
