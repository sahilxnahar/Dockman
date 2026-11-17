import AppKit
import ConfigKit

/// The single floating name label shown above (or beside) the hovered icon, like the
/// system Dock's. One shared panel, placed on the inward side of whichever edge the
/// Dock sits on, so it never runs off the screen.
@MainActor
final class HoverLabel {
    static let shared = HoverLabel()

    private let panel: NSPanel
    private let field = NSTextField(labelWithString: "")
    private weak var owner: NSView?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.layer?.masksToBounds = true
        field.textColor = .labelColor
        field.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
        panel.contentView = bg
    }

    func show(_ text: String, beside view: NSView, edge: Appearance.Edge) {
        guard let window = view.window else { return }
        owner = view
        let pt = CGFloat(DockAccess.prefs.labelSize)
        field.font = Self.labelFont(size: pt)
        field.stringValue = text
        if let bg = panel.contentView as? NSVisualEffectView {
            // High contrast: an opaque label with a clear outline instead of translucency.
            bg.state = DockAccess.highContrast ? .inactive : .active
            bg.layer?.backgroundColor = DockAccess.highContrast ? NSColor.windowBackgroundColor.cgColor : nil
            bg.layer?.borderWidth = DockAccess.highContrast ? 1.5 : 0
            bg.layer?.borderColor = NSColor.labelColor.cgColor
        }
        field.lineBreakMode = .byTruncatingTail          // very long names end in "…"
        let size = NSSize(width: min(ceil(field.intrinsicContentSize.width) + 20, 420), height: ceil(pt * 1.85))
        let r = window.convertToScreen(view.convert(view.bounds, to: nil))
        let gap: CGFloat = 8
        var origin: NSPoint
        switch edge {
        case .bottom: origin = NSPoint(x: r.midX - size.width / 2, y: r.maxY + gap)
        case .top:    origin = NSPoint(x: r.midX - size.width / 2, y: r.minY - gap - size.height)
        case .left:   origin = NSPoint(x: r.maxX + gap, y: r.midY + DockItemCell.dotZone / 2 - size.height / 2)
        case .right:  origin = NSPoint(x: r.minX - gap - size.width, y: r.midY + DockItemCell.dotZone / 2 - size.height / 2)
        }
        // Keep the label on the Dock's screen.
        if let screen = window.screen?.frame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            origin.y = min(max(origin.y, screen.minY + 4), screen.maxY - size.height - 4)
        }
        let wasVisible = panel.isVisible
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if wasVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1                       // moving between icons: switch instantly
        } else {
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
        panel.orderFrontRegardless()
    }

    /// The user's label typeface (Settings ▸ General ▸ Accessibility), bold in high contrast.
    static func labelFont(size: CGFloat) -> NSFont {
        let bold = DockAccess.prefs.labelBold || DockAccess.highContrast
        let base = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .medium)
        let design: NSFontDescriptor.SystemDesign
        switch DockAccess.prefs.labelFont {
        case .system:  return base
        case .rounded: design = .rounded
        case .serif:   design = .serif
        case .mono:    design = .monospaced
        }
        return base.fontDescriptor.withDesign(design).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }

    func hide(ifOwnedBy view: NSView? = nil) {
        if let view, owner !== view { return }
        owner = nil
        // Short grace period so sliding to the next icon swaps the text without a re-fade.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
            if owner == nil { panel.orderOut(nil) }
        }
    }
}
