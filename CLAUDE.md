# CLAUDE.md — operating guide for this repo

Read this first. It tells you what the project is, which environment you are in, and the
exact procedure to build, install and debug the app on the owner's iPhone so the owner does
not have to type commands.

## What this is

An iPhone app (`DisplayBrowser`) that puts a full-screen, Safari-like WKWebView browser on
an external display (Apple Studio Display, first gen, Thunderbolt cable). The phone is the
controller; iOS delivers no input to the external-display scene, so every keystroke and
pointer event is captured on the phone side and forwarded. `PLAN.md` has the constraints,
architecture and milestones. `README.md` has the user-facing cheat sheet.

Owner's setup: iPhone 15 on iOS 27, Mac mini with Xcode 27, free Apple ID (Personal Team,
7-day provisioning profiles, no paid developer program). Magic Keyboard over Bluetooth.
Magic Trackpad wired into the Studio Display's USB-C port (iPhone will not pair it over
Bluetooth). First must-work site: claude.ai. Goal: "macOS Safari on the Studio Display".

## Which environment am I in?

- **Cloud session (Linux container, no Xcode):** you can edit code, update docs, commit and
  push. You cannot build, install or test. Say so plainly; do not claim a build succeeded.
- **Mac mini session (macOS, Xcode installed):** you can and should run the full loop below
  yourself. The owner does not want to run commands. Ask only for things that need a finger
  on the phone (trust prompts, Developer Mode toggle, plugging in the display).

Check with: `uname -s` (Darwin = Mac mini) and `xcode-select -p`.

## Repository layout

```
project.yml                     XcodeGen definition. NEVER hand-edit a .xcodeproj; edit this and regenerate.
Config/Local.xcconfig.example   Template. The real Config/Local.xcconfig is git-ignored and holds DEVELOPMENT_TEAM.
scripts/bootstrap.sh            One-time: creates Local.xcconfig, runs xcodegen.
scripts/deploy.sh               Build + sign + install + launch on the phone. Run weekly (profile expires in 7 days).
Sources/App/                    AppDelegate, PhoneSceneDelegate, DisplaySceneDelegate
Sources/Browser/                BrowserModel (tabs, modes, zoom, scrolling, pointer→JS, clipboard, find, downloads, session), Tab, Bridge
Sources/Input/                  PointerController (cursor state, click counting), MouseInput (GCMouse), TouchpadView (phone screen)
Sources/UI/                     PhoneViewController (ALL keyboard input + touchpad), DesktopViewController (display chrome, PointerSurface: hit-tests chrome vs page), CursorView, ContextMenuView, RelayTextField
Sources/Resources/bridge.js     Injected user script: link hints, pointer/mouse event synthesis, scrollAt, probe (cursor shape, link, selection), selection/clipboard helpers, focus tracking, text insertion
```

Bundle ID: `com.grassten.displaybrowser` (set in `project.yml`). Do not change it: free
accounts get 10 App IDs per week and changing it burns one and loses app data.

## Build, install and run on the phone (Mac mini)

Prerequisites, once:

```bash
brew install xcodegen
scripts/bootstrap.sh                       # creates Config/Local.xcconfig + generates the .xcodeproj
# DEVELOPMENT_TEAM is the OU= field of the signing certificate, not the ID in parentheses:
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

Put the team ID in `Config/Local.xcconfig`. If no "Apple Development" identity exists, the
owner must sign in to Xcode once (Xcode > Settings > Accounts > add Apple ID); Xcode then
creates the Personal Team certificate. Ask the owner to do that step; it needs their password.

On the phone, once: Settings > Privacy & Security > Developer Mode on (reboots); connect to
the Mac by USB once and tap Trust; after the first install, Settings > General > VPN & Device
Management > trust the developer app. Tell the owner exactly which of these prompts to tap.

Every deploy:

```bash
scripts/deploy.sh                          # picks the first paired iPhone; DEVICE=<udid> to choose
```

The script: regenerates the project, builds Debug with `-allowProvisioningUpdates`, writes the
full log to `build/xcodebuild.log`, installs with `xcrun devicectl device install app`, then
launches the app. On failure it prints the `error:` lines. Fix the code, re-run. Do not edit
the generated `.xcodeproj`.

DerivedData deliberately lives at `~/Library/Developer/Xcode/DerivedData/DisplayBrowser-deploy`,
outside the repo. This checkout sits on the Desktop, which is iCloud-synced (Desktop &
Documents), and the iCloud file provider stamps `com.apple.FinderInfo` on the built `.app`.
Codesign then fails with `resource fork, Finder information, or similar detritus not allowed`.
Do not move the build back inside the repo. Override with `DERIVED=<path>` if needed.

Find the device UDID if needed:

```bash
xcrun devicectl list devices
```

## Reading the app's log (this is how you learn what the display negotiated)

Launch with console attached to see `NSLog` output live:

```bash
BUNDLE_ID=com.grassten.displaybrowser
UDID=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["hardwareProperties"]["udid"] for x in d["result"]["devices"] if x["hardwareProperties"].get("platform")=="iOS"))')
xcrun devicectl device process launch --console --terminate-existing --device "$UDID" "$BUNDLE_ID"
```

Look for `[Display] modes: [...] using WxH scale=… bounds=…` when the display is plugged in.
Record that line in `PLAN.md` under M1 the first time you see it.

Wi‑Fi works for install and launch once the phone has been paired over USB and both are on
the same network, so the owner can leave the phone docked to the display.

## Verification checklist after each deploy (M1 acceptance)

Ask the owner to have the display connected and the keyboard paired, then walk through and
record results (works / fails / notes) in `PLAN.md`:

1. Display shows the browser full-screen with no black bars; phone shows "Docked".
2. ⌘L, type `claude.ai`, Enter → page loads on the display.
3. `f` shows hint labels; typing one clicks the element.
4. Tab / Shift-Tab move focus between fields; arrows and space scroll in NORMAL mode.
5. Focus the claude.ai composer (hint or Tab) → badge turns green (INSERT); typing appears in
   the composer; Enter sends; Esc returns to NORMAL.
6. ⌘T, ⌘W, ⌘1–9, ⌘⇧[ / ⌘⇧] switch tabs; ⌘+ / ⌘− zoom.
7. Unplug the display → page returns to the phone; replug → back on the display.
8. Pointer via the phone touchpad: cursor visible on the display, tap clicks a link, two
   fingers scroll, two-finger tap opens the context menu, clicking the URL bar focuses the
   phone's URL field, clicking a tab switches.
9. Pointer via the wired Magic Trackpad: **AssistiveTouch must be on** (Settings >
   Accessibility > Touch > AssistiveTouch) or no movement events arrive at all, even though
   `[Mouse] connected` still logs. The phone status line shows "mouse". Same checks as 8. If
   the cursor moves inverted or scrolling is backwards, flip `mouseDeltaYIsUp` /
   `naturalScrolling` in `PointerController.Settings`.
10. ⌘F find, ⌘C on a drag-selected passage then ⌘V into a text field, a file download
    appearing in Files.

Known likely first-run issues: iOS 27 `UISceneAccessory` API names (see
`PhoneViewController.registerDisplayAccessoryIfNeeded`), Tab/arrow keys not reaching
`pressesBegan`, claude.ai's ProseMirror editor ignoring the relayed Enter, `GCMouse` not
reporting the wired trackpad on iPhone (then use the phone touchpad and investigate
AssistiveTouch on/off), wrong sign on mouse deltas or scroll.

## Weekly redeploy (free account limitation)

The provisioning profile expires 7 days after each install and the app stops launching.
Re-run `scripts/deploy.sh` before then. To automate on the Mac mini, install a launchd agent
that runs it every 6 days while the phone is on Wi‑Fi (not yet set up; add
`scripts/install-launchd.sh` when asked).

## Conventions

- Swift 5 language mode, UIKit lifecycle, no third-party dependencies, no SwiftUI yet.
- All keyboard handling lives in `PhoneViewController`; the display scene receives no
  system input. Pointer events reach `DesktopViewController` only through `PointerSurface`.
- Pointer coordinates: `PointerController.position` is in display-window points;
  `DesktopViewController` converts to web-view points and `BrowserModel.cssPoint` divides by
  `pageZoom` before anything is sent to `bridge.js`.
- Anything that talks to the page goes through `bridge.js` and `Bridge.swift`; keep the
  `window.__db` API in sync between them.
- Native scrolling (`BrowserModel.scroll`) is preferred over JavaScript scrolling.
- Commit small, descriptive changes. Update `PLAN.md` when a milestone's status changes or a
  decision is made. Do not put model identifiers in commits or code.
- `main` is the deployable branch. Work on a feature branch, merge when it builds.
