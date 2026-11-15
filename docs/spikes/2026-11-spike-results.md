# Spike results — November 2026

Throwaway spikes from plan 1, Part A. No URLs or tokens are recorded here; hosts are described, not quoted.

## Stream format

Probed 2026-11-14 with `curl` (headers) and `ffprobe`, three channels, one connection at a time.

| # | Group | HTTP | Redirect | Final content type | Container | Video | Audio | Resolution | Frame rate |
|---|---|---|---|---|---|---|---|---|---|
| 1 (first entry) | US Sports | 302 → 200 | yes, to a `workers.dev` subdomain over HTTPS | `application/octet-stream` | `mpegts` | h264 | aac | 1280×720 | 59.94 |
| 2 | United States | 302 → 200 | yes, to a bare IPv4 address over **plain HTTP** | `video/mp4` (wrong; the body is MPEG-TS) | `mpegts` | h264 | aac | 1280×720 | 29.97 |
| 3 | US Sports | 302 → 200 | yes, to a bare IPv4 address over **plain HTTP** | `video/mp4` (wrong; the body is MPEG-TS) | `mpegts` | h264 | aac | 1920×1080 | 59.94 |

Findings:

- **All three are raw MPEG-TS over HTTP, not HLS.** There is no playlist/manifest; the response is one endless transport stream.
- Every playlist URL answers `302` to a different edge host. Two of three edges were bare IP addresses on plain HTTP, so the app must allow non-HTTPS loads (the planned `NSAllowsArbitraryLoads`) and must log only the host.
- The `Content-Type` header is unreliable (`application/octet-stream`, `video/mp4`) and cannot be used to detect the format.
- The `Range` request was ignored: the server kept sending until the client hung up. Roughly 5–10 Mbit/s observed (9–18 MB in 15 s).
- Two streams joined mid-GOP: the decoder reported missing PPS until the first keyframe arrived. A short stretch with no picture at tune-in is normal and is not a start failure.
- All three probed URLs happen to end in a numeric path segment; no difference in behaviour was seen between groups.
