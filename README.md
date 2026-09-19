# external-display-safari

An iPhone app that turns an Apple Studio Display (or any USB-C monitor) into a full-screen,
desktop-class browser: Safari-style toolbar and tabs, a real pointer (wired Magic Trackpad,
any Bluetooth mouse, or the phone's screen as a trackpad), right-click menus, text selection,
clipboard, find in page, downloads, and full keyboard control. The phone is the dock and
controller. WebKit engine (the same one Safari uses) via WKWebView. Built for one person and
installed from Xcode with a free Apple ID.

**Status:** first iteration scaffolded, not yet run on hardware. See [PLAN.md](PLAN.md) for
the verified platform constraints, architecture, milestones, risks and open questions.

## Setup on the Mac mini (once)

1. Install Xcode 27 (the iOS 27 SDK is needed for the external-display API on iOS 27
   phones; the code also has the iOS 26 path) and `brew install xcodegen`.
2. Sign in to Xcode with your Apple ID: Xcode > Settings > Accounts. A "Personal Team"
   appears automatically.
3. Optionally change the bundle ID in `project.yml` (`PRODUCT_BUNDLE_IDENTIFIER`). Do this
   before the first install; free accounts get only 10 App IDs per week.
4. Run `scripts/bootstrap.sh`, then edit `Config/Local.xcconfig` and set
   `DEVELOPMENT_TEAM` to your Personal Team ID (the script prints candidates).
5. On the iPhone: Settings > Privacy & Security > Developer Mode > on (reboots the phone).
   Plug the phone into the Mac once and tap Trust.
6. Run `scripts/deploy.sh`. The first install asks you to trust the developer app on the
   phone: Settings > General > VPN & Device Management > your Apple ID > Trust.

`scripts/deploy.sh` builds, signs and installs over USB or Wi-Fi. The free provisioning
profile expires after 7 days, so re-run it weekly (a `launchd` job on the Mac mini can do
this while the phone is on the same Wi-Fi). The app keeps its tabs and logins across
reinstalls.

If the iOS 27 block in `Sources/UI/PhoneViewController.swift` fails to compile on your
Xcode, delete `registerDisplayAccessoryIfNeeded()`; the Info.plist path still works on
iOS 26.

## Using it

Plug the phone into the display with a Thunderbolt or USB 3 cable (the cable that came
with the phone is USB 2 and carries no video). Pair the keyboard with the phone over
Bluetooth. Open the app. The display shows the browser; the phone shows status, the URL
field and a trackpad area.

### Pointer

Three ways to get a cursor on the display, all optional:

- **Magic Trackpad, wired** into one of the Studio Display's USB-C ports (iPhone refuses to
  pair it over Bluetooth). Move, click, two-finger scroll, right-click.
- **Any third-party Bluetooth mouse** paired in Settings > Bluetooth. Keep AssistiveTouch
  off; the app reads the mouse directly.
- **The phone's screen**: while docked the lower half of the phone is a trackpad. One
  finger moves, tap clicks, double-tap double-clicks, two fingers scroll, two-finger tap
  right-clicks, hold then move drags or selects text, pinch zooms.

Click links, buttons and form fields as in Safari. Click the URL bar or the + button on the
display to type an address. Click a tab to switch, middle-click to close. Right-click for a
context menu (open in new tab, copy link, copy, paste, back, forward, reload). Drag across
text to select it, then ⌘C. ⌘-click opens a link in a new tab.

If the cursor or scrolling moves the wrong way, flip `mouseDeltaYIsUp` or
`naturalScrolling` in `Sources/Input/PointerController.swift`.

### Keyboard

Normal mode (shown in the status bar on the display):

| Key | Action |
|---|---|
| `f` / `F` | Show link hints; type the label to click / open in a new tab |
| `j` `k` ↓ ↑ | Scroll a line |
| `d` `u` | Scroll half a page |
| `space` / `⇧space` | Scroll a page |
| `gg` / `G` | Top / bottom |
| `H` / `L` | Back / forward |
| `J` / `K` | Previous / next tab |
| `r` | Reload |
| `o` or `/` or ⌘L | Enter a URL or search (typed on the phone field, Enter to go) |
| `t` / `x` | New tab / close tab |
| `Tab` / `⇧Tab` | Move focus between form fields |
| `Esc` | Cancel hints, leave insert mode, stop loading |

Insert mode starts automatically when a text field gets focus (via a hint or Tab). Typing,
Backspace, Enter, Shift+Enter, arrows and Tab go to the page. `Esc` returns to normal mode.
Without a hardware keyboard the phone's on-screen keyboard appears for the same purpose.

Command shortcuts in any mode: ⌘L location, ⌘T new tab, ⌘⇧T reopen closed tab, ⌘W close,
⌘R reload, ⌘[ / ⌘] back/forward, ⌘⇧[ / ⌘⇧] or ⌃Tab / ⌃⇧Tab switch tabs, ⌘1–9 pick a tab,
⌘+ / ⌘− / ⌘0 zoom, ⌘F find (Enter next, ⇧Enter previous, ⌘G / ⌘⇧G), ⌘C / ⌘V / ⌘X / ⌘A
copy, paste, cut, select all.

Downloads land in the Files app under On My iPhone > Display Browser > Downloads. Open
tabs are restored on the next launch.

## Layout

```
project.yml                     XcodeGen project definition (generates DisplayBrowser.xcodeproj)
Config/Local.xcconfig.example   Template for your Personal Team ID
scripts/bootstrap.sh            One-time setup
scripts/deploy.sh               Build + sign + install to the phone (run weekly)
Sources/App/                    AppDelegate and the two scene delegates (phone, display)
Sources/Browser/                BrowserModel (tabs, modes, zoom, scrolling, clipboard, find, downloads), Tab, Bridge
Sources/Input/                  PointerController (virtual cursor), MouseInput (GCMouse), TouchpadView (phone screen)
Sources/UI/                     PhoneViewController (all keyboard input), DesktopViewController (display + pointer dispatch), CursorView, ContextMenuView
Sources/Resources/bridge.js     Injected into pages: link hints, pointer events, selection, focus tracking, text relay
```
