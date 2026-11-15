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
