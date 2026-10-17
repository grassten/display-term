import UIKit
import Combine

/// Process-wide state shared by the phone scene and the display scene: whether a display is
/// attached, the pointer, the stores, and the workspace of tabs and panes.
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var displayAttached = false
    @Published private(set) var displayScreen: UIScreen?
    @Published var statusMessage = ""
    /// ⌘↩: hide the tab bar and status bar on the display.
    @Published var chromeHidden = false

    let pointer = PointerController()
    let preferences = Preferences()
    let profiles = ProfileStore()
    let keymap = Keymap()
    let themes = ThemeStore()
    private(set) lazy var workspace = Workspace(state: self)

    private init() {}

    func displayDidConnect(screen: UIScreen) {
        displayScreen = screen
        displayAttached = true
        UIApplication.shared.isIdleTimerDisabled = true
        statusMessage = "Display \(Int(screen.bounds.width))x\(Int(screen.bounds.height)) @\(screen.scale)x"
    }

    func displayDidDisconnect() {
        displayAttached = false
        displayScreen = nil
        UIApplication.shared.isIdleTimerDisabled = false
        statusMessage = "Display disconnected"
    }

    func keepPhoneAwakeIfDocked() {
        guard displayAttached else { return }
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func phoneSceneBecameActive() {
        keepPhoneAwakeIfDocked()
        keymap.reloadIfChanged()
        themes.reload()
        workspace.resumeAfterForeground()
    }
}

/// Small user-facing settings, UserDefaults-backed.
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Terminal font size on the external display, in points (= pixels at scale 1).
    @Published var displayFontSize: CGFloat { didSet { defaults.set(displayFontSize, forKey: "displayFontSize") } }
    /// Terminal font size on the phone.
    @Published var phoneFontSize: CGFloat { didSet { defaults.set(phoneFontSize, forKey: "phoneFontSize") } }
    @Published var themeName: String { didSet { defaults.set(themeName, forKey: "themeName") } }
    /// How much inactive split panes are dimmed (iTerm2 default 0.4).
    @Published var dimInactivePanes: Double { didSet { defaults.set(dimInactivePanes, forKey: "dimInactivePanes") } }
    @Published var showKeyHints: Bool { didSet { defaults.set(showKeyHints, forKey: "showKeyHints") } }
    @Published var showPaneTitles: Bool { didSet { defaults.set(showPaneTitles, forKey: "showPaneTitles") } }
    @Published var showStatusBar: Bool { didSet { defaults.set(showStatusBar, forKey: "showStatusBar") } }

    static let defaultDisplayFontSize: CGFloat = 20
    static let defaultPhoneFontSize: CGFloat = 13

    init() {
        let d = UserDefaults.standard
        displayFontSize = d.object(forKey: "displayFontSize") as? CGFloat ?? Self.defaultDisplayFontSize
        phoneFontSize = d.object(forKey: "phoneFontSize") as? CGFloat ?? Self.defaultPhoneFontSize
        themeName = d.string(forKey: "themeName") ?? Theme.darkBackground.name
        dimInactivePanes = d.object(forKey: "dimInactivePanes") as? Double ?? 0.4
        showKeyHints = d.object(forKey: "showKeyHints") as? Bool ?? true
        showPaneTitles = d.object(forKey: "showPaneTitles") as? Bool ?? false
        showStatusBar = d.object(forKey: "showStatusBar") as? Bool ?? false
    }
}

/// Where the app keeps its files. Documents is visible in the Files app (keymap.json,
/// Themes/); Application Support is not (profiles, known hosts, layout).
enum AppFiles {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var applicationSupport: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var themesDirectory: URL {
        let url = documents.appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func readJSON<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func writeJSON<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
