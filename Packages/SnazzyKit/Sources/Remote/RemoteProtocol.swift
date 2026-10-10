import Foundation

/// The remote-control protocol between Snazzy Pro on the Mac (host) and the
/// iPhone/iPad app (client): length-prefixed JSON messages over TLS with
/// pre-shared keys (see `RemoteSecurity`).
public enum RemoteProtocol {
    /// 2: `hello` carries a proof of the key behind its claim.
    public static let version = 2
    /// Bonjour service type (also listed in each app's NSBonjourServices).
    public static let serviceType = "_snazzyremote._tcp"
    public static let maxFrame = 1_000_000
}

/// What the Mac is doing, sent to devices whenever it changes.
public struct RemoteStatus: Codable, Sendable, Equatable {
    public var hostName: String
    /// idle, countdown, recording, paused, finishing or failed
    public var recording: String
    public var countdown: Int?
    public var elapsed: Double
    public var micLevel: Double
    /// What's being recorded, e.g. "Slides" or "Display: LG".
    public var source: String
    public var deckName: String?
    public var slideIndex: Int?
    public var slideCount: Int
    public var slideTitle: String?
    public var nextSlideTitle: String?
    /// Speaker notes for the current slide (the teleprompter).
    public var notes: String?
    public var liveRoomViewers: Int?
    public var broadcast: String?
    public var warnings: [String]
    /// The auto-scrolling teleprompter (nil from Macs that don't have one).
    public var prompter: PrompterState?

    public init(hostName: String = "", recording: String = "idle", countdown: Int? = nil, elapsed: Double = 0, micLevel: Double = 0,
                source: String = "", deckName: String? = nil, slideIndex: Int? = nil, slideCount: Int = 0, slideTitle: String? = nil,
                nextSlideTitle: String? = nil, notes: String? = nil, liveRoomViewers: Int? = nil, broadcast: String? = nil, warnings: [String] = [],
                prompter: PrompterState? = nil) {
        self.hostName = hostName
        self.recording = recording
        self.countdown = countdown
        self.elapsed = elapsed
        self.micLevel = micLevel
        self.source = source
        self.deckName = deckName
        self.slideIndex = slideIndex
        self.slideCount = slideCount
        self.slideTitle = slideTitle
        self.nextSlideTitle = nextSlideTitle
        self.notes = notes
        self.liveRoomViewers = liveRoomViewers
        self.broadcast = broadcast
        self.warnings = warnings
        self.prompter = prompter
    }

    public var isRecording: Bool { recording == "recording" || recording == "paused" || recording == "countdown" }
}

/// What a device can ask the Mac to do.
public enum RemoteCommand: Codable, Sendable, Equatable {
    case startRecording
    case pauseRecording
    case resumeRecording
    case stopRecording
    case nextSlide
    case previousSlide
    case goToSlide(Int)
    case openPresentWindow
    /// A message to the assistant, as if typed in the Mac's chat.
    case chat(String)
    case prompter(PrompterAction)
    /// Checks the link is alive (answers ok, does nothing).
    case ping
}

public enum PrompterAction: Codable, Sendable, Equatable {
    case play
    case pause
    case toggle
    case faster
    case slower
    /// Back to the top of the current slide's notes.
    case restart
    /// Jumps to a position, 0…1.
    case seek(Double)
}

/// The Mac's camera prompter (the teleprompter): it scrolls the current
/// slide's notes, or a script, at a reading speed. Devices show the same
/// position (a fraction of the text, so it lines up whatever the font size)
/// and keep it moving between status updates.
public struct PrompterState: Codable, Sendable, Equatable {
    public var running: Bool
    /// Reading speed in words per minute.
    public var wordsPerMinute: Double
    /// How far through the text, 0…1, when the status was made.
    public var progress: Double
    /// The script, when it shows one instead of the slide's notes.
    public var script: String?
    /// The prompter is open on the Mac.
    public var visible: Bool

    /// The same as the Mac's prompter settings.
    public static let speeds: ClosedRange<Double> = 60...260
    public static let step = 20.0

    public init(running: Bool = false, wordsPerMinute: Double = 140, progress: Double = 0, script: String? = nil, visible: Bool = true) {
        self.running = running
        self.wordsPerMinute = wordsPerMinute
        self.progress = progress
        self.script = script
        self.visible = visible
    }

    public static func words(in text: String?) -> Int {
        (text ?? "").split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The position `seconds` later, for notes of `words` words.
    public func progress(after seconds: Double, words: Int) -> Double {
        guard running, words > 0, seconds > 0 else { return progress }
        return min(1, progress + seconds * wordsPerMinute / 60 / Double(words))
    }
}

public enum RemoteMessage: Codable, Sendable, Equatable {
    /// Device → Mac, first message on every connection. `proof` is
    /// `RemoteSecurity.proof` with the pairing secret (pairing) or the device's
    /// own key; optional only so an older app still decodes and is told to update.
    case hello(deviceID: String, deviceName: String, version: Int, pairing: Bool, proof: Data?)
    /// Mac → device after pairing: the device's own key for future connections.
    case paired(hostID: String, hostName: String, deviceKey: Data)
    /// Mac → device on a normal connection.
    case welcome(hostID: String, hostName: String)
    case status(RemoteStatus)
    case command(id: Int, RemoteCommand)
    case result(id: Int, ok: Bool, message: String?)
    /// The assistant's reply to a `.chat` command (final text).
    case chatReply(String)
    /// Closing, with a reason (e.g. "This device was removed on the Mac.").
    case bye(String)
}

/// Length-prefixed (4-byte big-endian) JSON frames.
public enum RemoteFrame {
    public static func encode(_ message: RemoteMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        var length = UInt32(json.count).bigEndian
        return Data(bytes: &length, count: 4) + json
    }

    /// Accumulates bytes and returns complete messages.
    public struct Reader: Sendable {
        private var buffer = Data()
        public init() {}

        public mutating func append(_ data: Data) throws -> [RemoteMessage] {
            buffer.append(data)
            var out: [RemoteMessage] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length <= RemoteProtocol.maxFrame else { throw RemoteError("Message too large.") }
                guard buffer.count >= 4 + length else { break }
                let body = buffer.dropFirst(4).prefix(length)
                // A message from a newer version that this one doesn't know is
                // skipped (its sender times out) rather than closing the link.
                if let message = try? JSONDecoder().decode(RemoteMessage.self, from: Data(body)) { out.append(message) }
                buffer = Data(buffer.dropFirst(4 + length))
            }
            return out
        }
    }
}

public struct RemoteError: LocalizedError, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
