import Foundation

public struct ParsedChannel: Equatable, Sendable {
    public var name: String
    public var tvgID: String?
    public var tvgName: String?
    public var logoURL: String?
    public var groupTitle: String?
    public var streamURL: String
    public var extraAttributes: [String: String]

    public init(
        name: String,
        tvgID: String? = nil,
        tvgName: String? = nil,
        logoURL: String? = nil,
        groupTitle: String? = nil,
        streamURL: String,
        extraAttributes: [String: String] = [:]
    ) {
        self.name = name
        self.tvgID = tvgID
        self.tvgName = tvgName
        self.logoURL = logoURL
        self.groupTitle = groupTitle
        self.streamURL = streamURL
        self.extraAttributes = extraAttributes
    }
}

public struct M3UParseResult: Equatable, Sendable {
    public var channels: [ParsedChannel]
    /// `#EXTINF` with no URL, or a URL line that is not http(s)/file/rtsp/rtp/udp.
    public var skippedCount: Int

    public init(channels: [ParsedChannel], skippedCount: Int) {
        self.channels = channels
        self.skippedCount = skippedCount
    }
}

public struct ParsedGuideChannel: Equatable, Sendable {
    public var id: String
    public var displayNames: [String]
    public var iconURL: String?

    public init(id: String, displayNames: [String], iconURL: String? = nil) {
        self.id = id
        self.displayNames = displayNames
        self.iconURL = iconURL
    }
}

public struct ParsedProgramme: Equatable, Sendable {
    public var channelID: String
    public var start: Date
    public var stop: Date
    public var title: String
    public var subTitle: String?
    public var desc: String?
    public var categories: [String]

    public init(
        channelID: String,
        start: Date,
        stop: Date,
        title: String,
        subTitle: String? = nil,
        desc: String? = nil,
        categories: [String] = []
    ) {
        self.channelID = channelID
        self.start = start
        self.stop = stop
        self.title = title
        self.subTitle = subTitle
        self.desc = desc
        self.categories = categories
    }
}

public struct XMLTVSummary: Equatable, Sendable {
    public var channels: Int
    public var programmes: Int
    /// Channels without an id and programmes that are missing a channel, title or valid times.
    public var skipped: Int
    /// The document parsed to its end. False when the XML broke part way, such as a file cut off
    /// mid-download: what came before the break was still delivered.
    public var complete: Bool

    public init(channels: Int, programmes: Int, skipped: Int, complete: Bool = true) {
        self.channels = channels
        self.programmes = programmes
        self.skipped = skipped
        self.complete = complete
    }
}

public enum SourceKind: String, Sendable { case playlist, guide }

public struct SourceRow: Equatable, Sendable {
    public var id: Int64
    public var kind: SourceKind
    /// File path or URL string.
    public var location: String
    public var etag: String?
    public var lastRefreshAt: Date?
    public var lastError: String?
    public var itemCount: Int
    public var skippedCount: Int
    /// Set when the provider answered "too many requests": it is not asked again before this time.
    public var retryAt: Date? = nil
}

public enum Section: Hashable, Sendable { case recents, favourites, sports, all, group(String) }

public struct ChannelRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var name: String
    public var logoURL: String?
    public var groupTitle: String?
    public var streamURL: String
    public var guideRef: Int64?
    public var isFavourite: Bool
}

public struct ProgrammeRow: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var guideRef: Int64
    public var start: Date
    public var stop: Date
    public var title: String
    public var subTitle: String?
    public var desc: String?
    public var isSport: Bool
}

public struct ProgrammeHit: Identifiable, Equatable, Sendable {
    public var programme: ProgrammeRow
    public var channel: ChannelRow
    public var id: String { "\(programme.id)-\(channel.id)" }
}

public struct SearchResults: Equatable, Sendable {
    /// start <= at < stop, ordered by channel sortIndex.
    public var onNow: [ProgrammeHit]
    /// at < start <= at + 7 days, ordered by start.
    public var later: [ProgrammeHit]
    /// The best match first (`Store.search`).
    public var channels: [ChannelRow]
    /// Set when nothing matched what was typed and `channels` were found for this in its place:
    /// the typed words with a mistyped one mended.
    public var channelsFoundFor: String? = nil

    public static let empty = SearchResults(onNow: [], later: [], channels: [])
}
