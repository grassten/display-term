import SwiftUI
import UIKit

/// Settings: hosts, appearance, shortcuts, the device key.
struct SettingsRoot: View {
    @ObservedObject var profiles: ProfileStore
    @ObservedObject var preferences: Preferences
    @ObservedObject var keymap: Keymap
    @ObservedObject var themes: ThemeStore
    let onConnect: (Profile) -> Void
    let onDone: () -> Void
    @StateObject private var browser = HostBrowser()

    var body: some View {
        NavigationStack {
            Form {
                Section("Hosts") {
                    ForEach(profiles.profiles) { profile in
                        NavigationLink {
                            ProfileEditor(profile: profile, browser: browser, profiles: profiles, onConnect: onConnect)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(profile.name)
                                    Text("\(profile.user)@\(profile.hostDisplay)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == profiles.defaultID { Text("default").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    .onDelete { offsets in offsets.map { profiles.profiles[$0] }.forEach(profiles.remove) }
                    NavigationLink("Add host…") {
                        ProfileEditor(profile: nil, browser: browser, profiles: profiles, onConnect: onConnect)
                    }
                }
                Section("Appearance") {
                    Picker("Theme", selection: $preferences.themeName) {
                        ForEach(themes.themes, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Stepper("Display font: \(Int(preferences.displayFontSize)) px", value: $preferences.displayFontSize, in: 8...64)
                    Stepper("Phone font: \(Int(preferences.phoneFontSize)) pt", value: $preferences.phoneFontSize, in: 8...32)
                    VStack(alignment: .leading) {
                        Text("Dim inactive panes: \(Int(preferences.dimInactivePanes * 100))%")
                        Slider(value: $preferences.dimInactivePanes, in: 0...0.8)
                    }
                    Toggle("Pane title bars", isOn: $preferences.showPaneTitles)
                    Toggle("Status bar", isOn: $preferences.showStatusBar)
                    Toggle("Shortcut hints in the status bar", isOn: $preferences.showKeyHints)
                        .disabled(!preferences.showStatusBar)
                    Text("Drop .itermcolors files into Files › On My iPhone › Display Term › Themes.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Keyboard") {
                    NavigationLink("Shortcuts (\(keymap.bindings.count))") { ShortcutsView(keymap: keymap) }
                    Text("Left Option: \(keymap.file.leftOption). Change it in keymap.json.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Device key") {
                    if let line = DeviceKey.publicKeyLine() {
                        Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        Button("Copy public key") { UIPasteboard.general.string = line }
                        Text("Added to ~/.ssh/authorized_keys on the Mac after the first password login. \(DeviceKey.fingerprint ?? "")")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("No key available (Keychain error).").foregroundStyle(.red)
                    }
                }
                Section("Known hosts") {
                    let hosts = HostKeyStore.shared.all
                    if hosts.isEmpty { Text("None yet.").foregroundStyle(.secondary) }
                    ForEach(hosts, id: \.hostID) { item in
                        VStack(alignment: .leading) {
                            Text(item.hostID)
                            Text(item.entry.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onDone) } }
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }
}

/// Add or edit a host. Also the first-run screen.
struct ProfileEditor: View {
    let original: Profile?
    @ObservedObject var browser: HostBrowser
    @ObservedObject var profiles: ProfileStore
    let onConnect: (Profile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var user: String
    @State private var useBonjour: Bool
    @State private var bonjourName: String
    @State private var address: String
    @State private var port: String
    @State private var tmux: Bool
    @State private var connectOnLaunch: Bool
    @State private var makeDefault: Bool

    init(profile: Profile?, browser: HostBrowser, profiles: ProfileStore, onConnect: @escaping (Profile) -> Void) {
        original = profile
        self.browser = browser
        self.profiles = profiles
        self.onConnect = onConnect
        _name = State(initialValue: profile?.name ?? "")
        _user = State(initialValue: profile?.user ?? "")
        var bonjour = true, service = "", host = "", portText = "22"
        if let profile {
            switch profile.host {
            case .bonjour(let n): service = n
            case .address(let h, let p): bonjour = false; host = h; portText = "\(p)"
            }
        }
        _useBonjour = State(initialValue: bonjour)
        _bonjourName = State(initialValue: service)
        _address = State(initialValue: host)
        _port = State(initialValue: portText)
        _tmux = State(initialValue: profile?.tmux ?? true)
        _connectOnLaunch = State(initialValue: profile?.connectOnLaunch ?? true)
        _makeDefault = State(initialValue: profile == nil ? profiles.profiles.isEmpty : profiles.defaultID == profile?.id)
    }

    private var valid: Bool {
        !user.isEmpty && (useBonjour ? !bonjourName.isEmpty : !address.isEmpty)
    }

    var body: some View {
        Form {
            Section("Mac") {
                Toggle("Find on the network (Bonjour)", isOn: $useBonjour)
                if useBonjour {
                    if browser.hosts.isEmpty {
                        Text(browser.status).font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(browser.hosts) { host in
                        Button {
                            bonjourName = host.name
                            if name.isEmpty { name = host.name }
                        } label: {
                            HStack {
                                Text(host.name)
                                Spacer()
                                if host.name == bonjourName { Image(systemName: "checkmark") }
                            }
                        }
                        .tint(.primary)
                    }
                    TextField("Service name (as shown above)", text: $bonjourName)
                } else {
                    TextField("Host name or IP", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                }
                TextField("User (your macOS short name)", text: $user)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Profile name", text: $name)
            }
            Section("Session") {
                Toggle("Keep shells alive with tmux", isOn: $tmux)
                Text("Each pane runs `tmux new-session -A -s dt-<n>`, so a dropped connection reattaches to the same shell. Needs tmux on the Mac (brew install tmux); falls back to a plain shell if missing.")
                    .font(.footnote).foregroundStyle(.secondary)
                Toggle("Connect when the app opens", isOn: $connectOnLaunch)
                Toggle("Default host", isOn: $makeDefault)
            }
            Section {
                Button("Save & Connect") { save(connect: true) }.disabled(!valid)
                Button("Save") { save(connect: false) }.disabled(!valid)
            }
            if let original {
                Section {
                    Button("Forget host key for \(original.hostDisplay)", role: .destructive) {
                        HostKeyStore.shared.forget(hostID: original.hostID)
                    }
                    Text("First connection: the Mac's host-key fingerprint is shown to trust. Then one password login installs this phone's key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text("Remote Login must be on: System Settings › General › Sharing › Remote Login. First connection shows the Mac's host-key fingerprint to trust, then asks your password once to install this phone's key.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(original == nil ? "Connect to a Mac" : "Edit Host")
        .onAppear { browser.start() }
    }

    private func save(connect: Bool) {
        let host: Profile.Host = useBonjour ? .bonjour(bonjourName) : .address(address, Int(port) ?? 22)
        var profile = original ?? Profile(name: "", host: host, user: user)
        profile.name = name.isEmpty ? (useBonjour ? bonjourName : address) : name
        profile.host = host
        profile.user = user
        profile.tmux = tmux
        profile.connectOnLaunch = connectOnLaunch
        profiles.upsert(profile)
        if makeDefault { profiles.defaultID = profile.id }
        if connect || original == nil && profiles.profiles.count == 1 { onConnect(profile) } else { dismiss() }
    }
}

struct ShortcutsView: View {
    @ObservedObject var keymap: Keymap
    @State private var recording: RecordingTarget?

    private struct RecordingTarget: Identifiable {
        let index: Int
        var id: Int { index }
    }

    private var groups: [String] {
        var seen: [String] = []
        for b in keymap.bindings where !seen.contains(b.action.group) { seen.append(b.action.group) }
        return seen
    }

    var body: some View {
        List {
            if let error = keymap.loadError {
                Section { Text(error).foregroundStyle(.red) }
            }
            ForEach(groups, id: \.self) { group in
                Section(group) {
                    ForEach(Array(keymap.bindings.enumerated()).filter { $0.element.action.group == group }, id: \.offset) { item in
                        Button { recording = RecordingTarget(index: item.offset) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.element.action.title + (item.element.arg.map { " · \(Self.describe($0))" } ?? ""))
                                    if Keymap.stealsFromShell(item.element) {
                                        Text("Taken from the shell, as in iTerm2").font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                                Spacer()
                                Text(item.element.displayKeys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        .tint(.primary)
                    }
                }
            }
            Section {
                Button("Reset to iTerm2 defaults", role: .destructive) { keymap.resetToDefaults() }
                Text("Same data as Files › On My iPhone › Display Term › keymap.json. Edits there apply when the app comes back to the foreground. iOS keeps ⌘H, ⌘Space and ⌘Tab for itself.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shortcuts")
        .sheet(item: $recording) { target in
            if let binding = keymap.binding(at: target.index) {
                RebindSheet(binding: binding) { result in
                    switch result {
                    case .keep: break
                    case .remove: keymap.rebind(target.index, to: nil)
                    case .set(let keys): keymap.rebind(target.index, to: keys)
                    }
                    recording = nil
                }
            }
        }
    }

    private static func describe(_ arg: String) -> String {
        arg.unicodeScalars.map { $0 == "\u{1b}" ? "ESC " : String($0) }.joined()
    }
}

struct RebindSheet: View {
    enum Result { case keep, remove, set(String) }
    let binding: KeyBinding
    let onResult: (Result) -> Void
    @State private var captured: String?

    var body: some View {
        VStack(spacing: 18) {
            Text("Press the new shortcut for").foregroundStyle(.secondary)
            Text(binding.action.title).font(.title3.bold())
            KeyCapture { captured = $0 }
                .frame(width: 1, height: 1)
            Text(captured.map { Chord.parse($0)?.display ?? $0 } ?? binding.displayKeys)
                .font(.system(size: 34, design: .monospaced))
                .padding(.vertical, 10)
            Text("Needs the hardware keyboard. Shortcuts are stored as text like `cmd+shift+d`.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Cancel") { onResult(.keep) }
                Spacer()
                Button("Remove", role: .destructive) { onResult(.remove) }
                Spacer()
                Button("Save") { if let captured { onResult(.set(captured)) } }
                    .disabled(captured == nil)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

/// An invisible first responder that turns one hardware key press into a chord string.
struct KeyCapture: UIViewRepresentable {
    let onChord: (String) -> Void

    func makeUIView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onChord = onChord
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: KeyCaptureView, context: Context) {
        uiView.onChord = onChord
    }
}

final class KeyCaptureView: UIView, UIKeyInput {
    var onChord: ((String) -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { false }
    func insertText(_ text: String) {}
    func deleteBackward() {}

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, let name = Self.keyName(key) else { continue }
            var parts: [String] = []
            if key.modifierFlags.contains(.control) { parts.append("ctrl") }
            if key.modifierFlags.contains(.alternate) { parts.append("alt") }
            if key.modifierFlags.contains(.shift) { parts.append("shift") }
            if key.modifierFlags.contains(.command) { parts.append("cmd") }
            parts.append(name)
            onChord?(parts.joined(separator: "+"))
        }
    }

    private static func keyName(_ key: UIKey) -> String? {
        switch key.keyCode {
        case .keyboardLeftArrow: return "left"
        case .keyboardRightArrow: return "right"
        case .keyboardUpArrow: return "up"
        case .keyboardDownArrow: return "down"
        case .keyboardTab: return "tab"
        case .keyboardEscape: return "esc"
        case .keyboardReturnOrEnter, .keypadEnter: return "enter"
        case .keyboardSpacebar: return "space"
        case .keyboardDeleteOrBackspace: return "backspace"
        case .keyboardDeleteForward: return "delete"
        case .keyboardHome: return "home"
        case .keyboardEnd: return "end"
        case .keyboardPageUp: return "pageup"
        case .keyboardPageDown: return "pagedown"
        case .keyboardF1: return "f1"
        case .keyboardF2: return "f2"
        case .keyboardF3: return "f3"
        case .keyboardF4: return "f4"
        case .keyboardF5: return "f5"
        case .keyboardF6: return "f6"
        case .keyboardF7: return "f7"
        case .keyboardF8: return "f8"
        case .keyboardF9: return "f9"
        case .keyboardF10: return "f10"
        case .keyboardF11: return "f11"
        case .keyboardF12: return "f12"
        case .keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
             .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock:
            return nil
        default:
            let chars = key.charactersIgnoringModifiers.lowercased()
            return chars.isEmpty ? nil : chars
        }
    }
}
