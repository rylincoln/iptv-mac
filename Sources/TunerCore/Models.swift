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

    public init(channels: Int, programmes: Int, skipped: Int) {
        self.channels = channels
        self.programmes = programmes
        self.skipped = skipped
    }
}
