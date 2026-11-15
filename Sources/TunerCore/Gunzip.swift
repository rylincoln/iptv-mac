import Foundation
import zlib

/// Streaming gzip decompression, file to file, in fixed-size chunks.
enum Gunzip {
    struct Failure: Error {}

    static func inflate(from source: URL, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let input = try? FileHandle(forReadingFrom: source),
              let output = try? FileHandle(forWritingTo: destination)
        else { throw Failure() }
        defer { try? input.close(); try? output.close() }

        var stream = z_stream()
        // 16 + MAX_WBITS selects the gzip wrapper.
        guard inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
        else { throw Failure() }
        defer { inflateEnd(&stream) }

        let chunk = 64 * 1024
        var outBuffer = [UInt8](repeating: 0, count: chunk)
        var sawEnd = false
        var sawData = false

        while let data = try input.read(upToCount: chunk), !data.isEmpty {
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
                            throw Failure()
                        }
                        let produced = chunk - Int(stream.avail_out)
                        if produced > 0 { try output.write(contentsOf: Data(bytes: outBuf.baseAddress!, count: produced)) }
                    }
                    if status == Z_STREAM_END {
                        // Another gzip member may follow; trailing garbage is ignored.
                        sawEnd = true
                        if stream.avail_in > 0, inflateReset(&stream) != Z_OK { throw Failure() }
                        if stream.avail_in > 0 { sawEnd = false }
                    } else if status == Z_BUF_ERROR && stream.avail_in > 0 && stream.avail_out > 0 {
                        throw Failure()
                    }
                }
            }
        }
        guard sawData, sawEnd else { throw Failure() }
    }
}
