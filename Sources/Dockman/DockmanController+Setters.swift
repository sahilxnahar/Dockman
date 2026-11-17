import Foundation
import ConfigKit

// One-line per-dock setters used by Settings and the menu bar (each saves and re-pins).
extension DockmanController {
    func setFocusModes(_ id: UUID, _ names: [String]) { mutate(id) { $0.focusModes = names } }
    func setRevealDelay(_ id: UUID, _ s: Double) { mutate(id) { $0.behavior.revealDelay = s } }
    func setCollapsed(_ id: UUID, _ on: Bool) { mutate(id) { $0.behavior.collapsed = on } }
    func setAlignment(_ id: UUID, _ a: Appearance.Alignment) { mutate(id) { $0.appearance.alignment = a } }
    func setHoverEffect(_ id: UUID, _ e: Appearance.HoverEffect) { mutate(id) { $0.appearance.hoverEffect = e } }
    func setLaunchEffect(_ id: UUID, _ e: Appearance.LaunchEffect) { mutate(id) { $0.appearance.launchEffect = e } }
    func setMotionSpeed(_ id: UUID, _ s: Double) { mutate(id) { $0.appearance.motionSpeed = s } }
    func setRows(_ id: UUID, _ n: Int) { mutate(id) { $0.appearance.rows = min(max(n, 1), 4) } }
    func setLocked(_ id: UUID, _ on: Bool) { mutate(id) { $0.appearance.locked = on } }
    func setFloating(_ id: UUID, _ on: Bool) { mutate(id) { $0.appearance.floating = on } }
    func setBinding(_ id: UUID, _ binding: Binding) { mutate(id) { $0.binding = binding } }
    func setDockAllSpaces(_ id: UUID) { mutate(id) { $0.binding = .allSpaces } }
    func setEnabled(_ id: UUID, _ on: Bool) { mutate(id) { $0.enabled = on } }
    func setAutoHide(_ id: UUID, _ on: Bool) { mutate(id) { $0.behavior.autoHide = on } }
    func setShowOverFullscreen(_ id: UUID, _ on: Bool) { mutate(id) { $0.behavior.showOverFullscreen = on } }
    func setIconSize(_ id: UUID, _ size: Double) { mutate(id) { $0.appearance.iconSize = size } }
    func setEdge(_ id: UUID, _ edge: Appearance.Edge) { mutate(id) { $0.appearance.edge = edge } }
    func setStyle(_ id: UUID, _ style: Appearance.Style) { mutate(id) { $0.appearance.style = style } }
    func setTint(_ id: UUID, _ hex: String?) { mutate(id) { $0.appearance.tintHex = hex } }
    func setMagnification(_ id: UUID, _ on: Bool) { mutate(id) { $0.appearance.magnification = on } }
    func setMagnificationScale(_ id: UUID, _ scale: Double) { mutate(id) { $0.appearance.magnificationScale = scale } }
    func setPadding(_ id: UUID, _ points: Double) { mutate(id) { $0.appearance.padding = points } }
    func setEdgeGap(_ id: UUID, _ points: Double) { mutate(id) { $0.appearance.edgeGap = points } }
    func setCornerRadius(_ id: UUID, _ r: Double) { mutate(id) { $0.appearance.cornerRadius = r } }
    func setBackgroundOpacity(_ id: UUID, _ o: Double) { mutate(id) { $0.appearance.backgroundOpacity = o } }
}
