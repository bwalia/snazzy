import CryptoKit
import Foundation
import SnazzyCore

/// An interview pack: what a candidate's Snazzy Pro needs to take an interview
/// that OpsAPI runs. It holds the approved kit (the interview deck is made from
/// it) and, optionally, an introduction deck from the recruiter (a Builder
/// project folder, media included).
///
/// The pack is a zip (`manifest.json`, `intro/…`), encrypted on the recruiter's
/// Mac with a random 256-bit key (`PackCrypto`) and uploaded once to S3. OpsAPI
/// keeps the key and gives it, with a short-lived download link, only to a
/// valid invite: the invite link is the credential, there's no passcode.
public enum InterviewPack {
    public static let format = "snazzy-interview-pack"

    public struct Manifest: Codable, Sendable, Equatable {
        public var format: String
        public var version: Int
        public var title: String
        public var kit: RoleKit
        /// The introduction deck's folder inside the pack ("intro"), if any.
        public var intro: String?
        public var createdAt: Date

        public init(title: String, kit: RoleKit, intro: String?, createdAt: Date = Date()) {
            format = InterviewPack.format
            version = 1
            self.title = title
            self.kit = kit
            self.intro = intro
            self.createdAt = createdAt
        }
    }

    /// A built, encrypted pack, ready to upload.
    public struct Sealed: Sendable {
        public var file: URL
        public var key: SymmetricKey
        public var sha256: String
        public var size: Int64
        public var keyBase64: String { key.withUnsafeBytes { Data($0).base64EncodedString() } }
    }

    /// An opened pack: the kit and, if there is one, the introduction deck's folder.
    public struct Opened: Sendable {
        public var manifest: Manifest
        public var introFolder: URL?
    }

    /// The largest pack (zip limit).
    public static let maxBytes: Int64 = 2 << 30

    /// Builds and encrypts a pack in `folder`. The kit must be approved.
    public static func build(kit: RoleKit, intro: URL? = nil, in folder: URL) throws -> Sealed {
        guard kit.isApproved, KitValidator.canApprove(kit) else { throw InterviewFileError("Approve the kit before making a pack.") }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let manifest = Manifest(title: kit.title, kit: kit, intro: intro == nil ? nil : "intro")
        try InterviewJSON.encoder.encode(manifest).write(to: manifestURL)
        var files: [(path: String, url: URL)] = [("manifest.json", manifestURL)]
        if let intro {
            let base = intro.standardizedFileURL.resolvingSymlinksInPath()
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                             options: [.skipsHiddenFiles]) else { throw InterviewFileError("The introduction deck couldn't be read.") }
            for case let url as URL in walker {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let relative = url.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(base.path.count + 1)
                files.append(("intro/" + relative, url))
            }
        }
        let zip = folder.appendingPathComponent("pack.zip")
        try Zip.write(files: files, to: zip)
        let size = try fileSize(zip)
        guard size <= maxBytes else { throw InterviewFileError("The pack is too big (2 GB at most).") }
        let key = SymmetricKey(size: .bits256)
        let sealed = folder.appendingPathComponent("pack.snzpack")
        try PackCrypto.encrypt(zip, to: sealed, key: key)
        try? fm.removeItem(at: zip)
        try? fm.removeItem(at: manifestURL)
        return Sealed(file: sealed, key: key, sha256: try sha256(of: sealed), size: try fileSize(sealed))
    }

    /// Checks, decrypts and unpacks a downloaded pack into `folder`.
    public static func open(_ file: URL, keyBase64: String, sha256 expected: String, into folder: URL) throws -> Opened {
        guard let keyData = Data(base64Encoded: keyBase64), keyData.count == 32 else { throw InterviewFileError("The pack's key isn't valid.") }
        guard try sha256(of: file) == expected.lowercased() else {
            throw InterviewFileError("The interview pack didn't download completely. Please try again.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("pack.zip")
        try PackCrypto.decrypt(file, to: zip, key: SymmetricKey(data: keyData))
        defer { try? fm.removeItem(at: zip) }
        let entries = try Zip.entries(Data(contentsOf: zip, options: .alwaysMapped), limit: Int(maxBytes), maxEntries: 5000)
        guard let m = entries.first(where: { $0.path == "manifest.json" }),
              let manifest = try? InterviewJSON.decoder.decode(Manifest.self, from: m.data), manifest.format == format else {
            throw InterviewFileError("This isn't a Snazzy interview pack.")
        }
        guard manifest.version <= 1 else { throw InterviewFileError("This interview pack needs a newer Snazzy Pro. Please update.") }
        var intro: URL?
        if let name = manifest.intro {
            let dir = folder.appendingPathComponent("intro", isDirectory: true)
            for e in entries where e.path.hasPrefix(name + "/") {
                let target = dir.appendingPathComponent(String(e.path.dropFirst(name.count + 1)))
                guard target.standardizedFileURL.path.hasPrefix(dir.standardizedFileURL.path + "/") else { continue }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try e.data.write(to: target)
            }
            intro = dir
        }
        return Opened(manifest: manifest, introFolder: intro)
    }

    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fileSize(_ url: URL) throws -> Int64 {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Chunked AES-256-GCM, so packs of any size are encrypted and decrypted a
/// megabyte at a time:
///
///     "SNZPACK1" | chunk size (UInt32 LE) | nonce prefix (4 random bytes)
///     then each chunk: ciphertext | 16-byte tag
///
/// Chunk i uses nonce = prefix | i (UInt64 LE), and authenticates
/// "SNZPACK1" | i | last-flag, so chunks can't be reordered, dropped or cut off.
public enum PackCrypto {
    static let magic = Data("SNZPACK1".utf8)
    public static let chunkSize = 1 << 20

    public static func encrypt(_ input: URL, to output: URL, key: SymmetricKey, chunkSize: Int = chunkSize) throws {
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var prefix = Data(count: 4)
        prefix.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 4, $0.baseAddress!) }
        var header = magic
        header.append(contentsOf: withUnsafeBytes(of: UInt32(chunkSize).littleEndian, Array.init))
        header.append(prefix)
        try writer.write(contentsOf: header)
        var index: UInt64 = 0
        var current = try reader.read(upToCount: chunkSize) ?? Data()
        while true {
            let next = current.count == chunkSize ? (try reader.read(upToCount: chunkSize) ?? Data()) : Data()
            let last = next.isEmpty
            let box = try AES.GCM.seal(current, using: key, nonce: nonce(prefix, index), authenticating: aad(index, last: last))
            try writer.write(contentsOf: box.ciphertext + box.tag)
            if last { break }
            current = next
            index += 1
        }
    }

    public static func decrypt(_ input: URL, to output: URL, key: SymmetricKey) throws {
        let damaged = InterviewFileError("The interview pack is damaged or the key doesn't match.")
        let reader = try FileHandle(forReadingFrom: input)
        defer { try? reader.close() }
        guard let header = try reader.read(upToCount: 16), header.count == 16, header.prefix(8) == magic else { throw damaged }
        let size = Int(header.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard size > 0, size <= 64 << 20 else { throw damaged }
        let prefix = header.subdata(in: 12..<16)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var index: UInt64 = 0
        var current = try reader.read(upToCount: size + 16) ?? Data()
        while true {
            guard current.count >= 16 else { throw damaged }
            let next = current.count == size + 16 ? (try reader.read(upToCount: size + 16) ?? Data()) : Data()
            let last = next.isEmpty
            do {
                let box = try AES.GCM.SealedBox(nonce: nonce(prefix, index), ciphertext: current.dropLast(16), tag: current.suffix(16))
                try writer.write(contentsOf: try AES.GCM.open(box, using: key, authenticating: aad(index, last: last)))
            } catch {
                throw damaged
            }
            if last { break }
            current = next
            index += 1
        }
    }

    static func nonce(_ prefix: Data, _ index: UInt64) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: prefix + withUnsafeBytes(of: index.littleEndian, Array.init))
    }

    static func aad(_ index: UInt64, last: Bool) -> Data {
        magic + withUnsafeBytes(of: index.littleEndian, Array.init) + [last ? 1 : 0]
    }
}
