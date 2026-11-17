import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ConfigKit

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var controller: DockmanController

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Start at Login", isOn: Binding(
                    get: { controller.isLoginItemEnabled },
                    set: { _ in controller.toggleLaunchAtLogin() }))
            }
            Section("System Dock") {
                Toggle("Hide the built-in macOS Dock", isOn: Binding(
                    get: { controller.config.global.hideSystemDock },
                    set: { controller.setHideSystemDock($0) }))
                Text("Restored automatically when turned off.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accessibility") {
                let a = controller.config.global.access
                Picker("Running Indicator", selection: Binding(
                    get: { a.indicator }, set: { v in controller.setAccess { $0.indicator = v } })) {
                    Text("Dot").tag(AccessPrefs.Indicator.dot)
                    Text("Bar").tag(AccessPrefs.Indicator.bar)
                    Text("Ring").tag(AccessPrefs.Indicator.ring)
                    Text("None").tag(AccessPrefs.Indicator.none)
                }
                .help("Running and frontmost apps differ by shape, not only colour")
                Picker("Label Font", selection: Binding(
                    get: { a.labelFont }, set: { v in controller.setAccess { $0.labelFont = v } })) {
                    Text("SF Pro").tag(AccessPrefs.LabelFont.system)
                    Text("Rounded").tag(AccessPrefs.LabelFont.rounded)
                    Text("Serif").tag(AccessPrefs.LabelFont.serif)
                    Text("Mono").tag(AccessPrefs.LabelFont.mono)
                }
                .pickerStyle(.segmented)
                Toggle("Bold labels", isOn: Binding(
                    get: { a.labelBold }, set: { v in controller.setAccess { $0.labelBold = v } }))
                Toggle("High contrast", isOn: Binding(
                    get: { a.highContrast }, set: { v in controller.setAccess { $0.highContrast = v } }))
                    .help("Solid labels and outlined docks. Also on automatically with macOS Increase Contrast.")
                VStack(alignment: .leading) {
                    LabeledContent("Label Size", value: "\(Int(a.labelSize)) pt")
                    Slider(value: Binding(get: { a.labelSize }, set: { v in controller.setAccess { $0.labelSize = v } }),
                           in: 11...24, step: 1)
                }
                Toggle("Big targets (icons at least 64 px)", isOn: Binding(
                    get: { a.bigTargets }, set: { v in controller.setAccess { $0.bigTargets = v } }))
                Toggle("Sounds for launch, drop and remove", isOn: Binding(
                    get: { a.sounds }, set: { v in controller.setAccess { $0.sounds = v } }))
                Toggle("Dwell to click", isOn: Binding(
                    get: { a.dwellClick }, set: { v in controller.setAccess { $0.dwellClick = v } }))
                    .help("Open an icon by resting the pointer on it")
                if a.dwellClick {
                    VStack(alignment: .leading) {
                        LabeledContent("Dwell Time", value: String(format: "%.1f s", a.dwellDelay))
                        Slider(value: Binding(get: { a.dwellDelay }, set: { v in controller.setAccess { $0.dwellDelay = v } }),
                               in: 0.4...4, step: 0.1)
                    }
                }
            }
            Section("Keyboard") {
                LabeledContent("Navigate docks", value: "⌃⌥0, then ← → Return, Space for menu, Tab, Esc")
                LabeledContent("Search and launch", value: "⌃⌥Space")
                LabeledContent("Show/hide a dock", value: "⌃⌥1–9 (set per dock)")
            }
            Section("Docks") {
                Button("Add Dock on Current Desktop") { controller.newDockHere() }
                Button("Add Copy of the macOS Dock") { controller.newSystemDockCopy() }
                    .help("A dock that mirrors your built-in Dock. Choose which screens it appears on in its settings.")
                HStack {
                    Button("Export Docks…") { exportDocks() }
                    Button("Import Docks…") { importDocks() }
                }
                Text("Import replaces your current docks with the ones in the file.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: appVersion())
                LabeledContent("Scripting", value: "dockman://toggle?dock=Name")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func exportDocks() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Dockman Docks.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try controller.exportDocks(to: url) } catch { NSAlert(error: error).runModal() }
    }

    private func importDocks() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try controller.importDocks(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't import docks"
            alert.informativeText = "That file isn't a Dockman export. Your docks were not changed."
            alert.runModal()
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
