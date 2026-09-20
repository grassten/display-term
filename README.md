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

**The phone's screen is the trackpad.** While docked, the lower part of the phone is a
touch surface: one finger moves, tap clicks, double-tap double-clicks, two fingers scroll,
two-finger tap right-clicks, hold then move drags or selects text, pinch zooms. Leave
AssistiveTouch **off**; it is not needed for this and its floating button only gets in the
way.

A Magic Trackpad or mouse is deliberately not supported on iPhone, after trying it. iPhone
has no pointer system of its own: the only way a pointing device produces input at all is
through AssistiveTouch, whose cursor is confined to the phone's own screen. `GCMouse`
deltas are that cursor's movement, so once it pins against the phone's edge they drop to
zero with most of the display still ahead. Mapping the phone screen proportionally onto the
display made every pixel reachable but felt bad, and pointer lock, which fixes this on iPad,
does not exist on iPhone. The code path is kept behind
`PointerController.Settings.externalPointingDevices` for an iPad, where none of this applies.

Click links, buttons and form fields as in Safari. Click the URL bar or the + button on the
display to type an address. Click a tab to switch, middle-click to close. Right-click for a
context menu (open in new tab, copy link, copy, paste, back, forward, reload). Drag across
text to select it, then ⌘C. ⌘-click opens a link in a new tab.

If the cursor or scrolling moves the wrong way, flip `mouseDeltaYIsUp` or
`naturalScrolling` in `Sources/Input/PointerController.swift`.

### Keyboard

It behaves like a normal browser. Typing always goes to the page - there is no mode to
enter or leave, and single letters are never commands. Every shortcut is on the Command
key, as in Safari:

⌘L location, ⌘T new tab, ⌘⇧T reopen closed tab, ⌘W close tab, ⌘R reload, ⌘[ / ⌘] back and
forward, ⌘⇧[ / ⌘⇧] or ⌃Tab / ⌃⇧Tab switch tabs, ⌘1-9 pick a tab, ⌘+ / ⌘- / ⌘0 zoom,
⌘F find (Enter next, ⇧Enter previous, ⌘G / ⌘⇧G), ⌘C / ⌘V / ⌘X / ⌘A copy, paste, cut,
select all.

Arrow keys, space, Page Up/Down, Home and End scroll the page when no text field has
focus, and move the caret or type a space when one does. Tab moves between form fields.
Esc drops focus out of a field and closes the find bar.

Close a tab with the x on the tab itself, with ⌘W, or by middle-clicking it.

### Saved passwords (iCloud Keychain)

iOS only offers AutoFill to a web view that is genuinely first responder with the system
keyboard up. The external display scene receives no input at all, so iOS never sees a
focused password field there and never offers to fill one. The `ASAuthorization` route is
also closed: it needs the Associated Domains entitlement, which a free Personal Team cannot
have.

So the page comes to you instead. Tap **Type on phone (AutoFill passwords)** on the phone
while docked and the active tab moves to the phone as an ordinary web view: tap the login
field, pick the password from the QuickType bar, confirm with Face ID, then tap **Send page
back to display**. It is the same web view being reparented, so the tab, its session and its
scroll position all survive the round trip.

⌘V also works if you would rather copy a password out of the Passwords app by hand.

**Passkeys do not work and cannot be made to work here.** WKWebView only performs a passkey
assertion when the app holds the Associated Domains entitlement carrying `webcredentials:`
for that exact site, and that entitlement is only honoured when the site itself publishes an
apple-app-site-association file naming your app. No third-party browser can satisfy that for
someone else's domain, and a free Personal Team cannot hold the entitlement at all. Safari,
SFSafariViewController and ASWebAuthenticationSession get passkeys because the system trusts
them specifically. Sign in with a password or an emailed code instead.

### Dark mode

On by default; ⌘⇧D toggles it. The web view reports `prefers-color-scheme: dark` to pages,
so any site with a dark theme picks it up on its own, and the page background behind it is
dark too so there is no white flash on load. Sites with no dark theme still render light -
forcing those would mean inverting their colours, which is not done here.

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
