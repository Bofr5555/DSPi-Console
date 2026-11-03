//
//  iOSCompat.swift
//  DSPi Console (iOS target)
//
//  The small compatibility layer that lets the shared SwiftUI views compile
//  for iOS/iPadOS unchanged where AppKit and UIKit only differ by name.
//  Everything here is iOS-only: on macOS this file compiles to nothing, so
//  the macOS target sees exactly the AppKit types it always did.
//
//  Kept deliberately small.  Value types (points, sizes, rects) and the
//  colour/font classes are aliased because their APIs match; anything with
//  behaviour (windows, events, alerts, panels) is NOT aliased - those call
//  sites are fenced with `#if os(macOS)` and get an iOS path of their own.
//

#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Name-only aliases

typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSPoint = CGPoint
typealias NSSize = CGSize
typealias NSRect = CGRect

extension UIColor {
    // The semantic AppKit colours the shared views use, mapped to their
    // closest UIKit equivalents.
    static var controlBackgroundColor: UIColor { .secondarySystemBackground }
    static var windowBackgroundColor: UIColor { .systemBackground }
    static var textBackgroundColor: UIColor { .systemBackground }
    static var separatorColor: UIColor { .separator }
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var controlAccentColor: UIColor { .tintColor }

    /// AppKit's `NSColor(srgbRed:green:blue:alpha:)`; UIKit's designated
    /// initialiser is already sRGB (extended).
    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

extension UIView {
    /// AppKit's `needsLayout = true` and `needsDisplay = true`, so shared
    /// view code can ask for a pass the same way on both platforms.  Setting
    /// false is a no-op; reading always answers false (UIKit does not expose
    /// the pending state).
    var needsLayout: Bool {
        get { false }
        set { if newValue { setNeedsLayout() } }
    }
    var needsDisplay: Bool {
        get { false }
        set { if newValue { setNeedsDisplay() } }
    }
}

extension UIFont {
    /// AppKit's small control font size.
    static var smallSystemFontSize: CGFloat { 11 }
}

extension Color {
    /// AppKit spelling of `Color(uiColor:)`.
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}

// MARK: - Control styles

extension ToggleStyle where Self == SwitchToggleStyle {
    /// macOS checkboxes become switches, the iOS idiom for a boolean.
    static var checkbox: SwitchToggleStyle { .switch }
}

extension PrimitiveButtonStyle where Self == BorderlessButtonStyle {
    /// macOS link-styled buttons become borderless (tinted text) buttons.
    static var link: BorderlessButtonStyle { .borderless }
}

// MARK: - Alerts

/// A stand-in for the `NSAlert.runModal()` call sites.  UIKit has no modal
/// run loop, so the answer arrives in a completion instead of a return value;
/// each macOS call site keeps its `NSAlert` and gets a `#else` branch that
/// uses this.  Button indices follow `NSAlert`: 0 is the first button added
/// (`.alertFirstButtonReturn`), and the last one added is treated as the
/// cancel button when it is titled "Cancel".
final class PlatformAlert {
    enum Style { case informational, warning, critical }

    var messageText = ""
    var informativeText = ""
    var alertStyle: Style = .informational
    private(set) var buttons: [String] = []

    func addButton(withTitle title: String) { buttons.append(title) }

    func present(_ completion: @escaping (Int) -> Void = { _ in }) {
        DispatchQueue.main.async {
            let controller = UIAlertController(title: self.messageText,
                                               message: self.informativeText.isEmpty ? nil : self.informativeText,
                                               preferredStyle: .alert)
            let titles = self.buttons.isEmpty ? ["OK"] : self.buttons
            for (index, title) in titles.enumerated() {
                let style: UIAlertAction.Style
                if title == "Cancel" {
                    style = .cancel
                } else if index == 0 && self.alertStyle == .critical {
                    style = .destructive
                } else {
                    style = .default
                }
                controller.addAction(UIAlertAction(title: title, style: style) { _ in completion(index) })
            }
            guard let presenter = UIApplication.shared.topViewController else {
                completion(titles.count - 1)
                return
            }
            presenter.present(controller, animated: true)
        }
    }
}

extension UIApplication {
    /// The view controller an alert or sheet should be presented from.
    var topViewController: UIViewController? {
        let scenes = connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Tool windows as sheets

/// What the iOS root view presents: one tool "window" at a time, as a sheet.
/// The macOS window controllers each own an `NSWindow`; their iOS twins all
/// route through this presenter instead, so ContentView and the menus keep
/// calling the same `show`/`hide`/`toggle` API on both platforms.
final class ToolSheetPresenter: ObservableObject {
    static let shared = ToolSheetPresenter()

    struct Sheet: Identifiable {
        let id: String
        let title: String
        let content: AnyView
        let onDismiss: () -> Void
    }

    @Published var current: Sheet?

    func present(id: String, title: String, content: AnyView, onDismiss: @escaping () -> Void) {
        // Replacing an open sheet dismisses it first; let its owner know.
        if let open = current, open.id != id { open.onDismiss() }
        current = Sheet(id: id, title: title, content: content, onDismiss: onDismiss)
    }

    func dismiss(id: String) {
        guard current?.id == id else { return }
        let sheet = current
        current = nil
        sheet?.onDismiss()
    }
}

/// Base for the iOS versions of the tool window controllers.
class IOSToolWindowController: NSObject, ObservableObject {
    @Published var isVisible: Bool = false
    private lazy var sheetID = String(describing: type(of: self))

    func present<V: View>(title: String, @ViewBuilder _ content: () -> V) {
        let view = AnyView(content())
        ToolSheetPresenter.shared.present(id: sheetID, title: title, content: view) { [weak self] in
            self?.isVisible = false
            self?.didHide()
        }
        isVisible = true
    }

    func hide() {
        ToolSheetPresenter.shared.dismiss(id: sheetID)
        isVisible = false
    }

    /// Hook for subclasses that stop polling when their window closes.
    func didHide() {}
}

/// Hosts the presented tool sheet with a title bar and a Done button.
struct ToolSheetHost: View {
    let sheet: ToolSheetPresenter.Sheet

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                sheet.content
                    .padding(.bottom, 24)
            }
            .navigationTitle(sheet.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { ToolSheetPresenter.shared.dismiss(id: sheet.id) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
