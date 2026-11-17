import AppKit

// Keyboard navigation (⌃⌥0): move with the arrow keys or by typing a name,
// Return opens, Space shows the item's menu, Tab goes to the next dock, Esc leaves.
extension DockContentView {
    /// Cells reachable by keyboard: icons and the collapsed dock's expand button.
    var focusableViews: [NSView] {
        allCells.filter { $0 is DockItemCell || $0 is NSButton }
    }

    public func beginKeyboardFocus() {
        guard !focusableViews.isEmpty else { onKeyboardFocusEnded?(); return }
        keyboardIndex = 0
        typeBuffer = ""
        window?.makeFirstResponder(self)
        showKeyboardFocus()
    }

    func endKeyboardFocus(returnToApp: Bool) {
        guard keyboardIndex != nil else { return }
        keyboardIndex = nil
        focusableViews.forEach { ($0 as? DockItemCell)?.setKeyboardFocus(false) }
        HoverLabel.shared.hide()
        onKeyboardFocusEnded?()
        // Hand the keyboard back to whatever app was in front.
        if returnToApp { NSWorkspace.shared.frontmostApplication?.activate() }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard let index = keyboardIndex else { return false }
        let views = focusableViews
        guard !views.isEmpty else { endKeyboardFocus(returnToApp: true); return true }
        switch Int(event.keyCode) {
        case 123, 126: move(to: (index - 1 + views.count) % views.count)      // ← ↑
        case 124, 125: move(to: (index + 1) % views.count)                    // → ↓
        case 36, 76:                                                          // Return / Enter
            let view = views[min(index, views.count - 1)]
            endKeyboardFocus(returnToApp: false)
            if let cell = view as? DockItemCell { cell.onActivate?() } else { (view as? NSButton)?.performClick(nil) }
        case 49:                                                              // Space
            _ = (views[min(index, views.count - 1)] as? DockItemCell)?.accessibilityPerformShowMenu()
        case 48:                                                              // Tab
            endKeyboardFocus(returnToApp: false)
            onFocusNextDock?()
        case 53:                                                              // Esc
            endKeyboardFocus(returnToApp: true)
        default:
            // Type-select: jump to the next item whose name starts with what was typed.
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty,
                  chars.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " }) else { return false }
            if Date().timeIntervalSince(lastTypeTime) > 1 { typeBuffer = "" }
            typeBuffer += chars
            lastTypeTime = Date()
            let names = views.map { ($0 as? DockItemCell)?.displayName?.lowercased() ?? "" }
            if let hit = (0..<views.count).map({ (index + $0) % views.count }).first(where: { names[$0].hasPrefix(typeBuffer) }) {
                move(to: hit)
            } else {
                NSSound.beep()
            }
        }
        return true
    }

    private func move(to newIndex: Int) {
        keyboardIndex = newIndex
        showKeyboardFocus()
    }

    private func showKeyboardFocus() {
        guard let index = keyboardIndex else { return }
        for (i, view) in focusableViews.enumerated() {
            guard let cell = view as? DockItemCell else { continue }
            cell.setKeyboardFocus(i == index)
            if i == index, let name = cell.displayName {
                HoverLabel.shared.show(name, beside: cell, edge: edge)
                NSAccessibility.post(element: cell, notification: .announcementRequested,
                                     userInfo: [.announcement: name, .priority: NSAccessibilityPriorityLevel.high.rawValue])
            }
        }
    }
}
