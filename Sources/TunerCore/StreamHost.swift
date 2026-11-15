/// The host of a stream address, for showing. Addresses carry account credentials, so nothing else of
/// one is ever returned, and anything that is not plainly a host gives nil rather than a guess.
public enum StreamHost {
    /// The host, lower case: letters, digits, dots and hyphens, or a bracketed IPv6 literal. Nil when
    /// there is none, or when what stands there might not be the host. An "@" after the authority
    /// means the credentials hold an unencoded "/", "?" or "#", so what looks like the host is part of
    /// them. A percent-encoded or otherwise unusual host, or a port that is not digits, is not decoded
    /// or guessed at.
    public static func name(of streamURL: String) -> String? {
        guard let separator = streamURL.range(of: "://") else { return nil }
        let scheme = streamURL[..<separator.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        let rest = streamURL[separator.upperBound...]
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        guard !rest[authorityEnd...].contains("@") else { return nil }
        var hostAndPort = rest[..<authorityEnd]
        if let at = hostAndPort.lastIndex(of: "@") { hostAndPort = hostAndPort[hostAndPort.index(after: at)...] }

        let host: Substring
        let port: Substring
        if hostAndPort.hasPrefix("[") {
            guard let close = hostAndPort.firstIndex(of: "]") else { return nil }
            host = hostAndPort[...close]
            port = hostAndPort[hostAndPort.index(after: close)...]
            let literal = host.dropFirst().dropLast()
            guard literal.contains(":"),
                  literal.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == ":" || $0 == ".") })
            else { return nil }
        } else {
            let colon = hostAndPort.firstIndex(of: ":") ?? hostAndPort.endIndex
            host = hostAndPort[..<colon]
            port = hostAndPort[colon...]
            guard host.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { return nil }
        }
        guard !host.isEmpty,
              port.isEmpty || (port.first == ":" && port.dropFirst().allSatisfy { $0.isASCII && $0.isNumber })
        else { return nil }
        return host.lowercased()
    }
}
