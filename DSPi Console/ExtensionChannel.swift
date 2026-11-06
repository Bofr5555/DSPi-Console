//
//  ExtensionChannel.swift
//  DSPi Console
//
//  The firmware's extension channel (bofr fork; Weeb Labs is asked to reserve
//  the opcode): features developed outside Weeb Labs sit behind one vendor
//  request, REQ_EXTENSION 0x00, instead of claiming opcodes upstream may
//  assign later.  wValue selects the sub-command, the transfer direction
//  selects read (IN) or write (OUT).  An unknown sub-command, the wrong
//  direction or a bad length STALLs on USB and answers ERROR on MIDI / UART /
//  I2C; stock firmware STALLs 0x00 entirely, which reads as "no extensions".
//  Spec: Documentation/Features/extension_channel_spec.md in the firmware.
//
//  This file holds the wire formats only (no transport, no UI): the
//  EXT_LIST reply, the crossfeed pair map and CoreVregStatus.
//

import Foundation

// MARK: - Request

let REQ_EXTENSION: UInt8 = 0x00
/// wIndex of every extension request: the vendor interface, as for the other
/// interface-recipient commands.
let EXT_WINDEX: UInt16 = 2

/// Sub-command IDs (wValue).  0x0001-0x7FFF are coordinated with Weeb Labs;
/// 0x8000-0xFFFF are experimental and never shipped.
let EXT_LIST: UInt16               = 0x0000   // IN: supported IDs, uint16 LE ascending
let EXT_CROSSFEED_PAIR_MAP: UInt16 = 0x0001   // IN: uint8[4]   OUT: uint8[4]
let EXT_CORE_VREG: UInt16          = 0x0002   // IN: CoreVregStatus (16 B)   OUT: {op, value}

/// Reply buffer for EXT_LIST: room for 32 IDs.  The reply is truncated to it.
let EXT_LIST_READ_LENGTH: UInt16 = 64

/// The sub-commands a device lists, from its EXT_LIST reply.
struct DeviceExtensions: Equatable {
    let ids: Set<UInt16>

    static let none = DeviceExtensions(ids: [])

    init(ids: Set<UInt16>) { self.ids = ids }

    /// Decode an EXT_LIST reply: uint16 LE IDs.  An odd trailing byte (a
    /// reply cut mid-ID) is ignored, and so is 0 (EXT_LIST itself is never
    /// listed).
    init(listReply data: Data) {
        let bytes = [UInt8](data)
        var ids = Set<UInt16>()
        var i = 0
        while i + 1 < bytes.count {
            let id = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            if id != EXT_LIST { ids.insert(id) }
            i += 2
        }
        self.ids = ids
    }

    func contains(_ id: UInt16) -> Bool { ids.contains(id) }
    var crossfeedPairMap: Bool { contains(EXT_CROSSFEED_PAIR_MAP) }
    var coreVreg: Bool { contains(EXT_CORE_VREG) }
}

/// Where the connected device's extension probe stands.  `unknown` until the
/// first answer after a connect; `unsupported` covers stock firmware (STALL /
/// ERROR), a DSPi Link hub that denies the opcode to this session's role, and
/// a probe that failed twice.
enum ExtensionProbeState: Equatable {
    case unknown
    case unsupported
    case supported(DeviceExtensions)

    var extensions: DeviceExtensions {
        if case .supported(let e) = self { return e }
        return .none
    }
}

// MARK: - Crossfeed pair map (EXT_CROSSFEED_PAIR_MAP)

/// Which two outputs each crossfeed pair processes (firmware crossfeed_map.h).
///
/// Four bytes, byte p for pair p: 0x00 is the default pairing (outputs 2p,
/// 2p+1); any other value is `(right << 4) | left`, 0-based output indices.
/// The filter is symmetric, so "left" and "right" only label the two sides.
/// A map is valid when every pair below the platform's pair count has two
/// distinct stereo outputs (below 2 * pairs: never the PDM sub), no output is
/// in two pairs, and the bytes beyond the platform's pairs are 0.  The
/// firmware stores and reports the map normalized (explicit default bytes
/// become 0) and ignores an invalid one.
///
/// The map also rides in the bulk image, in the crossfeed section's former
/// `reserved2` (bulk offset 44); stock firmware has zero there, the default.
struct CrossfeedPairMap: Equatable, Hashable {
    static let byteCount = 4

    /// Exactly `byteCount` bytes.
    let bytes: [UInt8]

    init(bytes: [UInt8]) {
        var b = Array(bytes.prefix(Self.byteCount))
        b.append(contentsOf: [UInt8](repeating: 0, count: Self.byteCount - b.count))
        self.bytes = b
    }

    init(_ data: Data) { self.init(bytes: [UInt8](data)) }

    /// Every pair on its default outputs (what stock firmware reports).
    static let `default` = CrossfeedPairMap(bytes: [0, 0, 0, 0])

    /// One DAC per ear (the K340 amplifier): out1 = right woofer, out2 = right
    /// tweeter, out3 = left woofer, out4 = left tweeter.  Pair 1 = the woofers
    /// (left out3, right out1), pair 2 = the tweeters (left out4, right out2);
    /// the other pairs stay default.  Valid on RP2040 and RP2350.
    static let oneDACPerEar = CrossfeedPairMap(bytes: [encode(left: 2, right: 0), encode(left: 3, right: 1), 0, 0])

    /// The output-pair mask that goes with `oneDACPerEar`: both pairs.  The
    /// factory mask (pair 1 only) would crossfeed the woofers alone.
    static let oneDACPerEarPairMask: UInt8 = 0x03

    /// The byte for an explicit pair (not normalized).
    static func encode(left: Int, right: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: ((right & 0x0F) << 4) | (left & 0x0F))
    }

    /// Outputs (left, right) of pair `p`, with 0 decoded as the default pair.
    func pair(_ p: Int) -> (left: Int, right: Int) {
        let b = p >= 0 && p < bytes.count ? bytes[p] : 0
        return b == 0 ? (2 * p, 2 * p + 1) : (Int(b & 0x0F), Int(b >> 4))
    }

    /// A map from explicit pairs, pair 0 first; missing pairs stay default.
    /// A pair on its own default outputs is written as 0, as the device
    /// reports it.
    static func from(pairs: [(left: Int, right: Int)]) -> CrossfeedPairMap {
        CrossfeedPairMap(bytes: (0..<byteCount).map { p in
            guard p < pairs.count else { return 0 }
            let pr = pairs[p]
            return pr.left == 2 * p && pr.right == 2 * p + 1 ? 0 : encode(left: pr.left, right: pr.right)
        })
    }

    /// The map for explicit pairs (one per platform pair, pair 0 first) when
    /// the firmware would accept it, else nil.  Checks the pairs themselves as
    /// well as the encoded map: a pair on output 1 twice, (0, 0), encodes as
    /// 0x00, which is the default pair and would pass `isValid`.
    static func validated(pairs: [(left: Int, right: Int)], pairCount: Int) -> CrossfeedPairMap? {
        guard pairs.count == pairCount,
              pairs.allSatisfy({ $0.left != $0.right && (0..<16).contains($0.left) && (0..<16).contains($0.right) })
        else { return nil }
        let map = from(pairs: pairs)
        return map.isValid(pairCount: pairCount) ? map : nil
    }

    /// The firmware's `crossfeed_map_valid`, byte for byte.
    func isValid(pairCount: Int) -> Bool {
        guard pairCount >= 1, pairCount <= Self.byteCount else { return false }
        var used: UInt32 = 0
        for p in 0..<Self.byteCount {
            if p >= pairCount {
                if bytes[p] != 0 { return false }
                continue
            }
            let (l, r) = pair(p)
            if l >= 2 * pairCount || r >= 2 * pairCount || l == r { return false }
            let bits = (UInt32(1) << UInt32(l)) | (UInt32(1) << UInt32(r))
            if used & bits != 0 { return false }
            used |= bits
        }
        return true
    }

    /// Explicit default bytes rewritten as 0 (the firmware's
    /// `crossfeed_map_normalize`; meant for a valid map).
    var normalized: CrossfeedPairMap {
        CrossfeedPairMap(bytes: bytes.enumerated().map { p, b in
            b == Self.encode(left: 2 * p, right: 2 * p + 1) ? 0 : b
        })
    }

    /// What the firmware would load for a received or stored map: the
    /// normalized map when valid, otherwise the default.
    func loaded(pairCount: Int) -> CrossfeedPairMap {
        isValid(pairCount: pairCount) ? normalized : .default
    }

    /// Same pairing, compared after normalization.
    func samePairing(as other: CrossfeedPairMap) -> Bool { normalized == other.normalized }

    var isDefault: Bool { samePairing(as: .default) }

    var data: Data { Data(bytes) }

    // Bulk image (WireBulkParams.crossfeed.pair_map)

    /// The map in a REQ_GET_ALL_PARAMS image, as stored (not validated).
    init(bulk: Data) {
        let start = bulk.startIndex + BULK_CROSSFEED_PAIR_MAP_OFFSET
        self.init(bytes: bulk.count >= BULK_CROSSFEED_PAIR_MAP_OFFSET + Self.byteCount
                  ? [UInt8](bulk[start..<(start + Self.byteCount)]) : [])
    }

    /// Write the map into a bulk image at its offset.
    func encode(into bulk: inout Data) {
        guard bulk.count >= BULK_CROSSFEED_PAIR_MAP_OFFSET + Self.byteCount else { return }
        let start = bulk.startIndex + BULK_CROSSFEED_PAIR_MAP_OFFSET
        bulk.replaceSubrange(start..<(start + Self.byteCount), with: bytes)
    }
}

/// The pair map in WireBulkParams: crossfeed section offset 12, the former
/// `WireCrossfeedParams.reserved2`.  Stock firmware writes zero there.
let BULK_CROSSFEED_PAIR_MAP_OFFSET: Int = BULK_CROSSFEED_OFFSET + 12   // 44

// MARK: - Core voltage (EXT_CORE_VREG)

/// The 16-byte CoreVregStatus (firmware core_vreg.h), little-endian.  Voltage
/// fields are pico-sdk `vreg_voltage` codes, the same on both chips for the
/// range the firmware uses (0x0C = 1.15 V ... 0x0F = 1.30 V).
struct CoreVregStatus: Equatable {
    static let size = 16

    static let flagAutoRaised: UInt8   = 0x01
    static let flagAutoDisabled: UInt8 = 0x02

    /// Voltage programmed now.
    let liveVreg: UInt8
    /// Persisted selection; 0 = the build default.
    let storedSel: UInt8
    /// Build default (DSPI_VREG_MV), also the floor for the stored selection.
    let defaultVreg: UInt8
    let flags: UInt8
    /// Watchdog hangs in this power session not yet acted on.
    let hangCount: UInt8
    let trialActive: Bool
    /// The trial voltage, while `trialActive`.
    let trialVreg: UInt8
    /// 0 = none; else the trial voltage whose run ended in a hang.
    let failedTrialVreg: UInt8
    /// How long that failed trial ran.
    let failedTrialUptimeS: UInt32
    /// Uptime of the current run.
    let uptimeS: UInt32

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= Self.size else { return nil }
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        liveVreg = b[0]
        storedSel = b[1]
        defaultVreg = b[2]
        flags = b[3]
        hangCount = b[4]
        trialActive = b[5] != 0
        trialVreg = b[6]
        failedTrialVreg = b[7]
        failedTrialUptimeS = u32(8)
        uptimeS = u32(12)
    }

    var autoRaised: Bool { flags & Self.flagAutoRaised != 0 }
    var autoRaiseDisabled: Bool { flags & Self.flagAutoDisabled != 0 }
    /// The voltage the device boots at: the stored selection, or the build
    /// default when nothing is stored.
    var storedVreg: UInt8 { storedSel == 0 ? defaultVreg : storedSel }
    var hasFailedTrial: Bool { failedTrialVreg != 0 }
}

/// pico-sdk `enum vreg_voltage` codes to volts.
enum VregVoltage {
    /// RP2350 codes above 1.30 V (0x10-0x1F), which need the POWMAN limit
    /// lifted; the firmware never programs them, but a reply is decoded as is.
    private static let rp2350High: [Double] = [1.35, 1.40, 1.50, 1.60, 1.65, 1.70, 1.80, 1.90,
                                               2.00, 2.35, 2.50, 2.65, 2.80, 3.00, 3.15, 3.30]

    /// Volts for `code` on `platform` ("RP2040" / "RP2350"), or nil for a code
    /// the chip does not have.  Both chips share 0x06 (0.85 V) to 0x0F
    /// (1.30 V) in 50 mV steps; RP2350 adds 0x00-0x05 (0.55-0.80 V) and the
    /// high range; on RP2040 codes 0x00-0x05 all program 0.80 V.
    static func volts(_ code: UInt8, platform: String) -> Double? {
        switch code {
        case 0x00...0x0F:
            if platform == "RP2040" && code < 0x06 { return 0.80 }
            return 0.55 + 0.05 * Double(code)
        case 0x10...0x1F:
            return platform == "RP2040" ? nil : rp2350High[Int(code - 0x10)]
        default:
            return nil
        }
    }

    /// "1.20 V", or the raw code when it does not decode.
    static func label(_ code: UInt8, platform: String) -> String {
        guard let v = volts(code, platform: platform) else { return String(format: "code 0x%02X", code) }
        return String(format: "%.2f V", v)
    }
}

/// "3 h 12 min", "4 min 5 s", "42 s".
func formatUptime(_ seconds: UInt32) -> String {
    let s = Int(seconds)
    let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60, sec = s % 60
    if d > 0 { return "\(d) d \(h) h" }
    if h > 0 { return "\(h) h \(m) min" }
    if m > 0 { return "\(m) min \(sec) s" }
    return "\(sec) s"
}
