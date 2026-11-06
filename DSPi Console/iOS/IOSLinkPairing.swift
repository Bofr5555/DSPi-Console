//
//  IOSLinkPairing.swift
//  DSPi Console (iOS target)
//
//  Pairing with a DSPi Link hub that asks for a PIN, as a sheet (work
//  package A7).  The Mac asks with a modal NSAlert through
//  `CompositeTransport.pairingPrompt`; iOS cannot block the main thread for a
//  sheet, so it answers `asyncPairingPrompt` instead: the request is published
//  here, a sheet shows it, and the PIN (or nil for Cancel) goes back to the
//  hub's NetworkTransport.  A wrong PIN makes the transport ask again, which
//  shows the sheet again.
//

#if os(iOS)
import SwiftUI

@MainActor
final class IOSLinkPairing: ObservableObject {
    static let shared = IOSLinkPairing()

    struct Request: Identifiable {
        let id = UUID()
        let hubName: String
        fileprivate let completion: (String?) -> Void
    }

    @Published var request: Request?

    /// `CompositeTransport.asyncPairingPrompt`.
    nonisolated static func ask(hubName: String, completion: @escaping (String?) -> Void) {
        Task { @MainActor in shared.present(hubName: hubName, completion: completion) }
    }

    private func present(hubName: String, completion: @escaping (String?) -> Void) {
        // One question at a time: an older one is given up.
        request?.completion(nil)
        request = Request(hubName: hubName, completion: completion)
    }

    /// The user's answer: a PIN, or nil for Cancel.
    func answer(_ pin: String?) {
        guard let pending = request else { return }
        request = nil
        pending.completion(pin)
    }

    /// Valid PINs are six digits (DSPi Link spec 7.2).
    nonisolated static func isValid(_ pin: String) -> Bool {
        pin.count == 6 && pin.allSatisfy(\.isNumber)
    }
}

struct IOSPairingSheet: View {
    let request: IOSLinkPairing.Request
    @State private var pin = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("000000", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 30, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .focused($focused)
                        .accessibilityLabel("Pairing code")
                        .onChange(of: pin) { _, value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { pin = digits }
                        }
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("""
                        On a Mac sharing its DSPi with DSPi Console: open Settings, Networking, \
                        choose Allow a New Client and enter the code it shows within two minutes. \
                        On a DSPi Link bridge: enter the PIN set on its web page.
                        """)
                }
            }
            .navigationTitle("Pair with \(request.hubName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { IOSLinkPairing.shared.answer(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { IOSLinkPairing.shared.answer(pin) }
                        .disabled(!IOSLinkPairing.isValid(pin))
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled()
        .preferredColorScheme(.dark)
    }
}

extension View {
    /// Presents the pairing sheet when a hub asks for a PIN.  `active` false
    /// leaves it to another presenter (the Devices sheet, while it is up).
    func linkPairingSheet(active: Bool = true) -> some View {
        modifier(LinkPairingSheetModifier(active: active))
    }
}

private struct LinkPairingSheetModifier: ViewModifier {
    let active: Bool
    @ObservedObject private var pairing = IOSLinkPairing.shared

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? pairing.request : nil },
                                    set: { if $0 == nil, active { pairing.answer(nil) } })) { request in
            IOSPairingSheet(request: request)
        }
    }
}
#endif
