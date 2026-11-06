//
//  CoreVoltageStatusView.swift
//  DSPi Console
//
//  Settings > Overview: the core-voltage status of firmware with the
//  extension channel's EXT_CORE_VREG (bofr fork).  At the fixed 307.2 MHz
//  clock some RP2350 parts hang at the stock 1.15 V; the firmware can run a
//  higher stored voltage, raise it by itself after repeated watchdog hangs,
//  and try a voltage without storing it.  This section only reads: the
//  writes (stored voltage, trials, automatic raising) are not offered yet.
//  Shown only when the device lists EXT_CORE_VREG.
//

import SwiftUI

struct CoreVoltageSection: View {
    @ObservedObject var vm: DSPViewModel

    var body: some View {
        Section {
            if let s = vm.coreVregStatus {
                rows(s)
            } else {
                Text("Reading…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            HStack {
                Label("Core Voltage", systemImage: "bolt")
                Spacer()
                Button {
                    vm.refreshCoreVregStatus()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Read the status again")
                .accessibilityIdentifier("coreVoltage.refresh")
            }
        } footer: {
            Text("At its 307.2 MHz clock the device raises its stored voltage one step by itself after two watchdog hangs in one power session, up to 1.25 V.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .onAppear { vm.refreshCoreVregStatus() }
    }

    private func volts(_ code: UInt8) -> String { VregVoltage.label(code, platform: vm.platformName) }

    @ViewBuilder
    private func rows(_ s: CoreVregStatus) -> some View {
        row("Running at", volts(s.liveVreg) + (s.trialActive ? " (trial)" : ""))
        if s.trialActive && s.trialVreg != s.liveVreg {
            row("Trial voltage", volts(s.trialVreg))
        }
        row("Stored", s.storedSel == 0 ? "Build default" : volts(s.storedSel)
            + (s.autoRaised ? ", raised by the device" : ""))
        row("Build default", volts(s.defaultVreg))
        row("Automatic raising", s.autoRaiseDisabled ? "Off" : "On")
        row("Hangs this session", "\(s.hangCount)")
        row("Last failed trial", s.hasFailedTrial
            ? "\(volts(s.failedTrialVreg)), hung after \(formatUptime(s.failedTrialUptimeS))"
            : "None")
        row("Uptime", formatUptime(s.uptimeS))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
