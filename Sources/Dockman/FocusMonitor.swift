import Foundation

/// Which Focus modes are on, read from the Focus database macOS keeps in
/// ~/Library/DoNotDisturb/DB (there is no public API for this). Event-driven: a
/// directory watcher fires when macOS rewrites the files; nothing polls.
///
/// shortcut: sees Focus modes switched on by hand (assertion records); scheduled or
/// location-triggered Focus doesn't write those, so it isn't detected. Upgrade if
/// Apple ships a public Focus-status API for unsigned agents.
final class FocusMonitor {
    var onChange: (() -> Void)?
    private(set) var activeModeNames: Set<String> = []
    private var source: DispatchSourceFileSystemObject?
    private let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/DoNotDisturb/DB")

    /// All Focus mode names defined on this Mac ("Work", "Personal", …); empty if unreadable.
    func modeNames() -> [String] {
        modeIDsToNames().values.sorted()
    }

    func start() {
        guard source == nil else { return }
        activeModeNames = readActive()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.readActive()
            if now != self.activeModeNames { self.activeModeNames = now; self.onChange?() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() { source?.cancel(); source = nil }

    private func json(_ name: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (obj["data"] as? [[String: Any]])?.first else { return nil }
        return first
    }

    private func modeIDsToNames() -> [String: String] {
        guard let configs = json("ModeConfigurations.json")?["modeConfigurations"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (id, value) in configs {
            if let mode = (value as? [String: Any])?["mode"] as? [String: Any], let name = mode["name"] as? String {
                out[id] = name
            }
        }
        return out
    }

    private func readActive() -> Set<String> {
        guard let records = json("Assertions.json")?["storeAssertionRecords"] as? [[String: Any]] else { return [] }
        let names = modeIDsToNames()
        return Set(records.compactMap {
            (($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String).flatMap { names[$0] }
        })
    }
}
