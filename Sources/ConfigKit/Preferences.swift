import Foundation

/// Accessibility options applied to every Dock.
public struct AccessPrefs: Codable, Equatable, Sendable {
    /// Running-app indicator. Running vs. frontmost always differ by shape, not just colour.
    public enum Indicator: String, Codable, Sendable, CaseIterable { case dot, bar, ring, none }
    public var indicator: Indicator
    /// Open an icon by resting the cursor on it for `dwellDelay` seconds.
    public var dwellClick: Bool
    public var dwellDelay: Double
    /// Keep icons at least 64 px so they're easy to hit.
    public var bigTargets: Bool
    /// Bolder outlines and solid labels (also on automatically with macOS Increase Contrast).
    public var highContrast: Bool
    /// Hover-label font size in points.
    public var labelSize: Double
    /// Subtle sounds for launch, drop and remove.
    public var sounds: Bool
    /// Hover-label typeface: SF Pro, SF Pro Rounded, New York (serif) or SF Mono.
    public enum LabelFont: String, Codable, Sendable, CaseIterable { case system, rounded, serif, mono }
    public var labelFont: LabelFont
    /// Bold labels (always on in high contrast).
    public var labelBold: Bool

    public init() {
        indicator = .dot; dwellClick = false; dwellDelay = 1.2; bigTargets = false
        highContrast = false; labelSize = 13; sounds = false
        labelFont = .system; labelBold = false
    }

    private enum CodingKeys: String, CodingKey { case indicator, dwellClick, dwellDelay, bigTargets, highContrast, labelSize, sounds, labelFont, labelBold }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AccessPrefs()
        indicator = (try? c.decodeIfPresent(Indicator.self, forKey: .indicator)) ?? d.indicator
        dwellClick = try c.decodeIfPresent(Bool.self, forKey: .dwellClick) ?? d.dwellClick
        dwellDelay = min(max(try c.decodeIfPresent(Double.self, forKey: .dwellDelay) ?? d.dwellDelay, 0.4), 4)
        bigTargets = try c.decodeIfPresent(Bool.self, forKey: .bigTargets) ?? d.bigTargets
        highContrast = try c.decodeIfPresent(Bool.self, forKey: .highContrast) ?? d.highContrast
        labelSize = min(max(try c.decodeIfPresent(Double.self, forKey: .labelSize) ?? d.labelSize, 11), 24)
        sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        labelFont = (try? c.decodeIfPresent(LabelFont.self, forKey: .labelFont)) ?? d.labelFont
        labelBold = try c.decodeIfPresent(Bool.self, forKey: .labelBold) ?? d.labelBold
    }
}

/// Per-app preferences, shared by every Dock showing that app (keyed by bundle path).
public struct AppPrefs: Codable, Equatable, Sendable {
    /// Menu-bar commands pinned to the top of the app's Dock menu, as title paths
    /// (e.g. ["File", "Export", "Quick Export as PNG"]).
    public var pinnedActions: [[String]]
    /// Name shown in the hover label and to VoiceOver instead of the app's own.
    public var label: String?
    /// What a click on the icon does.
    public enum ClickAction: String, Codable, Sendable, CaseIterable {
        case open, summon, windowList, screenshot, hideOthers
        public var displayName: String {
            switch self {
            case .open:       return "Open / Switch To"
            case .summon:     return "Bring Windows to This Screen"
            case .windowList: return "Show Window List"
            case .screenshot: return "Screenshot Front Window"
            case .hideOthers: return "Open and Hide Others"
            }
        }
    }
    public var clickAction: ClickAction
    public var showBadge: Bool

    public init(pinnedActions: [[String]] = [], label: String? = nil,
                clickAction: ClickAction = .open, showBadge: Bool = true) {
        self.pinnedActions = pinnedActions
        self.label = label
        self.clickAction = clickAction
        self.showBadge = showBadge
    }

    private enum CodingKeys: String, CodingKey { case pinnedActions, label, clickAction, showBadge }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pinnedActions = try c.decodeIfPresent([[String]].self, forKey: .pinnedActions) ?? []
        label = try c.decodeIfPresent(String.self, forKey: .label)
        clickAction = (try? c.decodeIfPresent(ClickAction.self, forKey: .clickAction)) ?? .open
        showBadge = try c.decodeIfPresent(Bool.self, forKey: .showBadge) ?? true
    }
}
