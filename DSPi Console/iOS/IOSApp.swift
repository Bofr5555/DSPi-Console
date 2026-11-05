//
//  IOSApp.swift
//  DSPi Console (iOS target)
//
//  The iOS/iPadOS app shell.  The macOS app's scene (`DSPi_ConsoleApp`: one
//  main window, a Settings window, tool windows, the menu bar and the menu
//  bar extra) has no iOS equivalent, so this file supplies a minimal one:
//
//  * one WindowGroup showing the same `MainWindowRoot`/`ContentView`, inside a
//    NavigationStack whose toolbar carries what the Mac menus carry (Devices,
//    Tools, the flash operations, Settings);
//  * tool windows as sheets, through `ToolSheetPresenter` (iOSCompat.swift);
//  * Settings as a sheet holding the shared `SettingsView`;
//  * a Devices sheet: a DSPi on USB (its MIDI control port), the demo device,
//    DSPi Link hubs found on the network, and manual hub entry.
//
//  The compact (iPhone portrait) layout is work package A3; this shell keeps
//  the macOS two-pane console as is.
//
//  Launch arguments (for the Simulator and UI tests):
//    -DemoMode YES|NO       connect to the demo device at launch (default YES
//                           in the Simulator, NO on a device)
//    -OpenTool <name>       open a tool sheet after launch: matrix, loudness,
//                           crossfeed, psybass, subharm, tube, upmixer,
//                           leveller, siggen, spectrum, stats, interrupts,
//                           autoeq, graph, settings, devices, whatsnew
//    -SelectChannel <c>     select a channel page: in1..in8, out1..out9
//    -LocalTransport demo   leave the USB MIDI transport out (demo only)
//    -MIDIReadOnly YES      send only pure reads to a DSPi on USB MIDI
//

#if os(iOS)
import SwiftUI
import UIKit

@main
struct DSPiConsoleIOSApp: App {
    @StateObject private var statsWindowController = StatsWindowController()
    @StateObject private var loudnessWindowController = LoudnessWindowController()
    @StateObject private var crossfeedWindowController = CrossfeedWindowController()
    @StateObject private var psybassWindowController = PsychoacousticBassWindowController()
    @StateObject private var subharmWindowController = SubharmonicSynthWindowController()
    @StateObject private var tubeWindowController = TubeModellerWindowController()
    @StateObject private var upmixerWindowController = UpmixerWindowController()
    @StateObject private var levellerWindowController = VolumeLevellerWindowController()
    @StateObject private var autoEQBrowserController = AutoEQBrowserController()
    @StateObject private var matrixMixerWindowController = MatrixMixerWindowController()
    @StateObject private var graphWindowController = GraphWindowController()
    @StateObject private var interruptMonitorWindowController = InterruptMonitorWindowController()
    @StateObject private var testSignalsWindowController = TestSignalsWindowController()
    @StateObject private var spectrumWindowController = SpectrumAnalyserWindowController()
    @StateObject private var firmwareUpdateWindowController = FirmwareUpdateWindowController()
    @StateObject private var whatsNewWindowController = WhatsNewWindowController()
    @StateObject private var onboarding = OnboardingCoordinator.shared

    var body: some Scene {
        WindowGroup {
            IOSRootView(vm: AppState.shared.viewModel)
                .environmentObject(matrixMixerWindowController)
                .environmentObject(loudnessWindowController)
                .environmentObject(crossfeedWindowController)
                .environmentObject(psybassWindowController)
                .environmentObject(subharmWindowController)
                .environmentObject(tubeWindowController)
                .environmentObject(upmixerWindowController)
                .environmentObject(levellerWindowController)
                .environmentObject(statsWindowController)
                .environmentObject(graphWindowController)
                .environmentObject(interruptMonitorWindowController)
                .environmentObject(spectrumWindowController)
                .environmentObject(firmwareUpdateWindowController)
                .environmentObject(whatsNewWindowController)
                .environmentObject(autoEQBrowserController)
                .environmentObject(onboarding)
                .preferredColorScheme(.dark)
        }
    }
}

/// The console with an iOS toolbar standing in for the Mac menu bar.
struct IOSRootView: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject private var sheets = ToolSheetPresenter.shared
    @ObservedObject private var platform = PlatformInfo.shared
    @EnvironmentObject private var onboarding: OnboardingCoordinator
    @EnvironmentObject private var matrixMixer: MatrixMixerWindowController
    @EnvironmentObject private var loudness: LoudnessWindowController
    @EnvironmentObject private var crossfeed: CrossfeedWindowController
    @EnvironmentObject private var psybass: PsychoacousticBassWindowController
    @EnvironmentObject private var subharm: SubharmonicSynthWindowController
    @EnvironmentObject private var tube: TubeModellerWindowController
    @EnvironmentObject private var upmixer: UpmixerWindowController
    @EnvironmentObject private var leveller: VolumeLevellerWindowController
    @EnvironmentObject private var stats: StatsWindowController
    @EnvironmentObject private var graph: GraphWindowController
    @EnvironmentObject private var interrupts: InterruptMonitorWindowController
    @EnvironmentObject private var spectrum: SpectrumAnalyserWindowController
    @EnvironmentObject private var firmwareUpdate: FirmwareUpdateWindowController
    @EnvironmentObject private var whatsNew: WhatsNewWindowController
    @EnvironmentObject private var autoEQ: AutoEQBrowserController

    @State private var showSettings = false
    @State private var showDevices = false
    @State private var didLaunch = false

    var body: some View {
        NavigationStack {
            MainWindowRoot(vm: vm)
                .toolbar { toolbarContent }
                .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $sheets.current) { sheet in
            ToolSheetHost(sheet: sheet)
                .environmentObject(onboarding)
                .environmentObject(graph)
                .environmentObject(spectrum)
                .toolSheetSizing()
        }
        .sheet(isPresented: $showSettings) { IOSSettingsSheet() }
        .sheet(isPresented: $showDevices) { IOSDevicesSheet(vm: vm) }
        .onAppear(perform: launch)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { showDevices = true } label: {
                Label("Devices", systemImage: vm.isDeviceConnected ? "cable.connector" : "cable.connector.slash")
            }
            Menu {
                toolsMenu
            } label: {
                Label("Tools", systemImage: "wrench.and.screwdriver")
            }
            .disabled(onboarding.shouldTakeOverMainWindow())
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }

    /// The Mac's Tools and File menus, as one menu.
    @ViewBuilder
    private var toolsMenu: some View {
        Section {
            Button("Matrix Mixer") { matrixMixer.show() }
            Button("Loudness Compensation") { loudness.show(vm: vm) }
            Button("Headphone Crossfeed") { crossfeed.show(vm: vm) }
            Button("Psychoacoustic Bass") { psybass.show(vm: vm) }
            Button("Subharmonic Synthesizer") { subharm.show(vm: vm) }
            Button("Tube Modeller") { tube.show(vm: vm) }
            Button("Stereo Upmixer") { upmixer.show(vm: vm) }
            Button("Volume Leveller") { leveller.show(vm: vm) }
            Button("Signal Generator") { TestSignalsSheet.show(vm: vm) }
            Button("Spectrum Analyser") { spectrum.show(vm: vm) }
            Button("Filter Response") { graph.show(vm: vm) }
        }
        Section {
            Button("AutoEQ Profiles") { autoEQ.show() }
            Button("Stats for nerbs") { stats.show(transport: vm.transport) }
            Button("Interrupt Monitor") { interrupts.show() }
        }
        Section {
            Button("Commit Parameters...") { ToolsMenuActions.commitParameters() }
            Button("Revert to Saved...") { ToolsMenuActions.revertToSaved() }
            Button("Factory Reset...", role: .destructive) { ToolsMenuActions.factoryReset() }
            if platform.name != "STM32H723" {
                Button("Firmware Update...") { firmwareUpdate.show(vm: vm) }
            }
        }
        Section {
            Button("What's New") { whatsNew.show() }
        }
    }

    /// One-time launch work: onboarding, and the launch-argument hooks used
    /// for Simulator screenshots and UI tests.
    private func launch() {
        guard !didLaunch else { return }
        didLaunch = true
        // The setup wizard walks through real hardware (firmware, wiring);
        // the demo device has none, so demo launches go straight to the
        // console.
        if !FakeTransport.autoSelectAtLaunch {
            onboarding.evaluate(vm: vm)
        }
        _ = AppState.shared.linkClientCoordinator

        let defaults = UserDefaults.standard
        if let tool = defaults.string(forKey: "OpenTool") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { open(tool: tool) }
        }
    }

    private func open(tool: String) {
        switch tool.lowercased() {
        case "matrix":     matrixMixer.show()
        case "loudness":   loudness.show(vm: vm)
        case "crossfeed":  crossfeed.show(vm: vm)
        case "psybass":    psybass.show(vm: vm)
        case "subharm":    subharm.show(vm: vm)
        case "tube":       tube.show(vm: vm)
        case "upmixer":    upmixer.show(vm: vm)
        case "leveller":   leveller.show(vm: vm)
        case "siggen":     TestSignalsSheet.show(vm: vm)
        case "spectrum":   spectrum.show(vm: vm)
        case "stats":      stats.show(transport: vm.transport)
        case "interrupts": interrupts.show()
        case "autoeq":     autoEQ.show()
        case "graph":      graph.show(vm: vm)
        case "whatsnew":   whatsNew.show()
        case "settings":   showSettings = true
        case "devices":    showDevices = true
        default:           break
        }
    }
}

/// The Signal Generator's controller lives in the macOS scene only as a
/// StateObject; on iOS one shared instance is enough.
enum TestSignalsSheet {
    private static let controller = TestSignalsWindowController()
    static func show(vm: DSPViewModel) { controller.show(vm: vm) }
}

// MARK: - Settings

/// The shared Settings view (sidebar + detail), as a sheet with a Done button.
struct IOSSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsView()
            .environmentObject(OnboardingCoordinator.shared)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .preferredColorScheme(.dark)
    }
}

// MARK: - Devices

/// The connect screen: a DSPi on USB MIDI, the demo device, devices on DSPi
/// Link hubs found on the local network, and hubs added by address.  Selecting a device goes through
/// `DSPViewModel.switchToDevice`, exactly as the Mac's device picker does.
struct IOSDevicesSheet: View {
    @ObservedObject var vm: DSPViewModel
    @ObservedObject private var client = AppState.shared.linkClientCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var manualAddress = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(vm.availableDevices) { device in
                        Button {
                            vm.switchToDevice(device)
                        } label: {
                            HStack {
                                let isDemo = device == FakeTransport.demoDevice
                                Image(systemName: device.isRemote ? "network" : isDemo ? "play.rectangle" : "cable.connector")
                                    .frame(width: 24)
                                VStack(alignment: .leading) {
                                    Text(device.displayName)
                                    Text(device.isRemote ? "DSPi Link" : isDemo ? "Simulated DSPi, RP2350, firmware 1.1.6" : "USB, MIDI control port")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if device == vm.selectedDevice {
                                    Image(systemName: vm.isDeviceConnected ? "checkmark.circle.fill" : "circle.dotted")
                                        .foregroundStyle(vm.isDeviceConnected ? .green : .secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                    if let error = vm.connectionError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("A DSPi on USB appears here when its firmware has the MIDI control port (\"DSPi Control\"). Or use the demo device, or a DSPi shared by DSPi Console on a Mac (Settings > Networking there) or another DSPi Link hub.")
                }

                Section {
                    Toggle("Look for hubs on this network", isOn: $client.lookForHubs)
                    ForEach(client.hubs) { hub in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(hub.name)
                                Text(hub.displayAddress).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if hub.isManual {
                                Button(role: .destructive) { client.removeManual(hub) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    HStack {
                        TextField("Hub address (host or host:port)", text: $manualAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .onSubmit(addManual)
                        Button("Add", action: addManual)
                            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("DSPi Link")
                }
            }
            .navigationTitle("Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func addManual() {
        client.addManual(manualAddress)
        manualAddress = ""
    }
}

private extension View {
    /// Tool windows were sized for a Mac screen; on iPadOS 18+ give their
    /// sheets the larger page size instead of the default form sheet.
    @ViewBuilder
    func toolSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.page)
        } else {
            self
        }
    }
}

// MARK: - Layout shims

/// `HSplitView` is AppKit-backed and macOS-only.  On iOS the console's two
/// panes sit side by side in a plain HStack (no draggable divider); the
/// compact phone layout replaces this in A3.
struct HSplitView<Content: View>: View {
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: 0) { content() }
    }
}

extension UIApplication {
    /// Ends text editing anywhere in the app (AppKit: `makeFirstResponder(nil)`).
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
