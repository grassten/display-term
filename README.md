# Display Term

A terminal emulator for iPhone, built to be used **docked**: plug the phone into a monitor
(Apple Studio Display or any USB-C/Thunderbolt display), pair a Bluetooth keyboard, and the
monitor becomes a full-screen, iTerm2-style SSH terminal with tabs, split panes and iTerm2's
keyboard shortcuts (all rebindable). The phone's screen is the trackpad. iOS delivers no
input to an external-display scene, so every keystroke is captured on the phone and relayed
to the terminal on the monitor. Undocked, the phone is an ordinary SSH terminal.

There is no local shell (iOS has none); the app connects over SSH, by default to a Mac on
the same network found by Bonjour, and can keep shells alive across disconnects with tmux.

Terminal emulation by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (vendored with
patches, see `Vendor/SwiftTerm/PATCHES.md`); SSH by
[swift-nio-ssh](https://github.com/apple/swift-nio-ssh).

**Status:** a personal project, in daily use on an iPhone 15 (iOS 27) with a Studio Display,
a Mac mini and a Magic Keyboard. It is not on the App Store; you build and install it
yourself from Xcode, which works with a free Apple ID (the install then expires every 7
days). See [PLAN.md](PLAN.md) for the decisions, architecture, milestones and what is still
untested. The project started as a browser for the external display; that code is in git
history up to commit `5b65eed`.

### What you need

- An iPhone with USB-C (video out over USB-C needs a USB 3 or Thunderbolt cable; the cable
  in the box is USB 2 and carries no video).
- A monitor with a USB-C or Thunderbolt input, and a Bluetooth keyboard paired to the phone.
- A Mac with Xcode 27 to build and install, and something to SSH into (the same Mac works).

## Setup on the Mac (once)

1. Install Xcode 27 and `brew install xcodegen`. SwiftTerm's Metal renderer needs the Metal
   toolchain: `xcodebuild -downloadComponent MetalToolchain` (≈840 MB, once).
2. Sign in to Xcode with your Apple ID: Xcode > Settings > Accounts. A "Personal Team"
   appears automatically.
3. Run `scripts/bootstrap.sh`, then edit `Config/Local.xcconfig` and set
   `DEVELOPMENT_TEAM` to your Personal Team ID (the script prints candidates).
4. On the iPhone: Settings > Privacy & Security > Developer Mode > on (reboots the phone).
   Plug the phone into the Mac once and tap Trust.
5. Run `scripts/deploy.sh`. The first install asks you to trust the developer app on the
   phone: Settings > General > VPN & Device Management > your Apple ID > Trust.

`scripts/deploy.sh` builds, signs and installs over USB or Wi-Fi. The free provisioning
profile expires after 7 days, so re-run it weekly. The app keeps its hosts, keys and layout
across reinstalls.

On the Mac: System Settings › General › Sharing › **Remote Login** on. Optional but
recommended: `brew install tmux`, so shells survive the phone sleeping.

## Using it

### First run

The app looks for Macs with Remote Login on the local network (Bonjour) and shows them. Pick
yours, type your macOS user name, Save & Connect. You get the Mac's host-key fingerprint to
trust (compare with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the Mac), then one
password prompt. The app then installs its own ed25519 key into `~/.ssh/authorized_keys`;
later connections need no password. The key never leaves the phone's Keychain.

### Docked

Plug the phone into the display with a Thunderbolt or USB 3 cable and pair the keyboard with
the phone over Bluetooth.

The display shows the tab bar, the panes (each with a title bar: `user@host — cwd — title`),
and a status bar. The phone shows the connection status, four buttons (new tab, split, split
down, close), a trackpad, and a row of extra keys (esc, tab, ctrl, alt, arrows, `⌘ ⋯` with
every action). With no hardware keyboard, the phone's keyboard appears above that row.

| Trackpad gesture | Action |
|---|---|
| one finger | move the cursor |
| tap | focus that pane; click, for programs that track the mouse (tmux, vim with `mouse=a`) |
| tap, tap | select the word; a third tap selects the line |
| hold still, then move | select text; ⌘C copies |
| two fingers | scroll the scrollback; wheel events or arrow keys inside full-screen programs |
| two-finger tap | context menu: copy, paste, split, maximize, clear, reconnect, close |
| drag a divider | resize the split |
| tap a tab, or `+` | switch tabs, new tab |

### Shortcuts (iTerm2 defaults)

| | |
|---|---|
| ⌘T · ⌘W · ⌥⌘W | new tab · close pane (tab when last) · close tab |
| ⌘⇧] / ⌘⇧[ · ⌃Tab / ⌃⇧Tab · ⌘1–9 | next / previous tab · tab n |
| ⌘⇧← / ⌘⇧→ | move tab |
| ⌘D · ⌘⇧D | split side by side · split stacked |
| ⌘⌥←→↑↓ · ⌘] / ⌘[ | focus pane by direction · next / previous pane |
| ⌘⇧↩ · ⌃⌘←→↑↓ | maximize / restore pane · move divider |
| ⌘C · ⌘V · ⌘A | copy · paste · select all |
| ⌘K · ⌘R · ⌘⇧R | clear buffer · reset terminal · reconnect |
| ⌘+ / ⌘− / ⌘0 | font size |
| ⌘↑↓ · ⌘⇞⇟ / ⇧⇞⇟ · ⌘↖ / ⌘↘ | scroll line · page · top / bottom |
| ⌘↩ · ⌘, | hide / show tab and status bars · settings |
| ⌥← / ⌥→ | word left / right (`ESC b` / `ESC f`) |

Left Option sends Meta (`ESC` prefix) by default. Rebind anything in Settings › Shortcuts
(tap an action, press the new chord), or edit `keymap.json` in Files › On My iPhone ›
Display Term; it is reloaded when the app comes back to the foreground. Bindings on ⌃ or ⌥
chords are taken away from the shell, as in iTerm2. iOS keeps ⌘H, ⌘Space and ⌘Tab.

### Appearance

Settings › Appearance: theme (iTerm2 "Dark Background" by default, Solarized Dark bundled),
font size for the display and for the phone, dimming of inactive panes, pane title bars,
status-bar hints. Drop any iTerm2 `.itermcolors` file into Files › On My iPhone › Display
Term › Themes to add it. Font: JetBrains Mono Nerd Font, so prompt glyphs render.

### Sessions

With "keep shells alive with tmux" on (default), each pane runs
`tmux new-session -A -s dt-<n>` on the Mac. When the phone sleeps and iOS drops the
connection, the pane reconnects on return and reattaches to the same shell. Without tmux you
get a fresh shell. Layout (tabs, splits, which tmux session is where) is saved and restored
on relaunch.

## Layout

```
project.yml                     XcodeGen project definition (generates DisplayBrowser.xcodeproj; SwiftPM packages pinned here)
Config/Local.xcconfig.example   Template for your Personal Team ID
scripts/bootstrap.sh            One-time setup
scripts/deploy.sh               Build + sign + install to the phone (run weekly)
Sources/App/                    AppDelegate and the two scene delegates (phone, display)
Sources/Model/                  AppState, Workspace → Tab → PaneNode/Pane, Profile, Keymap, Theme
Sources/SSH/                    SSHConnection (NIOSSH over Network.framework), auth + host-key delegates, DeviceKey, HostBrowser
Sources/Input/                  KeyRelayView (phone → display keys), Commands, PointerController, TouchpadView, MouseInput
Sources/UI/Display/             DisplayRootViewController, PaneView, TabBarView, StatusBarView, CursorView, ContextMenuView
Sources/UI/Phone/               PhoneRootViewController, ExtraKeysView, PromptCenter, SettingsViews (SwiftUI)
Sources/Resources/Fonts/        JetBrains Mono Nerd Font Mono (OFL)
docs/mockups/                   The agreed look
```
