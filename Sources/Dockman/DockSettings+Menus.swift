import AppKit
import SwiftUI
import ConfigKit

// Focus-mode and app-trigger pickers for the per-dock Settings pane.
extension DockSettingsView {
    /// "Show only during Focus": pick any Focus modes; none = always shown.
    @ViewBuilder func focusMenu(_ dock: DockModel) -> some View {
        let modes = controller.focus.modeNames()
        LabeledContent("Show During Focus") {
            Menu(dock.focusModes.isEmpty ? "Always" : dock.focusModes.joined(separator: ", ")) {
                Button("Always (any Focus)") { controller.setFocusModes(dockID, []) }
                if !modes.isEmpty { Divider() }
                ForEach(modes, id: \.self) { name in
                    Button((dock.focusModes.contains(name) ? "✓ " : "") + name) {
                        var set = dock.focusModes
                        if let i = set.firstIndex(of: name) { set.remove(at: i) } else { set.append(name) }
                        controller.setFocusModes(dockID, set)
                    }
                }
            }
            .fixedSize()
            .disabled(modes.isEmpty)
            .help(modes.isEmpty ? "Dockman can't read your Focus modes (Full Disk Access may be needed)"
                                : "Show this dock only while one of these Focus modes is on")
        }
    }

    /// "Show While App Is Active": the dock appears only while one of these apps is in front.
    @ViewBuilder func appTriggerMenu(_ dock: DockModel) -> some View {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { $0.bundleURL?.path }
        let choices = Array(Set(running + dock.showForApps + dock.items.compactMap(\.appPath))).sorted {
            appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending
        }
        LabeledContent("Show While App Is Active") {
            Menu(dock.showForApps.isEmpty ? "Always" : dock.showForApps.map(appName).joined(separator: ", ")) {
                Button("Always (any app)") { controller.setShowForApps(dockID, []) }
                Divider()
                ForEach(choices, id: \.self) { path in
                    Button((dock.showForApps.contains(path) ? "✓ " : "") + appName(path)) {
                        var list = dock.showForApps
                        if let i = list.firstIndex(of: path) { list.remove(at: i) } else { list.append(path) }
                        controller.setShowForApps(dockID, list)
                    }
                }
            }
            .fixedSize()
            .help("e.g. a Photoshop toolbox dock that appears only while Photoshop is in front")
        }
    }

    func appName(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
