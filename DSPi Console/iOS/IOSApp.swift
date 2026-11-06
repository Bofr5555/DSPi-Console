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
//    -ForceOrientation landscape|portrait
//                           rotate the window after launch (screenshots)
//    -EmulateWidth <points> lay the app out in a window that narrow, as in
//                           iPad Slide Over or Split View (screenshots)
//    -ShowChannels YES      show the channel list in a one-pane window
//    -SelectBand <n>        select PEQ band n on the graph (with -SelectChannel)
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            IOSRootView(vm: AppState.shared.viewModel)
                .modifier(WindowWidthReader())
                .modifier(EmulatedWindowWidth())
                // Text styles grow with Dynamic Type up to three steps past
                // the default.  The console is dense and many shared views
                // use fixed point sizes, so the accessibility sizes beyond
                // that would break rows and tables rather than help.
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
                .onChange(of: scenePhase) { old, new in
                    // Back from the background: the USB MIDI device may have
                    // changed or gone while the app was suspended.
                    // iOS suspends the app soon after it leaves the screen, so
                    // a hub's WebSocket is dead or stale by now: dial again,
                    // and the view model re-reads the device on connect.
                    if old == .background && new != .background {
                        let transport = AppState.shared.transport
                        if transport.isRemoteActive {
                            transport.reconnect()
                        } else {
                            AppState.shared.midiTransport.resume()
                        }
                    }
                }
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

    @ObservedObject private var panes = CompactPanes.shared
    @Environment(\.horizontalSizeClass) private var sizeClass
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
        // A hub that asks for a PIN: over the Devices sheet when that is up
        // (that is where a shared device gets picked), from here otherwise.
        .linkPairingSheet(active: !showDevices)
        .onAppear(perform: launch)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if panes.isSinglePane {
            ToolbarItem(placement: .topBarLeading) {
                Button { panes.showsChannelList.toggle() } label: {
                    if panes.showsChannelList {
                        Label("Console", systemImage: "chart.xyaxis.line")
                    } else {
                        Label("Channels", systemImage: "sidebar.left")
                    }
                }
            }
        }
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
        if let orientation = defaults.string(forKey: "ForceOrientation"),
           let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            let mask: UIInterfaceOrientationMask = orientation == "landscape" ? .landscapeRight : .portrait
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        if defaults.bool(forKey: "ShowChannels") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { CompactPanes.shared.showsChannelList = true }
        }
        let band = defaults.integer(forKey: "SelectBand")
        if band >= 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { vm.peqSelection.selected = [band - 1] }
        }
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
    @ObservedObject private var browser = AppState.shared.linkClientCoordinator.browser
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
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
                    if client.lookForHubs && browser.isLocalNetworkDenied {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Local network access is off", systemImage: "wifi.exclamationmark")
                                .font(.headline)
                            Text("DSPi Console needs it to find and reach DSPi Link hubs. Turn on Local Network for DSPi Console in Settings, Privacy & Security, Local Network.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                        .padding(.vertical, 4)
                    } else if client.lookForHubs, let error = client.browseError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
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
            .linkPairingSheet()
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

/// `-EmulateWidth <points>`: the app laid out in a window of that width at
/// the leading edge, with the horizontal size class such a window gets
/// (compact below 600 pt), the way iPad Slide Over and Split View size it.
/// Lets screenshots and UI tests cover multitasking widths without driving
/// the multitasking UI.
struct EmulatedWindowWidth: ViewModifier {
    private let width: CGFloat? = UserDefaults.standard.string(forKey: "EmulateWidth")
        .flatMap(Double.init).map { CGFloat($0) }

    func body(content: Content) -> some View {
        if let width = width {
            content
                .environment(\.horizontalSizeClass, width < 600 ? .compact : .regular)
                .frame(width: width)
                .overlay(Rectangle().stroke(Color.gray.opacity(0.6), lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
        }
    }
}

/// `HSplitView` is AppKit-backed and macOS-only.  On iOS the console's two
/// panes (channel list; graph and channel page) sit side by side in a wide
/// window, without a draggable divider.  A narrower one (an iPhone, iPad
/// Slide Over or Split View, an iPad mini in portrait) shows one at a time,
/// switched by `CompactPanes`.
struct HSplitView<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject private var panes = CompactPanes.shared
    @ViewBuilder let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        let single = CompactPanes.wantsSinglePane(width: panes.windowWidth, sizeClass: sizeClass,
                                                  verticalSizeClass: verticalSizeClass)
        Group {
            if single, #available(iOS 18.0, *) {
                CompactPaneSwitcher(content: content)
            } else {
                HStack(spacing: 0) { content() }
            }
        }
        .onAppear { panes.setSinglePane(single) }
        .onChange(of: single) { _, now in panes.setSinglePane(now) }
    }
}

/// Which pane a narrow window shows: the console (graph, dashboard or
/// channel page) or the channel list.  Selecting a channel shows its page;
/// the toolbar's Channels button goes back to the list.
final class CompactPanes: ObservableObject {
    static let shared = CompactPanes()
    @Published var showsChannelList = false
    /// True while the window shows one pane at a time.
    @Published private(set) var isSinglePane = false
    /// The window's width, measured at the root (`WindowWidthReader`): a
    /// GeometryReader inside the console is not re-read when the window
    /// rotates.
    @Published var windowWidth: CGFloat = 0

    /// Below this width the 220 pt channel list and a channel page (filter
    /// table, channel header) do not fit side by side: an iPad mini in
    /// portrait is 744 pt, an 11-inch iPad 834 pt.
    static let minimumTwoPaneWidth: CGFloat = 820

    /// One pane in a compact width, below `minimumTwoPaneWidth`, and in a
    /// compact height (an iPhone in landscape, even a Pro Max at 956 pt: the
    /// channel list's bottom panel would cover its rows).
    static func wantsSinglePane(width: CGFloat, sizeClass: UserInterfaceSizeClass?,
                                verticalSizeClass: UserInterfaceSizeClass? = nil) -> Bool {
        guard #available(iOS 18.0, *) else { return false }
        return sizeClass == .compact || verticalSizeClass == .compact
            || (width > 0 && width < minimumTwoPaneWidth)
    }
}

/// Measures the window's width into `CompactPanes.windowWidth`.
struct WindowWidthReader: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { CompactPanes.shared.windowWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in CompactPanes.shared.windowWidth = width }
            }
        )
    }
}

extension CompactPanes {

    func setSinglePane(_ single: Bool) {
        if isSinglePane != single { isSinglePane = single }
        if !single && showsChannelList { showsChannelList = false }
    }
}

/// The two panes of `HSplitView` one at a time.  Both stay alive (the hidden
/// one is transparent and inert), so lists keep their scroll position.
/// iOS 18 for `Group(subviews:)`; iOS 17 keeps the side-by-side layout.
@available(iOS 18.0, *)
private struct CompactPaneSwitcher<Content: View>: View {
    let content: () -> Content
    @ObservedObject private var panes = CompactPanes.shared
    @ObservedObject private var vm = AppState.shared.viewModel

    var body: some View {
        Group(subviews: content()) { subviews in
            if subviews.count == 2 {
                ZStack {
                    subviews[0]
                        .opacity(panes.showsChannelList ? 1 : 0)
                        .allowsHitTesting(panes.showsChannelList)
                    subviews[1]
                        .opacity(panes.showsChannelList ? 0 : 1)
                        .allowsHitTesting(!panes.showsChannelList)
                }
            } else {
                HStack(spacing: 0) { subviews }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: panes.showsChannelList)
        // A tap on a channel row selects it (or goes back to the overview):
        // show the console pane with that page.
        .onChange(of: vm.activeEqChannel) { _, _ in panes.showsChannelList = false }
    }
}

extension View {
    /// The sidebar pane's width (macOS: ContentView.swift): 220 to 260 pt
    /// beside the console, the full width when it is the only pane.
    @ViewBuilder
    func sidebarPaneFrame() -> some View {
        modifier(SidebarPaneFrame())
    }
}

extension View {
    /// The response graph's height (macOS: ContentView.swift): the user's
    /// setting, capped at 140 pt in a short window (an iPhone in landscape),
    /// so the channel page below keeps some room.
    func consoleGraphFrame(height: CGFloat) -> some View {
        modifier(ConsoleGraphFrame(height: height))
    }

    /// The console column (macOS: ContentView.swift, minimum height 500 pt).
    func consoleColumnFrame() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension View {
    /// The channel page or dashboard below the graph (macOS: ContentView
    /// .swift, unchanged).  Their tables have fixed columns (a channel's
    /// page is about 500 pt, a stereo dashboard card about 440 pt),
    /// wider than an iPhone, so in a one-pane window they keep that width and
    /// scroll sideways; the graph above stays the screen's width.
    func consoleDetailFrame() -> some View {
        modifier(ConsoleDetailFrame())
    }
}

private struct ConsoleDetailFrame: ViewModifier {
    static let minimumHeight: CGFloat = 420
    @ObservedObject private var panes = CompactPanes.shared
    @ObservedObject private var vm = AppState.shared.viewModel

    func body(content: Content) -> some View {
        if panes.isSinglePane {
            let minimum: CGFloat = vm.activeEqChannel == nil ? 440 : 500
            GeometryReader { proxy in
                ScrollView([.horizontal, .vertical]) {
                    // Top-leading, so content that is still larger starts at
                    // the corner instead of being cut on both sides.  At
                    // least 420 pt high, which a phone in landscape does not
                    // have: the channel header and a few filter rows, the
                    // rest by scrolling.
                    content.frame(width: max(proxy.size.width, minimum),
                                  height: max(proxy.size.height, Self.minimumHeight),
                                  alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
            }
        } else {
            content
        }
    }
}

private struct ConsoleGraphFrame: ViewModifier {
    let height: CGFloat
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    func body(content: Content) -> some View {
        content.frame(height: verticalSizeClass == .compact ? min(height, 140) : height)
    }
}

private struct SidebarPaneFrame: ViewModifier {
    @ObservedObject private var panes = CompactPanes.shared

    func body(content: Content) -> some View {
        if panes.isSinglePane {
            content.frame(maxWidth: .infinity)
        } else {
            content.frame(minWidth: 220, maxWidth: 260)
        }
    }
}

extension UIApplication {
    /// Ends text editing anywhere in the app (AppKit: `makeFirstResponder(nil)`).
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
