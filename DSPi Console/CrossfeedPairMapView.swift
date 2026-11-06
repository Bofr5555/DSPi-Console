//
//  CrossfeedPairMapView.swift
//  DSPi Console
//
//  The crossfeed window's pair editor, for firmware with the extension
//  channel's EXT_CROSSFEED_PAIR_MAP (bofr fork): which two outputs each
//  crossfeed pair processes.  Boards whose left and right outputs are not on
//  neighbouring slots need it - the K340 amplifier has one DAC per ear, so
//  its pairs are outputs 3/1 (woofers) and 4/2 (tweeters).  Without the
//  extension none of this is shown and the window is upstream's.
//
//  Every write sends the whole map (pairs must stay disjoint, so there is no
//  per-pair write), and the view shows the map the device reports.
//

import SwiftUI

/// The choices of the "Outputs" menu.
enum CrossfeedPairChoice: CaseIterable {
    case standard
    case oneDACPerEar
    case custom

    var title: String {
        switch self {
        case .standard:     return "Default (1/2, 3/4, …)"
        case .oneDACPerEar: return "One DAC per ear (K340)"
        case .custom:       return "Custom…"
        }
    }

    /// The preset a map matches, or `.custom`.
    static func of(_ map: CrossfeedPairMap) -> CrossfeedPairChoice {
        if map.samePairing(as: .default) { return .standard }
        if map.samePairing(as: .oneDACPerEar) { return .oneDACPerEar }
        return .custom
    }
}

/// The "Outputs" row, the K340 mask offer and the inline custom editor.
struct CrossfeedPairMapControls: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject var crossfeed: CrossfeedParameters

    @State private var editing = false
    @State private var offerMask = false
    @State private var draft: [PairDraft] = []

    struct PairDraft: Equatable {
        var left: Int
        var right: Int
    }

    private var pairCount: Int { vm.crossfeedPairCount }
    private var map: CrossfeedPairMap { crossfeed.pairMap }
    private var choice: CrossfeedPairChoice { CrossfeedPairChoice.of(map) }
    private var enabled: Bool { vm.isDeviceConnected }

    /// The editor's pairs as a map, or nil when the device would refuse them.
    private var draftMap: CrossfeedPairMap? {
        CrossfeedPairMap.validated(pairs: draft.map { (left: $0.left, right: $0.right) }, pairCount: pairCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Outputs")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    ForEach(CrossfeedPairChoice.allCases, id: \.self) { c in
                        Button(c.title) { pick(c) }
                    }
                } label: {
                    Text(choice == .custom ? "Custom" : choice.title)
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!enabled)
                .accessibilityIdentifier("crossfeed.pairs.menu")
            }

            Text("Which two outputs each pair crossfeeds. An output can belong to one pair only.")
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if offerMask, choice == .oneDACPerEar,
               crossfeed.outputMask & CrossfeedPairMap.oneDACPerEarPairMask != CrossfeedPairMap.oneDACPerEarPairMask {
                maskOffer
            }

            if editing && enabled {
                editor
            }
        }
        .onChange(of: enabled) { _, isOn in if !isOn { editing = false } }
    }

    private func pick(_ c: CrossfeedPairChoice) {
        switch c {
        case .standard:
            offerMask = false
            vm.setCrossfeedPairMap(.default)
        case .oneDACPerEar:
            offerMask = true
            vm.setCrossfeedPairMap(.oneDACPerEar)
        case .custom:
            draft = (0..<pairCount).map { let p = map.pair($0); return PairDraft(left: p.left, right: p.right) }
            editing = true
        }
    }

    /// After the K340 preset: crossfeed both pairs, as the factory mask covers
    /// pair 1 (the woofers) only.  An explicit tap, never automatic.
    private var maskOffer: some View {
        HStack(spacing: 8) {
            Text("Crossfeed the woofers and the tweeters?")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Not Now") { offerMask = false }
                .font(.system(size: 11))
            Button("Enable Pairs 1 and 2") {
                vm.setCrossfeedMask(crossfeed.outputMask | CrossfeedPairMap.oneDACPerEarPairMask)
                offerMask = false
            }
            .font(.system(size: 11))
            .disabled(!enabled)
        }
    }

    // MARK: - Custom editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<draft.count, id: \.self) { p in
                HStack(spacing: 6) {
                    Text("Pair \(p + 1)")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 46, alignment: .leading)
                    outputMenu(selected: draft[p].left) { draft[p].left = $0 }
                    Text("↔")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    outputMenu(selected: draft[p].right) { draft[p].right = $0 }
                    Spacer(minLength: 0)
                }
            }
            let valid = draftMap != nil
            if !valid {
                Text("Each pair needs two different outputs, and no output can be in two pairs.")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { editing = false }
                    .font(.system(size: 11))
                Button("Apply") {
                    if let map = draftMap, vm.setCrossfeedPairMap(map) { editing = false }
                }
                .font(.system(size: 11))
                .disabled(!valid || !enabled)
                .accessibilityIdentifier("crossfeed.pairs.editor.apply")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func outputMenu(selected: Int, onPick: @escaping (Int) -> Void) -> some View {
        Menu {
            ForEach(0..<(2 * pairCount), id: \.self) { o in
                Button("\(o + 1) — \(vm.crossfeedOutputName(o))") { onPick(o) }
            }
        } label: {
            Text("Out \(selected + 1)")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

extension DSPViewModel {
    /// Channel name of output `o` (0-based), or "Out n" before names arrive.
    func crossfeedOutputName(_ o: Int) -> String {
        let idx = chOut1 + o
        return idx < channelNames.count && !channelNames[idx].isEmpty ? channelNames[idx] : "Out \(o + 1)"
    }
}
