import Foundation
import Testing
@testable import SnazzyCore

@Suite struct ZipTests {
    let entries = [
        Zip.Entry(path: "cdn-engineer/prep-kit.json", data: Data(String(repeating: "{\"role\":\"CDN Engineer\"}", count: 50).utf8)),
        Zip.Entry(path: "README.txt", data: Data("hi".utf8)),
    ]

    @Test func roundTrips() throws {
        let zip = try Zip.archive(entries)
        #expect(Zip.isZip(zip))
        #expect(try Zip.entries(zip) == entries)
    }

    /// The system's unzip reads what we write, and we read what zip writes.
    @Test func matchesTheZipTool() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ziptest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("in/cdn-engineer"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ours = dir.appendingPathComponent("ours.zip")
        try Zip.archive(entries).write(to: ours)
        #expect(run("/usr/bin/unzip", ["-tq", ours.path]) == 0)

        for e in entries { try e.data.write(to: dir.appendingPathComponent("in/\(e.path)")) }
        let theirs = dir.appendingPathComponent("theirs.zip")
        #expect(run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", dir.appendingPathComponent("in").path, theirs.path]) == 0)
        let read = try Zip.entries(Data(contentsOf: theirs))
        #expect(Set(read.map(\.path)) == Set(entries.map(\.path)))
        #expect(read.first { $0.path == "cdn-engineer/prep-kit.json" }?.data == entries[0].data)
    }

    @Test func refusesUnsafeAndDamaged() throws {
        #expect(throws: Zip.Error.self) { try Zip.archive([Zip.Entry(path: "../evil", data: Data())]) }
        var zip = try Zip.archive(entries)
        zip[70] ^= 0xFF  // inside the first file's compressed data
        #expect(throws: Zip.Error.self) { try Zip.entries(zip) }
        #expect(throws: Zip.Error.self) { try Zip.entries(Data("not a zip".utf8)) }
        #expect(throws: Zip.Error.self) { try Zip.entries(try Zip.archive(entries), limit: 10) }
    }

    @Test func crc32() {
        #expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }

    private func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
