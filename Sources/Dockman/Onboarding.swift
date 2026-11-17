import AppKit
import SwiftUI

/// First-run welcome guide: what Dockman does and the handful of gestures that matter.
/// Shown once automatically; reopen from the menu bar ▸ Welcome Guide.
private struct WelcomeView: View {
    let openSettings: () -> Void
    let close: () -> Void

    private let steps: [(String, String, String)] = [
        ("rectangle.stack", "Extra docks, per desktop",
         "Each dock can live on one desktop, several, or all of them, on any screen and any edge — or float anywhere."),
        ("plus.square.on.square", "Add things by dragging",
         "Drop apps, files or folders from Finder onto a dock. Drag icons to reorder them; drag one onto the Trash widget to remove it."),
        ("cursorarrow.click.2", "Right-click for more",
         "Hide or quit apps, change an icon, add separators, or collapse the dock to a small button."),
        ("square.grid.2x2", "Widgets",
         "Settings ▸ Items ▸ Add Item adds a Clock, Battery, Shelf (park files), Recent Items or Trash."),
        ("keyboard", "Shortcuts and Focus",
         "Give a dock a ⌃⌥1–9 shortcut, or show it only during a Focus mode like Work."),
        ("lock.shield", "Optional permission",
         "Accessibility access is only needed for notification badges and moving windows to a dock's screen."),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Dockman").font(.largeTitle.bold())
            ForEach(steps, id: \.1) { symbol, title, detail in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline)
                        Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Spacer()
                Button("Open Settings") { openSettings(); close() }
                Button("Get Started") { close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

final class WelcomeWindowController {
    private var window: NSWindow?

    func show(openSettings: @escaping () -> Void) {
        if window == nil {
            let view = WelcomeView(openSettings: openSettings, close: { [weak self] in self?.window?.close() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Welcome to Dockman"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
