import UIKit
import Combine

/// Everything a keyboard shortcut can do.
enum TermAction: String, Codable, CaseIterable {
    case newTab, closePane, closeTab, nextTab, previousTab, selectTab, moveTabLeft, moveTabRight
    case splitVertical, splitHorizontal, focusPane, nextPane, previousPane, toggleMaximizePane, moveDivider
    case copy, paste, selectAll, clearBuffer, resetTerminal, reconnect
    case fontBigger, fontSmaller, fontReset
    case scrollLineUp, scrollLineDown, scrollPageUp, scrollPageDown, scrollTop, scrollBottom
    case toggleChrome, openSettings
    case sendText, sendBytes

    var title: String {
        switch self {
        case .newTab: return "New Tab"
        case .closePane: return "Close Pane (tab when last)"
        case .closeTab: return "Close Tab"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .selectTab: return "Select Tab"
        case .moveTabLeft: return "Move Tab Left"
        case .moveTabRight: return "Move Tab Right"
        case .splitVertical: return "Split Vertically (side by side)"
        case .splitHorizontal: return "Split Horizontally (stacked)"
        case .focusPane: return "Focus Pane"
        case .nextPane: return "Next Pane"
        case .previousPane: return "Previous Pane"
        case .toggleMaximizePane: return "Maximize / Restore Pane"
        case .moveDivider: return "Move Divider"
        case .copy: return "Copy"
        case .paste: return "Paste"
        case .selectAll: return "Select All"
        case .clearBuffer: return "Clear Buffer"
        case .resetTerminal: return "Reset Terminal"
        case .reconnect: return "Reconnect"
        case .fontBigger: return "Make Text Bigger"
        case .fontSmaller: return "Make Text Smaller"
        case .fontReset: return "Make Text Normal Size"
        case .scrollLineUp: return "Scroll One Line Up"
        case .scrollLineDown: return "Scroll One Line Down"
        case .scrollPageUp: return "Scroll One Page Up"
        case .scrollPageDown: return "Scroll One Page Down"
        case .scrollTop: return "Scroll to Top"
        case .scrollBottom: return "Scroll to Bottom"
        case .toggleChrome: return "Hide / Show Tab and Status Bars"
        case .openSettings: return "Settings"
        case .sendText: return "Send Text"
        case .sendBytes: return "Send Bytes (hex)"
        }
    }

    var group: String {
        switch self {
        case .newTab, .closePane, .closeTab, .nextTab, .previousTab, .selectTab, .moveTabLeft, .moveTabRight: return "Tabs"
        case .splitVertical, .splitHorizontal, .focusPane, .nextPane, .previousPane, .toggleMaximizePane, .moveDivider: return "Panes"
        case .copy, .paste, .selectAll, .clearBuffer, .resetTerminal, .reconnect: return "Session"
        case .fontBigger, .fontSmaller, .fontReset, .toggleChrome, .openSettings: return "View"
        case .scrollLineUp, .scrollLineDown, .scrollPageUp, .scrollPageDown, .scrollTop, .scrollBottom: return "Scrolling"
        case .sendText, .sendBytes: return "Keys"
        }
    }
}

struct KeyBinding: Codable, Equatable {
    /// e.g. "cmd+shift+d", "ctrl+tab", "alt+left". Modifiers: cmd, shift, alt (option), ctrl.
    var keys: String
    var action: TermAction
    var arg: String?

    init(_ keys: String, _ action: TermAction, _ arg: String? = nil) {
        self.keys = keys
        self.action = action
        self.arg = arg
    }

    var displayKeys: String { Chord.parse(keys)?.display ?? keys }
}

struct KeymapFile: Codable {
    var version = 1
    /// "esc+" sends Option-letter as ESC letter (Meta); "normal" types the special character.
    var leftOption = "esc+"
    var rightOption = "normal"
    var bindings: [KeyBinding]
}

/// A parsed key chord in UIKeyCommand terms.
struct Chord: Equatable {
    var modifiers: UIKeyModifierFlags
    var input: String
    var keyName: String

    private static let specialKeys: [String: String] = [
        "left": UIKeyCommand.inputLeftArrow, "right": UIKeyCommand.inputRightArrow,
        "up": UIKeyCommand.inputUpArrow, "down": UIKeyCommand.inputDownArrow,
        "esc": UIKeyCommand.inputEscape, "escape": UIKeyCommand.inputEscape,
        "tab": "\t", "enter": "\r", "return": "\r", "space": " ",
        "backspace": "\u{8}", "delete": UIKeyCommand.inputDelete,
        "home": UIKeyCommand.inputHome, "end": UIKeyCommand.inputEnd,
        "pageup": UIKeyCommand.inputPageUp, "pagedown": UIKeyCommand.inputPageDown,
        "plus": "+", "minus": "-", "equals": "=", "comma": ",", "period": ".", "slash": "/",
        "backslash": "\\", "backtick": "`", "grave": "`", "semicolon": ";", "quote": "'",
        "lbracket": "[", "rbracket": "]",
        "f1": UIKeyCommand.f1, "f2": UIKeyCommand.f2, "f3": UIKeyCommand.f3, "f4": UIKeyCommand.f4,
        "f5": UIKeyCommand.f5, "f6": UIKeyCommand.f6, "f7": UIKeyCommand.f7, "f8": UIKeyCommand.f8,
        "f9": UIKeyCommand.f9, "f10": UIKeyCommand.f10, "f11": UIKeyCommand.f11, "f12": UIKeyCommand.f12,
    ]

    static func parse(_ text: String) -> Chord? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard var key = parts.last, !parts.isEmpty else { return nil }
        var flags: UIKeyModifierFlags = []
        var modifierTokens = Array(parts.dropLast())
        // "cmd++" (a literal plus key) comes through as ["cmd", "", ""].
        if key.isEmpty, modifierTokens.last == "" { key = "+"; modifierTokens.removeLast() }
        for m in modifierTokens {
            switch m {
            case "cmd", "command", "meta", "super": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "alt", "option", "opt": flags.insert(.alternate)
            case "ctrl", "control": flags.insert(.control)
            default: return nil
            }
        }
        let input = specialKeys[key] ?? key
        guard !input.isEmpty else { return nil }
        return Chord(modifiers: flags, input: input, keyName: key)
    }

    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.alternate) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        let names: [String: String] = [
            "left": "←", "right": "→", "up": "↑", "down": "↓", "esc": "⎋", "escape": "⎋", "tab": "⇥",
            "enter": "↩", "return": "↩", "space": "␣", "backspace": "⌫", "delete": "⌦", "home": "↖", "end": "↘",
            "pageup": "⇞", "pagedown": "⇟", "plus": "+", "minus": "−", "equals": "=",
        ]
        return s + (names[keyName] ?? keyName.uppercased())
    }
}

/// Shortcut bindings: iTerm2's defaults, overridable from the Shortcuts screen or by
/// editing Documents/keymap.json (visible in Files; reloaded when the app comes forward).
final class Keymap: ObservableObject {
    @Published private(set) var file: KeymapFile
    @Published private(set) var loadError: String?
    private var loadedModificationDate: Date?

    static var url: URL { AppFiles.documents.appendingPathComponent("keymap.json") }

    static let defaults: [KeyBinding] = {
        var b: [KeyBinding] = [
            KeyBinding("cmd+t", .newTab),
            KeyBinding("cmd+w", .closePane),
            KeyBinding("cmd+alt+w", .closeTab),
            KeyBinding("cmd+shift+]", .nextTab),
            KeyBinding("ctrl+tab", .nextTab),
            KeyBinding("cmd+shift+[", .previousTab),
            KeyBinding("ctrl+shift+tab", .previousTab),
            KeyBinding("cmd+shift+left", .moveTabLeft),
            KeyBinding("cmd+shift+right", .moveTabRight),
            KeyBinding("cmd+d", .splitVertical),
            KeyBinding("cmd+shift+d", .splitHorizontal),
            KeyBinding("cmd+alt+left", .focusPane, "left"),
            KeyBinding("cmd+alt+right", .focusPane, "right"),
            KeyBinding("cmd+alt+up", .focusPane, "up"),
            KeyBinding("cmd+alt+down", .focusPane, "down"),
            KeyBinding("cmd+]", .nextPane),
            KeyBinding("cmd+[", .previousPane),
            KeyBinding("cmd+shift+enter", .toggleMaximizePane),
            KeyBinding("ctrl+cmd+left", .moveDivider, "left"),
            KeyBinding("ctrl+cmd+right", .moveDivider, "right"),
            KeyBinding("ctrl+cmd+up", .moveDivider, "up"),
            KeyBinding("ctrl+cmd+down", .moveDivider, "down"),
            KeyBinding("cmd+c", .copy),
            KeyBinding("cmd+v", .paste),
            KeyBinding("cmd+a", .selectAll),
            KeyBinding("cmd+k", .clearBuffer),
            KeyBinding("cmd+r", .resetTerminal),
            KeyBinding("cmd+shift+r", .reconnect),
            KeyBinding("cmd+=", .fontBigger),
            KeyBinding("cmd+shift+=", .fontBigger),
            KeyBinding("cmd+-", .fontSmaller),
            KeyBinding("cmd+0", .fontReset),
            KeyBinding("cmd+up", .scrollLineUp),
            KeyBinding("cmd+down", .scrollLineDown),
            KeyBinding("cmd+pageup", .scrollPageUp),
            KeyBinding("cmd+pagedown", .scrollPageDown),
            KeyBinding("shift+pageup", .scrollPageUp),
            KeyBinding("shift+pagedown", .scrollPageDown),
            KeyBinding("cmd+home", .scrollTop),
            KeyBinding("cmd+end", .scrollBottom),
            KeyBinding("cmd+enter", .toggleChrome),
            KeyBinding("cmd+,", .openSettings),
            // iTerm2's default profile maps Option-arrows to word movement.
            KeyBinding("alt+left", .sendText, "\u{1b}b"),
            KeyBinding("alt+right", .sendText, "\u{1b}f"),
        ]
        for n in 1...9 { b.append(KeyBinding("cmd+\(n)", .selectTab, "\(n)")) }
        return b
    }()

    init() {
        file = KeymapFile(bindings: Keymap.defaults)
        load()
        if !FileManager.default.fileExists(atPath: Self.url.path) { save() }
    }

    var bindings: [KeyBinding] { file.bindings }

    var optionAsMeta: Bool {
        let v = file.leftOption.lowercased()
        return v.hasPrefix("esc") || v == "meta"
    }

    func load() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        do {
            file = try JSONDecoder().decode(KeymapFile.self, from: data)
            loadError = nil
        } catch {
            loadError = "keymap.json: \(error.localizedDescription)"
        }
        loadedModificationDate = modificationDate
    }

    /// Picks up an edit made in Files or over scp while the app was in the background.
    func reloadIfChanged() {
        guard modificationDate != loadedModificationDate else { return }
        load()
    }

    private var modificationDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: Self.url.path))?[.modificationDate] as? Date
    }

    func save() {
        AppFiles.writeJSON(file, to: Self.url)
        loadedModificationDate = modificationDate
    }

    func resetToDefaults() {
        file = KeymapFile(bindings: Keymap.defaults)
        save()
    }

    func rebind(_ index: Int, to keys: String?) {
        guard file.bindings.indices.contains(index) else { return }
        if let keys {
            file.bindings[index].keys = keys
        } else {
            file.bindings.remove(at: index)
        }
        save()
    }

    func binding(at index: Int) -> KeyBinding? {
        file.bindings.indices.contains(index) ? file.bindings[index] : nil
    }

    /// Every binding as a UIKeyCommand; `propertyList` carries the binding's index.
    func keyCommands(action: Selector) -> [UIKeyCommand] {
        var seen = Set<String>()
        var commands: [UIKeyCommand] = []
        for (i, binding) in file.bindings.enumerated() {
            guard let chord = Chord.parse(binding.keys) else { continue }
            let key = "\(chord.modifiers.rawValue):\(chord.input)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let command = UIKeyCommand(title: binding.action.title, image: nil, action: action,
                                       input: chord.input, modifierFlags: chord.modifiers, propertyList: i)
            command.wantsPriorityOverSystemBehavior = true
            commands.append(command)
        }
        return commands
    }

    /// Bindings that compete with the shell for ⌃ or ⌥ chords, flagged in the UI.
    static func stealsFromShell(_ binding: KeyBinding) -> Bool {
        guard let chord = Chord.parse(binding.keys) else { return false }
        return !chord.modifiers.contains(.command) && !chord.modifiers.intersection([.control, .alternate]).isEmpty
    }
}
