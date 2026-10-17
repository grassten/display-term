import UIKit
import SwiftTerm

/// A colour scheme in iTerm2's terms: 16 ANSI colours plus foreground, background, cursor
/// and selection. Loadable from an `.itermcolors` file dropped into Documents/Themes.
struct Theme: Equatable {
    var name: String
    var ansi: [UIColor]
    var foreground: UIColor
    var background: UIColor
    var cursor: UIColor
    var selection: UIColor
    var selectionText: UIColor?

    /// iTerm2's default profile colours ("Dark Background").
    static let darkBackground = Theme(
        name: "Dark Background",
        ansi: [
            UIColor(white: 0, alpha: 1), rgb(0.7333, 0, 0), rgb(0, 0.7333, 0), rgb(0.7333, 0.7333, 0),
            rgb(0, 0, 0.7333), rgb(0.7333, 0, 0.7333), rgb(0, 0.7333, 0.7333), rgb(0.7333, 0.7333, 0.7333),
            rgb(0.3333, 0.3333, 0.3333), rgb(1, 0.3333, 0.3333), rgb(0.3333, 1, 0.3333), rgb(1, 1, 0.3333),
            rgb(0.3333, 0.3333, 1), rgb(1, 0.3333, 1), rgb(0.3333, 1, 1), rgb(1, 1, 1),
        ],
        foreground: rgb(0.7333, 0.7333, 0.7333),
        background: .black,
        cursor: rgb(0.7333, 0.7333, 0.7333),
        selection: rgb(0.7098, 0.8353, 1),
        selectionText: .black
    )

    static let solarizedDark = Theme(
        name: "Solarized Dark",
        ansi: [
            hex(0x073642), hex(0xdc322f), hex(0x859900), hex(0xb58900), hex(0x268bd2), hex(0xd33682), hex(0x2aa198), hex(0xeee8d5),
            hex(0x002b36), hex(0xcb4b16), hex(0x586e75), hex(0x657b83), hex(0x839496), hex(0x6c71c4), hex(0x93a1a1), hex(0xfdf6e3),
        ],
        foreground: hex(0x839496), background: hex(0x002b36), cursor: hex(0x839496), selection: hex(0x073642), selectionText: nil
    )

    static let bundled: [Theme] = [darkBackground, solarizedDark]

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func hex(_ v: UInt32) -> UIColor {
        rgb(CGFloat((v >> 16) & 0xff) / 255, CGFloat((v >> 8) & 0xff) / 255, CGFloat(v & 0xff) / 255)
    }

    /// Parse an iTerm2 `.itermcolors` plist.
    static func load(itermcolors url: URL) -> Theme? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        func color(_ key: String) -> UIColor? {
            guard let d = plist[key] as? [String: Any] else { return nil }
            func c(_ k: String) -> CGFloat { CGFloat((d[k] as? NSNumber)?.doubleValue ?? 0) }
            return UIColor(red: c("Red Component"), green: c("Green Component"), blue: c("Blue Component"), alpha: 1)
        }
        var ansi: [UIColor] = []
        for i in 0..<16 {
            guard let c = color("Ansi \(i) Color") else { return nil }
            ansi.append(c)
        }
        guard let fg = color("Foreground Color"), let bg = color("Background Color") else { return nil }
        return Theme(name: url.deletingPathExtension().lastPathComponent,
                     ansi: ansi, foreground: fg, background: bg,
                     cursor: color("Cursor Color") ?? fg,
                     selection: color("Selection Color") ?? fg.withAlphaComponent(0.3),
                     selectionText: color("Selected Text Color"))
    }

    func apply(to view: TerminalView) {
        view.installColors(ansi.map(Theme.terminalColor))
        view.nativeForegroundColor = foreground
        view.nativeBackgroundColor = background
        view.caretColor = cursor
        view.selectedTextBackgroundColor = selection
        if let selectionText { view.selectedTextForegroundColor = selectionText }
        view.backgroundColor = background
    }

    static func terminalColor(_ color: UIColor) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        func u(_ v: CGFloat) -> UInt16 { UInt16(max(0, min(1, v)) * 65535) }
        return Color(red: u(r), green: u(g), blue: u(b))
    }
}

final class ThemeStore: ObservableObject {
    @Published private(set) var themes: [Theme] = Theme.bundled

    init() { reload() }

    func reload() {
        var list = Theme.bundled
        let files = (try? FileManager.default.contentsOfDirectory(at: AppFiles.themesDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "itermcolors" {
            if let theme = Theme.load(itermcolors: url), !list.contains(where: { $0.name == theme.name }) {
                list.append(theme)
            }
        }
        if list != themes { themes = list }
    }

    func theme(named name: String) -> Theme {
        themes.first { $0.name == name } ?? .darkBackground
    }
}

/// The bundled JetBrains Mono Nerd Font (Mono variant), falling back to the system
/// monospaced face if the bundle is ever missing it.
enum TerminalFont {
    static func set(_ view: TerminalView, size: CGFloat) {
        func face(_ name: String, weight: UIFont.Weight) -> UIFont {
            UIFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        }
        view.setFonts(normal: face("JetBrainsMonoNFM-Regular", weight: .regular),
                      bold: face("JetBrainsMonoNFM-Bold", weight: .bold),
                      italic: face("JetBrainsMonoNFM-Italic", weight: .regular),
                      boldItalic: face("JetBrainsMonoNFM-BoldItalic", weight: .bold))
    }
}
