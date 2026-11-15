import Foundation
import zlib

/// Streaming gzip decompression, file to file, in fixed-size chunks.
enum Gunzip {
    enum Failure: Error, Equatable {
        /// Not gzip, cut short, damaged, or followed by bytes that are not another gzip member.
        case corrupt
        /// Inflates to more than the limit.
        case tooLarge
        /// The compressed file could not be read.
        case cannotRead
        /// The decompressed file could not be created or written: the disk is full, say.
        case cannotWrite
    }

    /// Real guides inflate to tens, at most a few hundred, megabytes (the owner's is 23 MB). A gigabyte
    /// leaves room for any of them, and stops a damaged or hostile file from filling the disk: deflate
    /// can expand a single megabyte to about a gigabyte.
    static let defaultLimit: Int64 = 1 << 30

    /// Writes at most `limit` bytes to `destination`, and stops with `.tooLarge` rather than write more.
    /// On any failure `destination` may hold part of the output; the caller deletes it.
    static func inflate(from source: URL, to destination: URL, limit: Int64 = defaultLimit) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination)
        else { throw Failure.cannotWrite }
        defer { try? output.close() }
        guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.cannotRead }
        defer { try? input.close() }

        var stream = z_stream()
        // 16 + MAX_WBITS selects the gzip wrapper.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw Failure.corrupt }
        defer { inflateEnd(&stream) }

        let chunk = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunk)
        var sawEnd = false
        var sawData = false
        var written: Int64 = 0

        // Foundation hands back autoreleased Data; drain each chunk or the whole file piles up.
        var more = true
        while more {
            try autoreleasepool {
                let data: Data?
                do { data = try input.read(upToCount: chunk) } catch { throw Failure.cannotRead }
                guard let data, !data.isEmpty else { more = false; return }
                sawData = true
                var bytes = [UInt8](data)
                try bytes.withUnsafeMutableBufferPointer { inBuf in
                    stream.next_in = inBuf.baseAddress
                    stream.avail_in = UInt32(inBuf.count)
                    while stream.avail_in > 0 {
                        var status: Int32 = Z_OK
                        try outBuffer.withUnsafeMutableBufferPointer { outBuf in
                            stream.next_out = outBuf.baseAddress
                            stream.avail_out = UInt32(chunk)
                            status = zlib.inflate(&stream, Z_NO_FLUSH)
                            guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                                throw Failure.corrupt
                            }
                            let produced = chunk - Int(stream.avail_out)
                            guard produced > 0, let start = outBuf.baseAddress else { return }
                            written += Int64(produced)
                            guard written <= limit else { throw Failure.tooLarge }
                            do {
                                try output.write(contentsOf: Data(bytes: start, count: produced))
                            } catch {
                                throw Failure.cannotWrite
                            }
                        }
                        if status == Z_STREAM_END {
                            // Bytes after a member must start another member: they are inflated as one,
                            // and anything else (garbage, zero padding) fails the file as corrupt.
                            sawEnd = true
                            if stream.avail_in > 0, inflateReset(&stream) != Z_OK { throw Failure.corrupt }
                            if stream.avail_in > 0 { sawEnd = false }
                        } else if status == Z_BUF_ERROR && stream.avail_in > 0 && stream.avail_out > 0 {
                            throw Failure.corrupt
                        }
                    }
                }
            }
        }
        guard sawData, sawEnd else { throw Failure.corrupt }
    }
}
