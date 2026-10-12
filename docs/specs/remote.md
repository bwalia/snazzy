# Remote protocol

The Mac (host) and the iPhone/iPad app (client) talk over TLS 1.2 with
length-prefixed JSON messages. The Watch talks only to the iPhone, which relays.
The Windows/Linux host must work with the **shipping** iPhone, iPad and Watch apps.

Source of truth: `Packages/SnazzyKit/Sources/Remote/RemoteProtocol.swift`,
`RemoteSecurity.swift`, `RemoteHost.swift`, `WatchLink.swift`.
Fixtures: `remote-cases.json`, `remote-frames.bin`, `remote-status.json`.
Rust: `desktop/crates/snazzy-remote`.

## Constants

| | |
|---|---|
| `RemoteProtocol.version` | `2` (2: `hello` carries a proof) |
| Bonjour service | `_snazzyremote._tcp` |
| Largest frame body | 1,000,000 bytes |
| TLS | 1.2 only, PSK, `TLS_PSK_WITH_AES_128_GCM_SHA256` only |
| PSK identities | `pair:<hostID>` (one-time pairing secret), `dev:<deviceID>` (a paired device's key) |
| Keys | 32 random bytes |

## Frames

A 4-byte big-endian length, then that many bytes of UTF-8 JSON, one `RemoteMessage`.

- A length over 1,000,000 is an error: close the link.
- A frame that doesn't decode (a message from a newer version) is **skipped**,
  not fatal. Its sender times out.
- Readers must accept any key order and ignore unknown object keys.

## Messages

Synthesized Swift `Codable` (see README: one key per case, `_0`/`_1` for
unlabelled values, absent optionals left out, `Data` as base64):

| Case | JSON |
|---|---|
| `hello` (device → host, first) | `{"hello":{"deviceID":…,"deviceName":…,"version":2,"pairing":true,"proof":"<base64>"}}`; `proof` missing only from old apps |
| `paired` (host → device after pairing) | `{"paired":{"hostID":…,"hostName":…,"deviceKey":"<base64, 32 bytes>"}}` |
| `welcome` (host → device) | `{"welcome":{"hostID":…,"hostName":…}}` |
| `status` | `{"status":{"_0":<RemoteStatus>}}` |
| `command` | `{"command":{"id":7,"_1":<RemoteCommand>}}` |
| `result` | `{"result":{"id":7,"ok":true,"message":…}}` (`message` optional) |
| `chatReply` | `{"chatReply":{"_0":"…"}}` |
| `bye` | `{"bye":{"_0":"reason"}}` |

`RemoteCommand`: `startRecording`, `pauseRecording`, `resumeRecording`,
`stopRecording`, `nextSlide`, `previousSlide`, `openPresentWindow`, `ping` (all
`{"name":{}}`), `goToSlide` (`{"goToSlide":{"_0":3}}`, 0-based), `chat`
(`{"chat":{"_0":"text"}}`), `prompter` (`{"prompter":{"_0":<PrompterAction>}}`).

`PrompterAction`: `play`, `pause`, `toggle`, `faster`, `slower`, `restart`
(`{}`), `seek` (`{"seek":{"_0":0.5}}`, 0…1).

`RemoteStatus` (all of `remote-status.json`): required `hostName`, `recording`
(`idle`, `countdown`, `recording`, `paused`, `finishing`, `failed`), `elapsed`,
`micLevel`, `source`, `slideCount`, `warnings`; optional `countdown`, `deckName`,
`slideIndex`, `slideTitle`, `nextSlideTitle`, `notes`, `liveRoomViewers`,
`broadcast`, `prompter` (`running`, `wordsPerMinute` 60…260, `progress` 0…1,
`script` optional, `visible`). **New fields must be optional**, and a new
`RemoteCommand` case needs a version bump (older peers skip what they can't decode).

## Session

1. The client connects with TLS-PSK (identity `pair:<hostID>` and the QR secret
   when pairing, else `dev:<deviceID>` and its own key) and sends `hello`.
2. A `version` other than 2: close with "Update Snazzy Pro on this device and the
   Mac to the same version."
3. `proof` = HMAC-SHA256(key, UTF-8 deviceID). The host verifies it (constant
   time) against the pairing secret (pairing) or **that device ID's own key**;
   the TLS handshake alone only proves *some* accepted key.
   - Pairing, wrong/missing proof or window closed (3 minutes, one device per QR
     code): close with "This pairing code has expired or was already used. Show a
     new one on the Mac." Otherwise answer `paired` with a new 32-byte device key
     (both sides keep it) and stop accepting the pairing secret.
   - Reconnecting, unknown device or wrong/missing proof: close with "This device
     isn't paired with this Mac. Pair again." Otherwise answer `welcome`.
   - Device names are cut to 60 characters.
4. Then the host sends the latest `status` at once, and again whenever it changes
   (it polls every 250 ms). Each `command` gets one `result` with the same `id`; a
   `command` before `hello`: close with "Say hello first.". Closing sends `bye` with
   the reason.

## Pairing link (QR code)

`snazzypro://pair?v=2&h=<hostID>&n=<host name>&s=<secret>[&a=<addresses>]`

- Values are percent-encoded as `URLComponents` does: letters, digits and
  `-._~!$'()*+,;:@/?` stay; everything else (space, `&`, `=`, `#`, `%`, `[`, `]`,
  non-ASCII as UTF-8) is `%XX`. `+` is a plus, not a space.
- `s`: the 32-byte secret, base64 URL-safe (`-`, `_`) without padding. Readers
  accept the standard alphabet and padding too; anything not exactly 32 bytes is refused.
- `a`: optional `ip:port,ip:port` for when Bonjour can't find the host (VPNs).
- Reading: scheme exactly `snazzypro`, host exactly `pair` (a trailing `/` is
  fine), `h` non-empty; the first item of a name wins; `n` defaults to `Mac`.

## Watch

The watch may send every command except `chat` and `openPresentWindow`
(`WatchLink.allows`; `watchAllows` in the fixture).

## Not byte-identical

Swift's `JSONEncoder` without `.sortedKeys` writes keys in no fixed order, so the
Mac's own frames vary from run to run. The fixtures and the Rust encoder use
sorted keys; the lengths and the decoded messages are identical.
