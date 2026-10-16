import Compression
import Foundation

/// A small zip reader and writer (stored and deflate entries, no zip64, no
/// encryption), because the sandboxed app can't run `zip`. Reads what Finder's
/// Compress, `zip` and GitHub's "Download ZIP" make.
public enum Zip {
    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data
        public init(path: String, data: Data) {
            self.path = path
            self.data = data
        }
    }

    public struct Error: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: Writing

    /// A zip of the entries, deflated where that makes them smaller.
    public static func archive(_ entries: [Entry]) throws -> Data {
        var out = Data()
        var central = Data()
        for entry in entries {
            guard isSafePath(entry.path) else { throw Error("“\(entry.path)” can't go in a zip.") }
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let deflated = (try? (entry.data as NSData).compressed(using: .zlib) as Data) ?? entry.data
            let useDeflate = deflated.count < entry.data.count
            let body = useDeflate ? deflated : entry.data
            guard out.count < UInt32.max, body.count < UInt32.max else { throw Error("This is too big for a zip.") }
            let offset = UInt32(out.count)
            // Local header
            out.le32(0x0403_4B50); out.le16(20); out.le16(0x0800) // version, flags: UTF-8 names
            out.le16(useDeflate ? 8 : 0); out.le16(0); out.le16(0x21) // method, time, date (1980-01-01)
            out.le32(crc); out.le32(UInt32(body.count)); out.le32(UInt32(entry.data.count))
            out.le16(UInt16(name.count)); out.le16(0)
            out.append(name); out.append(body)
            // Central directory record
            central.le32(0x0201_4B50); central.le16(0x0314); central.le16(20); central.le16(0x0800)
            central.le16(useDeflate ? 8 : 0); central.le16(0); central.le16(0x21)
            central.le32(crc); central.le32(UInt32(body.count)); central.le32(UInt32(entry.data.count))
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
            central.le32(0o100644 << 16) // regular file, rw-r--r--
            central.le32(offset)
            central.append(name)
        }
        let start = UInt32(out.count)
        out.append(central)
        out.le32(0x0605_4B50); out.le16(0); out.le16(0)
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count)); out.le32(start); out.le16(0)
        return out
    }

    // MARK: Reading

    /// The files in a zip (folders, `__MACOSX` and hidden files left out).
    /// Throws for damaged archives, unsafe paths, or more than `limit` bytes in all.
    public static func entries(_ data: Data, limit: Int = 50 << 20, maxEntries: Int = 500) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let end = endOfCentralDirectory(bytes) else { throw Error("This isn't a zip file, or it's damaged.") }
        let count = Int(bytes.u16(end + 10))
        var p = Int(bytes.u32(end + 16))
        guard count <= maxEntries else { throw Error("This zip has too many files.") }
        guard bytes.u32(end + 16) != 0xFFFF_FFFF else { throw Error("Large (zip64) archives aren't supported.") }
        var out: [Entry] = []
        var total = 0
        for _ in 0..<count {
            guard p + 46 <= bytes.count, bytes.u32(p) == 0x0201_4B50 else { throw Error("This zip file is damaged.") }
            let flags = bytes.u16(p + 8)
            let method = bytes.u16(p + 10)
            let crc = bytes.u32(p + 16)
            let compressed = Int(bytes.u32(p + 20))
            let size = Int(bytes.u32(p + 24))
            let nameLength = Int(bytes.u16(p + 28))
            let extra = Int(bytes.u16(p + 30)) + Int(bytes.u16(p + 32))
            let local = Int(bytes.u32(p + 42))
            guard p + 46 + nameLength <= bytes.count else { throw Error("This zip file is damaged.") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            p += 46 + nameLength + extra
            if name.hasSuffix("/") { continue }
            let parts = name.split(separator: "/")
            if parts.contains(where: { $0 == "__MACOSX" || $0.hasPrefix(".") }) { continue }
            guard isSafePath(name) else { throw Error("This zip has a file with an unsafe name (\(name)).") }
            guard flags & 1 == 0 else { throw Error("Encrypted zip files aren't supported.") }
            total += size
            guard total <= limit else { throw Error("This zip is too big to open.") }
            guard local + 30 <= bytes.count, bytes.u32(local) == 0x0403_4B50 else { throw Error("This zip file is damaged.") }
            let start = local + 30 + Int(bytes.u16(local + 26)) + Int(bytes.u16(local + 28))
            guard start + compressed <= bytes.count else { throw Error("This zip file is damaged.") }
            let body = Data(bytes[start..<(start + compressed)])
            let file: Data
            switch method {
            case 0: file = body
            case 8: file = try inflate(body, limit: size)
            default: throw Error("This zip uses a compression method that isn't supported.")
            }
            guard file.count == size, crc32(file) == crc else { throw Error("This zip file is damaged (\(name)).") }
            out.append(Entry(path: name, data: file))
        }
        return out
    }

    /// Relative, no `..`, no backslashes or control characters.
    public static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.count < 512, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
        guard !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func endOfCentralDirectory(_ b: [UInt8]) -> Int? {
        guard b.count >= 22 else { return nil }
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 65_535)
        while i >= stop {
            if b.u32(i) == 0x0605_4B50 { return i }
            i -= 1
        }
        return nil
    }

    private static func inflate(_ data: Data, limit: Int) throws -> Data {
        var output = Data()
        var input = data[...]
        let filter = try InputFilter(.decompress, using: .zlib) { (length: Int) -> Data? in
            let chunk = input.prefix(length)
            input = input.dropFirst(chunk.count)
            return chunk.isEmpty ? nil : Data(chunk)
        }
        do {
            while let page = try filter.readData(ofLength: 1 << 16), !page.isEmpty {
                output.append(page)
                guard output.count <= limit else { throw Error("This zip file is damaged.") }
            }
        } catch let e as Error {
            throw e
        } catch {
            throw Error("This zip file is damaged.")
        }
        return output
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = table[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { le16(UInt16(v & 0xFFFF)); le16(UInt16(v >> 16)) }
}

private extension [UInt8] {
    func u16(_ i: Int) -> UInt16 { UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }
}
