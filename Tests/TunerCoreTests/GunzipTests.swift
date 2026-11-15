import Foundation
import Testing
import zlib
@testable import TunerCore

/// Test-side gzip, shared by the import tests.
enum TestGzip {
    /// One gzip member holding `data`.
    static func compress(_ data: Data) -> Data {
        var stream = z_stream()
        deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY,
                      ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var input = [UInt8](data)
        var output = [UInt8](repeating: 0, count: Int(deflateBound(&stream, UInt(input.count))) + 64)
        var written = 0
        input.withUnsafeMutableBufferPointer { inBuf in
            output.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = inBuf.baseAddress
                stream.avail_in = UInt32(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = UInt32(outBuf.count)
                deflate(&stream, Z_FINISH)
                written = outBuf.count - Int(stream.avail_out)
            }
        }
        return Data(output[0..<written])
    }
}

/// Bytes that barely compress, so the gzip file spans several of the inflater's 64 KB reads.
private func noise(_ count: Int) -> Data {
    var state: UInt64 = 42
    return Data((0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return UInt8(truncatingIfNeeded: state >> 33)
    })
}

private let text = Data(String(repeating: "<programme>Evening News</programme>\n", count: 2_000).utf8)

/// Inflates `compressed` from a file of its own into a fresh folder; returns the output or throws.
private func inflate(_ compressed: Data, limit: Int64 = Gunzip.defaultLimit) throws -> Data {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("gunzip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("in.gz")
    let destination = folder.appendingPathComponent("out.xml")
    try compressed.write(to: source)
    try Gunzip.inflate(from: source, to: destination, limit: limit)
    return try Data(contentsOf: destination)
}

@Suite struct GunzipTests {
    @Test func inflatesAFile() throws {
        #expect(try inflate(TestGzip.compress(text)) == text)
    }

    @Test func inflatesAFileLongerThanOneRead() throws {
        let data = noise(300_000)
        let compressed = TestGzip.compress(data)
        #expect(compressed.count > 2 * 64 * 1024)
        #expect(try inflate(compressed) == data)
    }

    @Test func inflatesConcatenatedMembers() throws {
        let second = Data("<programme>Late News</programme>\n".utf8)
        #expect(try inflate(TestGzip.compress(text) + TestGzip.compress(second)) == text + second)
        let big = noise(200_000)
        #expect(try inflate(TestGzip.compress(big) + TestGzip.compress(text)) == big + text)
    }

    @Test func truncatedInputFails() {
        let compressed = TestGzip.compress(text)
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(compressed.prefix(compressed.count / 2)) }
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(compressed.dropLast(4)) }  // trailer cut off
    }

    @Test func emptyInputFails() {
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(Data()) }
    }

    /// Anything after a member must be another member: bytes that are not fail the whole file.
    @Test func trailingGarbageFails() {
        let compressed = TestGzip.compress(text)
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(compressed + Data("not gzip".utf8)) }
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(compressed + Data(repeating: 0, count: 16)) }
    }

    @Test func stopsAtTheLimit() throws {
        let compressed = TestGzip.compress(text)
        #expect(throws: Gunzip.Failure.tooLarge) { try inflate(compressed, limit: Int64(text.count) - 1) }
        #expect(try inflate(compressed, limit: Int64(text.count)) == text)
    }

    @Test func notGzipFails() {
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(text) }
        #expect(throws: Gunzip.Failure.corrupt) { try inflate(Data([0x1F, 0x8B]) + Data(repeating: 0x42, count: 64)) }
    }
}
