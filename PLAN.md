# Plan: Display Term — iTerm2 on the Studio Display, driven by an iPhone

**Pivot (16 Oct 2026).** This app stops being a browser and becomes an iTerm2-style SSH
terminal. Plug the iPhone into the Studio Display and get a full-screen terminal that is
already logged into the Mac mini, with iTerm2's keyboard shortcuts (configurable), tabs,
and split panes. The browser era ends at commit `5b65eed` (16 Oct 2026); its plan, with every hardware
finding, is readable there (`git show 5b65eed:PLAN.md`). The findings that still matter are
carried into section 2.

**Goal.** "iTerm2 on the Studio Display": the phone is the dock, the SSH client and the
trackpad; the display is the terminal; the Magic Keyboard types into it. Undocked, the
phone is a good SSH terminal on its own.

**Owner's priorities (16 Oct 2026).** Default to ssh-ing into the Mac mini with no typing.
iTerm2 shortcuts out of the box, rebindable. Tabs plus splits (down and to the side) in
one window. The phone's screen stays the pointer.

**Non-goals.** A local shell (iOS has none to offer), mosh, floating or multiple windows,
port/agent forwarding, SFTP browsing, App Store distribution, tmux control mode (`-CC`).

---

## 1. Decisions (16 Oct 2026)

| Decision | Choice | Why |
|---|---|---|
| Terminal emulation | **SwiftTerm** (MIT, SwiftPM, v1.20.0) | Mature xterm emulation: 24-bit colour, scrollback, mouse modes, selection, search, OSC 52 clipboard, Kitty keyboard protocol, Metal renderer. Writing a VT parser that renders vim/tmux/htop correctly is weeks of work for nothing we need. We drive its view; its own input handling is used only undocked. |
| SSH client | **swift-nio-ssh** (Apple, Apache 2.0, 0.15.0) over **swift-nio-transport-services** | Pure Swift, builds clean with a Personal Team, PTY + shell + window-change requests, password and ed25519 key auth, host-key validation hook. NIOTS gives us Network.framework sockets, which handle Wi‑Fi/`.local` on iOS better than POSIX sockets. Citadel (a higher-level wrapper) was looked at and rejected: it pins a fork of NIOSSH. |
| Authentication | **Device ed25519 key in the Keychain, bootstrapped once by password** | First connect: show the host fingerprint, ask the macOS password once, append the public key to `~/.ssh/authorized_keys` over the same connection. After that, key only. Password never persisted. Secure Enclave P‑256 (`NIOSSHPrivateKey(secureEnclaveP256Key:)` exists) is a later option. |
| Default host | **Bonjour `_ssh._tcp`**, pick the Mac mini | Remote Login advertises `_ssh._tcp`; no IP to type. Manual `user@host:port` for everything else. |
| Window model | **One window: tabs → split panes** | iTerm2's extra "windows" layer buys nothing on a single display. Panes are a binary split tree (tmux/iTerm2 style). |
| Phone's role | **Undocked: full terminal. Docked: trackpad + actions + extra keys** | Useful on the couch; required by Apple to be functional without the display anyway. |
| Shortcut configuration | **Settings screen + `keymap.json`** in the app's Documents folder | Tap-to-rebind on the phone; the same file is visible in Files and `scp`-able, so it can live in dotfiles. iTerm2 defaults built in. |
| Surviving disconnects | **Auto-reconnect; per-profile "keep shells alive with tmux"** | iOS kills sockets when the app suspends. With the toggle on, each pane runs `tmux new-session -A -s db-<tab>-<pane>` so reconnecting reattaches to the same shell. Mosh would be better and is far too much work. |
| Look | **Bundled JetBrains Mono Nerd Font, iTerm2 "Dark Background" theme, `.itermcolors` import** | Prompt glyphs (starship, powerlevel10k, lsd) render; any iTerm2 preset can be dropped into Files. |
| Display chrome | **Mockup A ("iTerm2 classic")**: tab bar, per-pane title bars, status bar with connection/auth/latency, git branch, key hints, clock | Chosen from `docs/mockups/index.html`. Hint strip is a toggle. **16 Oct 2026, after first use:** status bar and pane title bars off by default (Settings toggles), a few points of padding inside each pane, tmux status line off in the app's sessions. |
| Phone while docked | **Mockup 1**: status line, action buttons (⌘T ⌘D ⌘⇧D ⌘W ⌨), trackpad, extra-keys row | Chosen from the same page. |
| Name | **Display Term** (`CFBundleDisplayName`). Bundle ID stays `com.grassten.displaybrowser`, `PRODUCT_NAME` stays `DisplayBrowser` | Free accounts get 10 App IDs a week and changing the ID loses app data; the internal name is not worth the churn. |
| UI toolkit | UIKit for scenes, display chrome and the terminal host; **SwiftUI (via `UIHostingController`) for settings forms** | Forms are where SwiftUI pays; everything that touches responders, windows or screens stays UIKit. |

## 2. What we are working with

Carried over from the browser era (all measured on this hardware; details at commit `5b65eed`):

| Topic | Fact | Consequence |
|---|---|---|
| External display scene | iPhone apps get a `windowExternalDisplayNonInteractive` scene: full screen, **no touch/pointer/keyboard input delivered to it**. On iOS 27 it must be requested with `registerSceneAccessory(.externalNonInteractive(...))`; iOS 26 uses the Info.plist manifest. | Keep both paths (already in `PhoneViewController.registerDisplayAccessoryIfNeeded` and `project.yml`). Every keystroke is captured on the phone scene and forwarded. |
| Display mode | iPhone 15 drives DisplayPort up to 4K60 over the Thunderbolt cable; `DisplaySceneDelegate.selectBestMode` picks the largest mode ≤ 4K and sets `overscanCompensation = .none`. Record the negotiated `[Display] modes:` log line here the first time it is seen. | Terminal at 3840×2160 @1×: with a 20 px font (≈12×26 px cells) the whole panel is about 320×80 cells. |
| Keyboard | Magic Keyboard over Bluetooth works; hardware keys arrive at the phone scene via `pressesBegan`/`UIKeyCommand`; `GCKeyboard.coalesced` tells us one is attached. ⌘-chords as `UIKeyCommand`s win over `pressesBegan`. | The relay design stands. New: terminals need ⌃/⌥/Tab/Esc/arrows/Fn keys intact — verified key by key in M2. |
| Pointer | No pointing device delivers input to an iPhone app without AssistiveTouch, and with it on the cursor is confined to the phone's screen. Pointer lock is iPad-only. | The phone's touchscreen is the trackpad (`TouchpadView`, `PointerController`, `CursorView` are kept). `MouseInput` stays behind `Settings.externalPointingDevices` for a future iPad. |
| Staying foreground | `GCMouse` and our relay only work with the app foreground; edge swipes background it. | Guided Access while docked; `isIdleTimerDisabled` while docked. |
| Free Apple ID | 7-day profiles, 3 apps per device, 10 App IDs per week, no iCloud/push/associated-domains entitlements. | Weekly `scripts/deploy.sh`. Nothing here needs a restricted entitlement: Keychain, local network and Bonjour are plain Info.plist keys. |

New facts, verified against the libraries' current sources on 16 Oct 2026:

| Topic | Fact | Consequence |
|---|---|---|
| SwiftTerm input/output | `TerminalView.feed(byteArray:)` for bytes in; `TerminalViewDelegate.send(source:data:)` for bytes out; `sizeChanged(newCols:newRows:)`, `setTerminalTitle`, `hostCurrentDirectoryUpdate`, `scrolled`, `requestOpenLink`, `clipboardCopy`, `bell`. | Clean seam to the SSH channel. Titles and cwd come free from OSC 0/2/7. |
| SwiftTerm keys | iOS `TerminalView.pressesBegan` is `open`, **skips ⌘-chords** (so `UIKeyCommand`s win), encodes function keys with application-cursor/keypad state, supports `optionAsMetaKey`, `backspaceSendsControlH`, key repeat, and the Kitty keyboard protocol when the remote enables it. Text arrives via `insertText` (UIKeyInput). | Docked, the phone-side relay forwards `pressesBegan`/`pressesEnded` and `insertText` into the focused pane's view instead of re-implementing key encoding. Fallback if that misbehaves: our own ~150-line encoder. |
| SwiftTerm pointer | `terminal.sendEvent(buttonFlags:x:y:)` / `encodeButton` for mouse reporting; `terminal.selection.startSelection/dragExtend/selectWordOrExpression/getSelectedText`; `setSelectionRange`, `clearSelection`; `scrollUp(lines:)`/`scrollDown`; `allowMouseReporting`. | `PointerController` can drive selection, clicks and wheel into the engine directly, no JavaScript bridge. |
| SwiftTerm extras | `setUseMetal` (4K rendering); OSC 52 clipboard hooks. **Version matters:** the 1.20.0 tag (what we build) exposes `getTerminal()` and a public `selection: SelectionService`, which the display pointer uses; `main` hides both, adds Kitty-clipboard delegate methods and `findNext/findPrevious`. Package needs Xcode 26+. | Pinned to the exact tag in `project.yml`; re-check `Pane` and `DisplayRootViewController` when bumping. |
| NIOSSH | `NIOSSHPrivateKey(ed25519Key:)` (also p256/p384/p521 and Secure Enclave P‑256); `Offer`: `privateKey`, `password`, `hostBased`, `none` — **no keyboard-interactive**; `SSHChannelRequestEvent.PseudoTerminalRequest/ShellRequest/ExecRequest/EnvironmentRequest/WindowChangeRequest/ExitStatus`; `NIOSSHClientServerAuthenticationDelegate.validateHostKey` for trust-on-first-use. Deps: swift-nio ≥ 2.81, swift-crypto, swift-atomics. | Everything the Mac needs. If a host only offers keyboard-interactive, the key path still works once installed by hand. |
| macOS Remote Login | Enabled in System Settings › General › Sharing. Default `sshd_config` accepts password auth (via PAM) and publickey; advertises `_ssh._tcp` over Bonjour. Host keys in `/etc/ssh/ssh_host_*_key.pub`. | Password bootstrap works out of the box; the fingerprint sheet tells the owner the command to compare against. |
| iOS networking | Bonjour browsing needs `NSLocalNetworkUsageDescription` + `NSBonjourServices: [_ssh._tcp]` and triggers the Local Network prompt once. Suspended apps lose their sockets within seconds. | Reconnect on `sceneDidBecomeActive`; tmux toggle for continuity. |
| iOS reserved shortcuts | ⌘H, ⌘Space, ⌘Tab, ⌘⇧3/4 and Globe chords never reach the app; ⌃Space is believed to switch keyboards. | Greyed out in the Shortcuts screen; the exact list is measured in M2 and recorded here. |

## 3. Product definition

**Docked** (display connected): the display shows one window — tab bar on top, split panes
with a one-line title bar each (`user@host — cwd — command`, from OSC 0/7), a status bar at
the bottom (● host · auth · latency; git branch when the shell reports it; key-hint strip;
clock). Inactive panes are dimmed (iTerm2 default). The phone shows a status line, five
action buttons (new tab, split, split down, close, keyboard), the trackpad, and an
extra-keys row (esc tab ctrl alt ↑↓←→ and `⌘ ⋯`, a menu of every bound action). With no
hardware keyboard, ⌨ raises the on-screen keyboard above the extra keys, so the phone alone
can drive the display.

**Undocked**: tabs as pills along the top; each tab shows its focused pane full-screen with
a `1/3` badge that cycles panes; SwiftTerm's own touch handling (tap, drag-select, pinch
for font size); the extra-keys row above the iOS keyboard, `ctrl`/`alt` sticky for one
keystroke. Docking moves the same sessions to the display with no reconnect.

**First run**: *Connect* lists Macs found via Bonjour; pick one, enter the user name; the
host-key fingerprint sheet asks to trust it; one password prompt installs the device key
into `~/.ssh/authorized_keys`; toggles for *keep shells alive with tmux* and *connect when
the app opens*. Saved as a profile; the Mac mini profile is the default.

**Keymap defaults (iTerm2 3.5), all rebindable:**

| Group | Action | Default |
|---|---|---|
| Tabs | New tab · close pane (tab when last) · close whole tab | ⌘T · ⌘W · ⌥⌘W |
| | Next / previous tab | ⌘⇧] or ⌃Tab · ⌘⇧[ or ⌃⇧Tab |
| | Tab 1–9 · move tab left / right | ⌘1–9 · ⌘⇧← / ⌘⇧→ |
| Panes | Split vertically (side by side) · split horizontally (one above the other) | ⌘D · ⌘⇧D |
| | Focus pane left / right / up / down · next / previous pane | ⌘⌥←→↑↓ · ⌘] / ⌘[ |
| | Maximize / restore pane · move divider | ⌘⇧↩ · ⌃⌘←→↑↓ |
| | Broadcast input to all panes in the tab | ⌥⌘I |
| Session | Copy · paste · select all | ⌘C · ⌘V · ⌘A |
| | Find · next · previous | ⌘F · ⌘G · ⌘⇧G |
| | Clear buffer · reset terminal · reconnect (ours) | ⌘K · ⌘R · ⌘⇧R |
| | Text bigger / smaller / default | ⌘+ · ⌘− · ⌘0 |
| | Scroll line · page · top / bottom | ⌘↑↓ · ⌘⇞⇟ (also ⇧⇞⇟) · ⌘↖ / ⌘↘ |
| | Hide chrome (iTerm2 "full screen") · open settings · edit profile | ⌘↩ · ⌘, · ⌘I |
| Keys | Left ⌥ = Esc+, right ⌥ = Normal; ⌥← / ⌥→ send `ESC b` / `ESC f`; ⌫ sends DEL; ⇧↩ newline for multi-line prompts (byte sequence verified against Claude Code in M2) | profile settings |
| Custom | `sendText`, `sendBytes` (hex), `sendEscape` actions for anything else | — |

A binding on a ⌃ or ⌥ chord takes it away from the shell, as in iTerm2; the Shortcuts
screen says so inline. Reserved iOS chords are greyed out.

**Pointer (phone trackpad, docked):** one finger moves; tap clicks (focuses a pane; sends a
mouse click to apps that track the mouse); double-tap selects a word, triple a line; hold
then move drag-selects (or drags for mouse-tracking apps); two fingers scroll the
scrollback, or send wheel events / arrow keys to full-screen apps (SwiftTerm's Alternate
Scroll Mode); two-finger tap opens the context menu (Copy, Paste, Split…, Close, Clear,
Rename tab, Open URL); pinch changes font size; dragging a divider resizes; clicking a tab
switches; ⌘-click on a URL opens it in Safari on the phone.

**Settings (phone):** Profiles (host, user, auth, tmux, connect-on-launch); Shortcuts
(grouped list, tap → press new chord, conflicts flagged, Reset to iTerm2 defaults);
Appearance (font, size, theme + `.itermcolors` import, dimming amount, cursor style, hint
strip on/off); Keys (Option behaviour, Backspace, ⇧↩).

## 4. Architecture

```
┌──────────────────────── iPhone ────────────────────────┐   ┌──────── Studio Display ─────────┐
│ PhoneScene                                             │   │ DisplayScene (non-interactive)   │
│  PhoneRootViewController                               │   │  DisplayRootViewController       │
│   docked:   status · actions · TouchpadView · key row  │   │   ├─ TabBarView                  │
│   undocked: tabs · PaneView(TerminalView) · key row    │   │   ├─ pane layout (PaneTree)      │
│  KeyRelayView (first responder when docked)            │   │   │   └─ PaneView ×N            │
│   └─ KeyDispatcher: chord ∈ Keymap → action            │──►│   │       TerminalView + title   │
│                     else → focused PaneView            │   │   ├─ StatusBarView               │
│  PointerController ──────────────────────────────────────►│   └─ CursorView, context menu   │
│                                                        │   └──────────────────────────────────┘
│ Workspace (shared model): [Tab] → PaneTree → Pane      │
│  Pane: SwiftTerm Terminal ⇄ SSHSessionChannel          │
│  Profile · Keymap · Theme · WorkspaceStore (restore)    │
│                                                        │
│ SSH: NIOTSConnectionBootstrap + NIOSSHHandler           │
│  AuthDelegate (device key → password)                  │
│  HostKeyStore (TOFU) · DeviceKey (Keychain ed25519)    │
│  KeyInstaller · HostBrowser (NWBrowser, _ssh._tcp)      │
└────────────────────────────────────────────────────────┘
```

Repository layout after M0:

```
Sources/App/           AppDelegate, PhoneSceneDelegate, DisplaySceneDelegate                       (kept)
Sources/Model/         Workspace, Tab, PaneTree, Pane, Profile, Keymap, Theme, WorkspaceStore
Sources/SSH/           SSHConnection, SSHSessionChannel, AuthDelegate, HostKeyStore, DeviceKey, KeyInstaller, HostBrowser
Sources/Input/         KeyRelayView, KeyDispatcher, PointerController, TouchpadView, CursorView     (last three kept)
Sources/UI/Display/    DisplayRootViewController, PaneView, TabBarView, StatusBarView, ContextMenuView (kept)
Sources/UI/Phone/      PhoneRootViewController, ConnectViewController, SettingsHost (SwiftUI forms)
Sources/Resources/     Fonts/JetBrainsMonoNerdFontMono-*.ttf, Themes/*.itermcolors, keymap.default.json
docs/mockups/          index.html — the agreed look (A + 1), kept as the reference
```

Flows:

1. **Keys, docked.** Hardware keyboard → phone window → `KeyRelayView` (UIKeyInput, first
   responder) → `KeyDispatcher`. A chord in the `Keymap` runs its action. Anything else is
   forwarded to the focused pane's `TerminalView`: `pressesBegan`/`pressesEnded` for special
   keys, modifiers and repeat; `insertText` for text. SwiftTerm encodes with the terminal's
   current modes → `TerminalViewDelegate.send` → `SSHSessionChannel.write`.
2. **Keys, undocked.** The `TerminalView` on the phone is first responder itself. ⌘-chords
   fall through SwiftTerm to the `UIKeyCommand`s on `PhoneRootViewController`, built from
   the same `Keymap`.
3. **Bytes in.** NIO event loop → coalesce one read → main actor → `terminalView.feed`.
4. **Resize.** Layout sets the view frame → `sizeChanged(newCols:newRows:)` →
   `WindowChangeRequest` on the channel.
5. **Dock / undock.** `DisplaySceneDelegate` connects → `DisplayRootViewController` adopts the
   `Workspace`; every `PaneView` is re-parented into the display window (same views, same
   engines, no reconnect — the browser moved its `WKWebView` the same way). Disconnect
   reverses it. Sizes change, so window-change requests follow.
6. **Connect.** `HostBrowser` resolves the profile's Bonjour name (or host:port) →
   `NIOTSConnectionBootstrap` → `NIOSSHHandler(role: .client)` with `AuthDelegate` (offers
   the device key, then asks the phone for a password) and `HostKeyStore` (fingerprint sheet
   on first sight, hard refusal on mismatch) → `session` child channel →
   `PseudoTerminalRequest(term: "xterm-256color", cols, rows, modes)` → `ShellRequest`, or
   `ExecRequest("tmux new-session -A -s db-<tab>-<pane>")` when the tmux toggle is on (exit
   status 127 → fall back to a shell and show "tmux not installed: brew install tmux").
7. **Key bootstrap.** After a password-authenticated connect, a second `session` channel runs
   `umask 077; mkdir -p ~/.ssh; grep -qxF '<pub>' ~/.ssh/authorized_keys 2>/dev/null || echo '<pub>' >> ~/.ssh/authorized_keys`;
   the profile flips to key-only.
8. **Reconnect.** Channel inactive → pane overlay "Disconnected · reconnecting in 2 s" →
   backoff 1, 2, 4, 8, 15, 30 s while foreground; `sceneDidBecomeActive` retries at once.
9. **Clipboard.** ⌘C puts the selection on `UIPasteboard` (Universal Clipboard carries it to
   the Mac); ⌘V pastes with bracketed paste when the remote enabled it; OSC 52 from the remote
   (`tmux set-clipboard`, `pbcopy`-style tools) also lands on the pasteboard.

Data formats:

```jsonc
// Documents/keymap.json — same data the Shortcuts screen edits; reloaded on change
{ "version": 1, "leftOption": "esc+", "rightOption": "normal",
  "bindings": [
    { "keys": "cmd+t",          "action": "newTab" },
    { "keys": "cmd+d",          "action": "splitVertical" },
    { "keys": "cmd+shift+d",    "action": "splitHorizontal" },
    { "keys": "cmd+alt+left",   "action": "focusPane", "arg": "left" },
    { "keys": "alt+left",       "action": "sendText",  "arg": "\u001bb" },
    { "keys": "ctrl+shift+c",   "action": "sendBytes", "arg": "03" }
  ] }
// key names: cmd shift alt ctrl + a–z 0–9 f1–f12 left right up down tab esc enter space backspace delete home end pageup pagedown ` - = [ ] \ ; ' , . /

// Application Support/profiles.json
{ "profiles": [ { "id": "…", "name": "Mac mini",
    "host": { "bonjour": "Mac mini" },            // or { "address": "mac-mini.local", "port": 22 }
    "user": "steven", "auth": "deviceKey",         // or "password" (asked each time)
    "tmux": true, "tmuxSession": "db-{tab}-{pane}",
    "connectOnLaunch": true,
    "theme": "Dark Background", "font": { "family": "JetBrainsMonoNFM", "size": 20 } } ],
  "default": "…" }

// Application Support/known_hosts.json — TOFU store
{ "mac-mini.local": { "type": "ssh-ed25519", "sha256": "x3K9…", "firstSeen": "2026-10-16T14:02:11Z" } }

// Application Support/workspace.json — layout restore
{ "tabs": [ { "title": null, "tree": { "split": "vertical", "ratio": 0.6,
    "a": { "pane": { "profile": "…", "tmux": "db-1-1" } },
    "b": { "split": "horizontal", "ratio": 0.5,
      "a": { "pane": { "profile": "…", "tmux": "db-1-2" } },
      "b": { "pane": { "profile": "…", "tmux": "db-1-3" } } } } } ], "active": 0 }
```

Design points:

- **PaneTree** is a binary tree: `leaf(Pane)` or `split(axis, ratio, a, b)`. Splitting a
  leaf replaces it with a split whose `a` is the old pane; closing collapses the parent.
  Layout is a recursive frame division; dividers are 1 px plus an 8 pt grab zone for the
  pointer. Focus navigation picks the nearest leaf in the requested direction by frame.
- **One `TerminalView` per pane for its whole life**, moved between windows on dock/undock.
  Display chrome scales by a factor `s = displayWidth / 1920` as `DesktopViewController`
  did; the terminal font is in pixels and user-controlled.
- **Dimming** of inactive panes is an overlay on `PaneView`, amount from Appearance
  (default 0.4, iTerm2's).
- **`KeyRelayView`** replaces `RelayTextField`: a plain `UIView` conforming to `UIKeyInput`
  with `canBecomeFirstResponder`, no caret, no autocorrection. When no hardware keyboard is
  attached and ⌨ is tapped, the same view raises the on-screen keyboard with the extra-keys
  row as its `inputAccessoryView`.
- **Latency** in the status bar is the round trip of an SSH `keepalive@openssh.com` global
  request every 15 s, which doubles as the dead-connection detector.
- **Tab title**: user-set name, else the focused pane's OSC title, else `cwd` basename.

## 5. Milestones

Each ends with something installed on the phone and a short acceptance test on the real
hardware. Estimates are working days on the Mac mini.

### M0 — Pivot the repo (½ day) — *done 16 Oct 2026*
- Tag `browser-final`. Delete `Sources/Browser`, `bridge.js`, `scripts/bridge-harness`,
  `DesktopViewController`, `RelayTextField`, `BrowserModel` references in `PhoneViewController`
  (which becomes `PhoneRootViewController`), the stray `Sources/Info 2.plist`.
- `project.yml`: add SwiftPM packages SwiftTerm, swift-nio-ssh, swift-nio-transport-services;
  `CFBundleDisplayName: Display Term`; Info.plist keys `NSLocalNetworkUsageDescription`,
  `NSBonjourServices: [_ssh._tcp]`, `UIAppFonts` for the four Nerd Font files; drop the
  camera/microphone strings and `UIApplicationSupportsIndirectInputEvents`.
- Rewrite `README.md` and `CLAUDE.md` for the terminal; keep the deploy loop unchanged.
- **Accept:** `scripts/deploy.sh` builds, installs and launches; the phone shows an empty
  SwiftTerm view; packages resolve with the Personal Team signing.

### M1 — One SSH session on the phone (1 day) — *written, untested*
- `HostBrowser` (NWBrowser), `ConnectViewController`, `SSHConnection` over NIOTS with
  password auth, `HostKeyStore` + fingerprint sheet, `SSHSessionChannel` with PTY
  (`xterm-256color`), shell, window-change, exit status; `Pane` glue to a `TerminalView`;
  undocked layout with tabs strip and extra-keys row; disconnect overlay and reconnect.
- **Accept:** from the couch, over Wi‑Fi, log into the Mac mini without typing a host name;
  `vim`, `htop`, `claude`, `tmux` render correctly; rotating the phone resizes the remote
  terminal; lock the phone, unlock, the session reconnects.

### M2 — Keys (1 day) — *written, untested*
- `DeviceKey` (CryptoKit ed25519 in the Keychain, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`),
  `KeyInstaller`, key-first `AuthDelegate`.
- `Keymap` engine: actions, chord parser, iTerm2 defaults in `keymap.default.json`,
  `Documents/keymap.json` with live reload, `UIKeyCommand` generation for the undocked case.
- `KeyRelayView` + `KeyDispatcher`, forwarding into SwiftTerm. On hardware, with the Magic
  Keyboard, verify every class of key: ⌃A–Z, Tab, Esc, arrows (with and without
  application-cursor mode), ⌥-arrows, Fn keys, Home/End/PgUp/PgDn, ⌫/⌦, key repeat,
  ⇧↩ into Claude Code. Measure which ⌘ chords iOS keeps; record the list in section 2.
- **Accept:** key-only login after one password; every default in the keymap table works or
  is documented as reserved by iOS.

### M3 — The display (1–2 days) — *written, untested*
- `DisplayRootViewController`: tab bar, one pane with title bar, status bar, cursor layer,
  chrome scale factor; default 20 px font; try `setUseMetal` at 4K.
- Dock/undock handoff of the `Workspace`; phone docked layout (status, five actions,
  trackpad, extra-keys row); `isIdleTimerDisabled` while docked.
- **Accept:** plug the display in → the session fills it with no black bars and the phone
  shows the docked layout; Magic Keyboard typing lands in the pane; unplug → back on the
  phone, nothing reconnected. Record the `[Display] modes:` line in section 2.

### M4 — Tabs and splits (1–2 days) — *written, untested*
- `PaneTree` with split/close/focus/maximize/divider-move actions, dimming, pane title bars,
  tab titles, `WorkspaceStore` save/restore, tmux reattach on restore.
- **Accept:** rebuild the three-pane layout from the mockup with ⌘D/⌘⇧D, navigate with
  ⌘⌥arrows, zoom a pane with ⌘⇧↩, kill and relaunch the app → same layout, same shells.

### M5 — Pointer on the display (1 day) — *written, untested*
- Adapt `PointerController`/`TouchpadView` to the terminal: focus-click, selection
  (character/word/line) → ⌘C, scroll vs. mouse-wheel reporting, mouse clicks for tracking
  apps, context menu, divider drag, tab click, ⌘-click URL.
- **Accept:** select a passage in one pane and paste it into vim in another; scroll `less`
  and the scrollback; click into tmux panes inside a pane; resize a split by dragging.

### M6 — Settings (1 day) — *written, untested; rebinding UI included*
- SwiftUI forms: Profiles, Shortcuts (tap → press chord, conflict and reserved markers,
  Reset), Appearance (font, size, theme list + `.itermcolors` import via Files, dimming,
  cursor style, hint strip), Keys (Option behaviour, Backspace, ⇧↩).
- **Accept:** rebind ⌘D to ⌘⇧V on the phone and it works immediately on the display;
  import Solarized Dark from Files and every pane recolours.

### M7 — Daily-use polish (ongoing)
- ⌘F with match count, bracketed paste, OSC 52 clipboard, bell and OSC 9 notifications
  (banner on the phone), scrollback size, output coalescing for `cat bigfile`, battery and
  thermals at 4K, `scripts/install-launchd.sh` for the weekly redeploy.

## 5a. Implementation status (16 Oct 2026, evening)

Everything in M0–M6 is written and compiles for iOS (`xcodebuild`, generic device, no
signing) with SwiftTerm 1.20.0, swift-nio-ssh 0.15.0, swift-nio 2.104.0, NIOTS 1.28.0 and
swift-collections pinned to 1.2.1. Nothing has run on the phone yet. First deploy is next.

What was decided while writing it, beyond section 1:

- **One SSH connection per pane**, not multiplexed channels on one connection. Simpler
  reconnect; key auth makes the extra handshakes silent. A second channel on the same
  connection runs the one-off `authorized_keys` install.
- **tmux is started through a login shell** (`exec "$SHELL" -lc 'PATH=/opt/homebrew/bin:/usr/local/bin:$PATH exec tmux new-session -A -s dt-<n>'`): sshd runs exec requests with a
  minimal PATH that lacks Homebrew. Exit status 127 means no tmux; the pane falls back to a
  plain shell and says so. Session names are `dt-<serial>` with a persistent counter.
- **Shortcuts are UIKeyCommands** generated from `keymap.json`, installed on the phone's
  root view controller. They win over the terminal in both modes, which is exactly iTerm2's
  rule that a bound chord is taken from the shell.
- **Docked key path**: `KeyRelayView` (a `UIKeyInput` view, first responder) forwards
  `pressesBegan/Ended/Cancelled`, `insertText` and `deleteBackward` straight into the
  focused pane's `TerminalView` on the display. Its `inputAccessoryView` is the extra-keys row,
  so with no hardware keyboard the on-screen keyboard appears with esc/tab/ctrl/alt/arrows.
- **Display pointer** uses SwiftTerm 1.20.0's public engine: `mouseMode` decides whether a tap
  is reported as a click (press + release unless x10) or starts a selection
  (`selection.setSoftStart` + `dragExtend`, screen rows); double-click selects a word via
  `selection.select(row:)` + text scan; two-finger scroll sends wheel events to
  mouse-tracking programs, arrow keys in the alternate buffer, and scrolls the scrollback
  otherwise. Dividers have a 6 pt grab zone; the context menu is `ContextMenuView` driven by
  pointer hit-testing of its buttons.
- **Theme application** goes through `installColors` + native fg/bg/caret/selection setters;
  `.itermcolors` files in Documents/Themes are parsed with PropertyListSerialization.
- Tooling: `xcodebuild -downloadComponent MetalToolchain` once (SwiftTerm ships a `.metal`
  shader; the Xcode 27 beta has no Metal toolchain by default), and
  `-skipPackagePluginValidation -skipMacroValidation` on every command-line build
  (SwiftTerm's build-tool plugin). Both are in `scripts/deploy.sh` / CLAUDE.md.

Not built yet, deliberately: ⌘F search (not in 1.20.0's public view API), broadcast input,
right-Option-as-Normal (SwiftTerm has one `optionAsMetaKey` flag), Secure Enclave keys,
SwiftTerm's Metal renderer (off until measured on the display), the launchd redeploy.

## 6. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Forwarding `pressesBegan`/`insertText` from the phone's responder into a `TerminalView` in another window misses some keys or double-fires repeats | Medium | Spike in M2 with a per-key log; fallback is our own encoder (~150 lines) driving `terminalView.send`. |
| iOS keeps chords we want (⌘H, ⌘Space, ⌘Tab, maybe ⌃Space, ⌘⇧3/4) | Certain for some | Measured in M2; greyed out in Shortcuts; alternatives bound by default where iTerm2 has two (⌃Tab and ⌘⇧]). |
| Suspension kills SSH even with the display attached (phone auto-locks) | Medium | `isIdleTimerDisabled` while docked, Guided Access, tmux toggle, instant reconnect on activate. |
| Metal renderer misbehaves on the external `UIScreen` | Low–Medium | `setUseMetal` is a switch; Core Graphics path is the default until measured. |
| `.local` resolution or the Local Network prompt blocks discovery | Low | NIOTS connects to the Bonjour endpoint directly (`NWEndpoint.service`); manual `address:port` always available. |
| Owner's `sshd_config` disables password auth | Low | Connect screen shows the public key with a copy button and the one-line `authorized_keys` command to run on the Mac. |
| 320 columns of 24-bit colour at 4K stresses rendering (`cat` of a big log) | Medium | Coalesce reads per frame; SwiftTerm's synchronized-output support; Metal. |
| SwiftTerm needs `swift-tools-version 6.2` | None with Xcode 27 | Noted in CLAUDE.md; Xcode 26+ required to build. |
| Universal Clipboard not wanted for everything copied | Low | Appearance › "Copy also to the Mac" toggle later; default on. |

## 7. Open questions (non-blocking; defaults in bold)

- Tab bar position: **top** (iTerm2 default) or bottom.
- Dimming amount for inactive panes: **0.4**.
- ⌃Tab as next tab (iTerm2 default) steals ⌃Tab from terminal apps: **on**.
- Default font size on the display: **20 px** (≈ 320×80 cells); phone: **13 pt**.
- tmux toggle default for the Mac mini profile: **on if `tmux` is found on first connect**,
  else off with a hint.
- Rename the repository directory (`external-display-safari` → `display-term`)? Owner's
  call; it changes the iCloud Desktop path that CLAUDE.md and the scripts mention.
- Right-click (two-finger tap) menu contents beyond the list in section 3.

## 8. Sources

- SwiftTerm: https://github.com/migueldeicaza/SwiftTerm (APIs checked against v1.20.0 sources, 2026-10-16)
- swift-nio-ssh: https://github.com/apple/swift-nio-ssh (0.15.0)
- swift-nio-transport-services: https://github.com/apple/swift-nio-transport-services
- Citadel (reference only): https://github.com/orlandos-nl/Citadel
- Nerd Fonts (JetBrains Mono NF, OFL 1.1): https://github.com/ryanoasis/nerd-fonts
- iTerm2 documentation (menu shortcuts, key mappings, colour presets): https://iterm2.com/documentation.html
- iTerm2 colour schemes (`.itermcolors` plist format): https://github.com/mbadolato/iTerm2-Color-Schemes
- Apple, `NWBrowser` and the local-network privacy keys: https://developer.apple.com/documentation/network/nwbrowser
- Apple, *Presenting content on a connected display* (iOS 27 scene accessory): https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display
- Apple, *Allow a remote computer to access your Mac* (Remote Login): https://support.apple.com/guide/mac-help/mchlp1066/mac
- Browser-era plan with all hardware measurements: `git show 5b65eed:PLAN.md`
