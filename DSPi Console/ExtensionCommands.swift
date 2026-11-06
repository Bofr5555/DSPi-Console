//
//  ExtensionCommands.swift
//  DSPi Console
//
//  The view model's side of the extension channel (REQ_EXTENSION 0x00; wire
//  formats in ExtensionChannel.swift).  Everything goes through the ordinary
//  DeviceTransport calls, so it works the same over the USB vendor
//  interface, USB MIDI, a DSPi Link hub and the demo device.
//
//  * Discovery: one EXT_LIST read per connect.  A refusal (STALL on USB,
//    ERROR on MIDI: stock firmware), a hub that denies the opcode to this
//    session (DSPi Link classifies the unlisted 0x00 as `config`, admin
//    only) or "unsupported" is final; any other failure is retried once.
//    Until the probe answers, every extension feature stays hidden, so a
//    console on stock firmware looks exactly as before.
//  * Writes use the ordinary fire-and-forget SET, then read the value back
//    on the same transport, which carries both in order.  The published
//    state follows the read-back, i.e. what the device accepted (the
//    firmware ignores an invalid pair map rather than refusing it).
//

import Foundation

extension DSPViewModel {

    // MARK: - Discovery

    /// Statuses after which asking again cannot help.
    static func extensionProbeIsFinal(_ status: LinkStatus) -> Bool {
        switch status {
        case .error, .denied, .unsupported, .noDevice, .badFrame, .frameError, .oversize: return true
        default: return false
        }
    }

    /// Read EXT_LIST unless this connection already answered it (`force`
    /// re-probes, for the connect path), then read what the listed features
    /// show.  Blocking; call off the main thread.
    func probeExtensions(force: Bool = false) {
        let generation = transport.generation
        extensionProbeLock.lock()
        let done = extensionProbeGeneration == generation
        extensionProbeLock.unlock()
        if done && !force { return }

        var state: ExtensionProbeState = .unsupported
        for attempt in 0..<2 {
            let result = transport.getControlResult(request: REQ_EXTENSION, value: EXT_LIST,
                                                    index: EXT_WINDEX, length: EXT_LIST_READ_LENGTH)
            if case .success(let data) = result {
                state = .supported(DeviceExtensions(listReply: data))
                break
            }
            if case .failure(let status) = result, Self.extensionProbeIsFinal(status) { break }
            if attempt == 0 { Thread.sleep(forTimeInterval: 0.2) }
            guard transport.generation == generation else { return }
        }
        guard transport.generation == generation else { return }
        extensionProbeLock.lock(); extensionProbeGeneration = generation; extensionProbeLock.unlock()

        let ext = state.extensions
        let map = ext.crossfeedPairMap ? readCrossfeedPairMap() : nil
        let vreg = ext.coreVreg ? readCoreVregStatus() : nil
        DispatchQueue.main.async {
            guard self.transport.generation == generation else { return }
            if self.extensionProbe != state { self.extensionProbe = state }
            if let map, self.crossfeed.pairMap != map { self.crossfeed.pairMap = map }
            self.coreVregStatus = vreg
        }
    }

    // MARK: - Crossfeed pair map

    /// Stereo pairs crossfeed can run on: the S/PDIF / I2S slots (2 on RP2040,
    /// 4 on RP2350).  The mono PDM sub is never in a pair.
    var crossfeedPairCount: Int { min(numOutputSlots, CrossfeedPairMap.byteCount) }

    /// The live map (EXT_CROSSFEED_PAIR_MAP IN), or nil when the read fails.
    /// Blocking.
    func readCrossfeedPairMap() -> CrossfeedPairMap? {
        guard case .success(let data) = transport.getControlResult(
            request: REQ_EXTENSION, value: EXT_CROSSFEED_PAIR_MAP, index: EXT_WINDEX,
            length: UInt16(CrossfeedPairMap.byteCount)),
              data.count >= CrossfeedPairMap.byteCount else { return nil }
        return CrossfeedPairMap(data)
    }

    /// Re-read the map and publish it.  Blocking; call off the main thread.
    func fetchCrossfeedPairMap() {
        let generation = transport.generation
        guard let map = readCrossfeedPairMap() else { return }
        DispatchQueue.main.async {
            guard self.transport.generation == generation, self.crossfeed.pairMap != map else { return }
            self.crossfeed.pairMap = map
        }
    }

    /// Set every pair's outputs at once (pairs must stay disjoint, so there is
    /// no per-pair write).  A map the firmware would ignore is refused here and
    /// nothing is sent.  The published map changes when the read-back that
    /// follows the write arrives.  Returns whether the write went out.
    @discardableResult
    func setCrossfeedPairMap(_ map: CrossfeedPairMap) -> Bool {
        guard crossfeedPairMapSupported, map.isValid(pairCount: crossfeedPairCount) else { return false }
        transport.sendControlRequest(request: REQ_EXTENSION, value: EXT_CROSSFEED_PAIR_MAP,
                                     index: EXT_WINDEX, data: map.normalized.data)
        DispatchQueue.global(qos: .userInitiated).async { self.fetchCrossfeedPairMap() }
        return true
    }

    // MARK: - Core voltage

    /// One EXT_CORE_VREG IN read, or nil.  Blocking.
    func readCoreVregStatus() -> CoreVregStatus? {
        guard case .success(let data) = transport.getControlResult(
            request: REQ_EXTENSION, value: EXT_CORE_VREG, index: EXT_WINDEX,
            length: UInt16(CoreVregStatus.size)) else { return nil }
        return CoreVregStatus(data)
    }

    /// Refresh the core-voltage status off the main thread (for the status
    /// section's appear and refresh).  A failed read keeps the last status.
    func refreshCoreVregStatus() {
        guard coreVregSupported else { return }
        let generation = transport.generation
        DispatchQueue.global(qos: .userInitiated).async {
            guard let status = self.readCoreVregStatus() else { return }
            DispatchQueue.main.async {
                guard self.transport.generation == generation else { return }
                self.coreVregStatus = status
            }
        }
    }
}
