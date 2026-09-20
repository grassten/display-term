# Plan: iPhone → Studio Display "desktop Safari"

**Goal.** Plug an iPhone into an Apple Studio Display and get a full-screen, desktop-class
browser window on the display, driven by an Apple Magic Keyboard over Bluetooth. The phone
itself becomes the dock/controller. Think XeOS ("External Display Browser"), built for one
person's setup, installed from Xcode with a free Apple ID.

**Owner's priorities (19 Sept 2026).** Get something live fast, then make it feel like
macOS Safari on the Studio Display. The owner will plug the Magic Trackpad in by cable, so
pointer support is in scope from the first iteration, with the phone's touchscreen as the
fallback trackpad. History and bookmarks are optional.

**Non-goals (for now).** App Store distribution, running arbitrary iOS apps on the display,
iCloud tab/password sync with real Safari, multi-user features, bookmarks/history UI.

---

## 1. What we are working with (facts, verified Sept 2026)

| Topic | Fact | Consequence |
|---|---|---|
| Stock iOS + external display | iOS only *mirrors* the phone (phone-shaped image between black bars). No desktop mode shipped in iOS 26 or iOS 27 (released 14 Sept 2026). Hidden Stage Manager code seen in 26.1 was removed in 26.2. | We must draw the display ourselves. |
| What apps may do on the display | Apps get a `windowExternalDisplayNonInteractive` scene: full-screen, but **the system delivers no touch/pointer/keyboard input to it**. Interactive external scenes exist only on M-series iPads. Confirmed by Apple DTS. | All input must be captured by the app on the phone side and forwarded into the display window ourselves. This is the core engineering problem. |
| iOS 27 API change | Apps built with the iOS 27 SDK are **no longer offered** the external-display scene from the Info.plist manifest. You must call `registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration:))` on a view controller. Older OS versions still use the manifest. (UTM hit exactly this and ships both paths.) | Support both paths behind `#available(iOS 27, *)`. |
| iPhone video out | iPhone 15 and later (USB-C) output DisplayPort at up to **4K 60 Hz**. Needs a USB 3 capable cable (the in-box cable is USB 2 and will not carry video). | Studio Display is 5K; expect a 3840×2160 (or lower) mode scaled by the display. Pick the best `UIScreen.availableModes` entry ourselves. |
| Studio Display as a hub | The display's upstream port provides power and exposes its downstream USB-C ports, speakers, mic and camera to the host. iPhone charges from it. | The display charges the phone while docked. |
| Magic Trackpad on iPhone | **Bluetooth pairing is refused on iPhone.** Wired, it enumerates to an app through GameController but delivers no input at all unless AssistiveTouch is on (measured 2026-09-20, see below). | Unusable as an app's pointer on iPhone. The phone's screen is the pointer. |
| Magic Mouse on iPhone | Not supported at all. | Out of scope. |
| Magic Keyboard on iPhone | Pairs over Bluetooth like any keyboard; also works wired. Touch ID does not work with iPhone. | Fine. |
| Pointer input to apps | iPhone has no system pointer of its own; AssistiveTouch is the pointer stack, and with it off a pointing device produces no events an app can see — not through `GCMouse`, not as hover or `.indirectPointer` touches, not as scroll events (measured 2026-09-20). `GCKeyboard` is unaffected; keyboards are not routed this way. | The phone's touchscreen is the pointer. A wired trackpad is only usable with AssistiveTouch on, which also confines the deltas to the phone's screen. |
| External camera | UVC (USB webcam) capture is iPad-only. The Studio Display camera will not work as an iPhone camera. | Video calls use the phone's own camera. Display speakers/mic over USB audio should work (verify). |
| Free Apple ID signing | Personal Team: profiles expire after **7 days**, max **3 apps per device**, **10 App IDs per week**, no push/iCloud/associated-domains entitlements, Developer Mode must be on. | Weekly reinstall from the Mac mini. We need none of the restricted entitlements. Automate the redeploy (section 5). |
| XeOS (reference app) | WKWebView-based "desktop" on the display: full-resolution browsing, no black bars, Bluetooth mouse/keyboard support, on-screen trackpad and keyboard on the phone, floating tabs/windows, downloads/PDFs, full-screen video, camera/mic, content blocker, all on-device. v2 added window management and a file system. | Good feature checklist. We can't see their code; the architecture below is our own derivation. |

## 2. Product definition (v1: keyboard-driven)

**When docked** (external display connected):

- Display: one browser "desktop" filling the screen. Tab strip + URL line at the top, page
  below, a one-line status bar at the bottom showing the current mode and key hints.
  Desktop-class rendering (desktop content mode and user agent, page zoom tuned for a 27"
  panel, not phone-sized text). WebKit engine via WKWebView, i.e. Safari's engine.
- Phone: a controller page. Connection status, the URL/search field, and a hidden "relay"
  field that forwards typing into the page. If no hardware keyboard is present the phone's
  on-screen keyboard appears here, so the phone doubles as the keyboard fallback.
- Keyboard model (Vimium-style, because there is no pointer):
  - **Normal mode**: `f` shows link hints (letter labels over every clickable element; type
    the label to click), `F` opens the hinted link in a new tab, `j`/`k`/arrows scroll,
    `d`/`u` half page, `space`/`⇧space` page, `gg`/`G` top/bottom, `H`/`L` back/forward,
    `J`/`K` previous/next tab, `r` reload, `o` open location, `t` new tab, `x` close tab,
    `Tab`/`⇧Tab` move focus between form fields.
  - **Insert mode**: entered automatically when a text field or editor gets focus (via a
    hint or Tab). Typing, Backspace, Enter, Shift+Enter, arrows and Tab go to the page.
    `Esc` leaves insert mode.
  - **Command shortcuts** (any mode): ⌘L location, ⌘T new tab, ⌘W close tab, ⌘R reload,
    ⌘[ / ⌘] back/forward, ⌘⇧[ / ⌘⇧] or ⌃Tab / ⌃⇧Tab switch tabs, ⌘1–9 pick tab,
    ⌘+ / ⌘− / ⌘0 zoom, Esc cancel.

**When undocked**: the app is a plain single-tab phone browser (Apple requires apps to be
functional without the display, and it is how you set things up).

**Persistence**: cookies, logins and history persist in the app's default
`WKWebsiteDataStore`. Nothing syncs with real Safari.

**Pointer** (written, untested): a virtual cursor on the display fed by `GCMouse` (wired
Magic Trackpad or any Bluetooth mouse) or by the phone's touchscreen. Clicks, double-clicks,
right-click menu, hover, scroll into nested scroll areas, drag-select, ⌘-click and
middle-click for new tabs, clickable toolbar and tabs.

**Also written**: find in page, clipboard shortcuts, downloads to the Files app, session
restore, URL typing echoed on the display's URL bar.

**Deferred**: floating windows, content blocker, bookmarks/history, reader mode.

## 3. Architecture

```
┌───────────────── iPhone ─────────────────┐    ┌──────── Studio Display ────────┐
│ PhoneScene (windowApplication)           │    │ DisplayScene                    │
│  PhoneViewController: status, URL field, │    │  (windowExternalDisplayNon-     │
│  hidden relay field (insert mode)        │    │   Interactive, full screen)     │
│                                          │    │  DesktopViewController          │
│  Hardware keyboard ──► UIKeyCommand +    │    │   ├─ tab strip + URL line       │
│  pressesBegan (normal mode) or relay     │───►│   ├─ WKWebView (active tab)     │
│  field (insert mode)                     │    │   └─ status bar (mode, hints)   │
│                                          │    │                                 │
│ BrowserModel (shared): tabs, mode, zoom, │    │  bridge.js (user script): link  │
│  native scrolling, navigation            │    │   hints, focus tracking, text   │
│                                          │    │   insertion, caret, focus-next  │
└──────────────────────────────────────────┘    └─────────────────────────────────┘
```

Key decisions:

1. **UIKit app lifecycle** (AppDelegate + scene delegates), SwiftUI for the phone-side
   controller UI. Scene roles need UIKit-level control; SwiftUI's external-display support
   on iOS 27 is via the same accessory API and can be adopted later.
2. **One display-side window**, `UIWindow(windowScene:)` sized to the chosen `UIScreenMode`,
   `overscanCompensation = .none`. This is what removes the black bars.
3. **Browser engine = WKWebView** with `preferredContentMode = .desktop`, optional custom
   desktop UA, `pageZoom` for display-appropriate scaling, `allowsInlineMediaPlayback`,
   `isElementFullscreenEnabled`, `WKDownload` delegate, `createWebViewWith` → new tab,
   `requestMediaCapturePermissionFor` → allow camera/mic, default (persistent) data store.
4. **All keyboard input is captured on the phone scene**, which is the scene iOS
   actually delivers hardware-keyboard events to. `UIKeyCommand`s handle ⌘-shortcuts in
   every mode; `pressesBegan` handles unmodified normal-mode keys; a hidden `UITextField`
   ("relay") is first responder in insert mode and forwards each keystroke to the page.
   This avoids betting on keys reaching the non-interactive display scene. If a later
   spike shows the display window can be made key and receive typing natively, insert
   mode can be simplified.
5. **Scrolling is native**: the app drives `webView.scrollView` directly, so `j`/`k`/space
   work on every page regardless of JavaScript.
6. **Everything else goes through `bridge.js`**, a `WKUserScript` injected at document
   start: link hints (collect visible clickables, label them, click or focus on match),
   focus tracking (`focusin`/`focusout` → native, switching normal/insert mode), text
   insertion (`execCommand('insertText')`), Backspace, Enter (submit form / new paragraph),
   caret movement and Tab focus cycling. Synthesised events are `isTrusted: false`; sites
   that gate on user activation (fullscreen, popups, autoplay-with-sound, file pickers)
   need native assists later (see risks).
7. **Pointer support is additive**: when it comes, a cursor layer plus `elementFromPoint`
   click injection slot into the same bridge; nothing in v1 needs to be undone.

## 4. Milestones

Each milestone ends with something installable and a short acceptance test on the real
hardware. The order is chosen to get a usable keyboard-driven browser on the display as
early as possible.

### M0 — Scaffold and redeploy loop — *done in this repo*
- Xcode project generated from `project.yml` (XcodeGen) so the project file stays
  reviewable in git. Bundle ID fixed once (free accounts get only 10 App IDs per week).
  Deployment target iOS 26; iOS 27 scene-accessory path behind `#available`.
- `scripts/bootstrap.sh` (one-time setup) and `scripts/deploy.sh` (build, sign with the
  Personal Team, install to the phone over USB or Wi‑Fi with `devicectl`).
- **Accept:** app installs and launches from the Mac mini with one command.
- First real deploy (2026-09-19, Mac mini, Xcode 27 beta, iPhone 15 Pro Max
  `00008130-00164D122EA2001C`): builds, signs and installs clean. Two setup traps found:
  `DEVELOPMENT_TEAM` is the certificate's `OU=` field, not the ID in parentheses in `CN=`;
  and DerivedData must live outside this iCloud-synced checkout or codesign rejects the
  `.app` for `com.apple.FinderInfo`. Both are fixed in `scripts/deploy.sh` and CLAUDE.md.
  Remaining manual step on a fresh install: trust the developer profile on the phone.
- Wi-Fi deploy verified 2026-09-19 with the phone unplugged (no iPhone on USB;
  `devicectl` reports `transportType: localNetwork`, `tunnelState: connected`). Full
  `scripts/deploy.sh` loop — xcodegen, incremental build, sign, install, launch — takes
  ~16s; the install step alone ~1.6s. The phone must be unlocked for the launch to be
  accepted, otherwise `devicectl` reports `Locked`.

### M1 — First live iteration: full-screen page + keyboard + pointer — *written, needs on-device testing*
- External scene via Info.plist manifest (iOS 26) and `UISceneAccessory` (iOS 27).
- Best `UIScreenMode` selected, overscan compensation off, WKWebView in desktop mode with
  zoom tuned for the panel; tab strip, URL line and status bar drawn on the display.
- Normal/insert modes, link hints, native scrolling, tab management and all ⌘-shortcuts from
  section 2, all captured on the phone scene.
- Pointer: `GCMouse` + phone touchpad → `PointerController` → `DesktopViewController`
  (hit-tests chrome vs page) → `bridge.js` synthesises pointer/mouse events. Right-click
  menu, selection, clipboard, find, downloads, session restore.
- **Accept:** on the Studio Display, open a URL with ⌘L, follow links with `f`, log into
  claude.ai and hold a conversation by typing in insert mode, switch tabs, scroll, without
  touching the phone. Record the display mode the link negotiates and which keys (if any)
  fail to arrive.

### Decision (2026-09-19, after the first hour on hardware): no modal keyboard

The vim-style NORMAL/INSERT scheme in section 2 is removed. It was scaffolded before anyone
used the thing, and in practice it made the browser unusable: clicking a text field and
typing produced commands instead of text, so `t` opened a tab while the owner was trying to
type an email address. Typing now always goes to the page, single letters are never
commands, and every shortcut lives on the Command key as in Safari. Arrow keys and space
scroll only when no page field has focus. Link hints (`f`) are gone with the mode that
carried them; the pointer covers that ground now.

### Constraint found 2026-09-19: passkeys are out of reach

WKWebView performs a passkey assertion only when the app holds Associated Domains with
`webcredentials:` for the site, which in turn requires that site to publish an
apple-app-site-association file naming the app. A third-party browser can never satisfy that
for a domain it does not own, and a free Personal Team cannot hold the entitlement anyway.
Safari, SFSafariViewController and ASWebAuthenticationSession are privileged by the system.
ASWebAuthenticationSession is not a workaround either: it uses Safari's cookie store, so a
sign-in completed there does not carry a session into our web view. Passwords are fine -
they are ordinary web-form AutoFill and need no entitlement. Log in with a password or an
emailed code.

### Constraint found 2026-09-19: no pointer lock on iPhone, so keep the app foreground

`prefersPointerLocked` is honoured on iPad only. On the iPhone the window scene's
`pointerLockState` stays nil no matter when the lock is requested, confirmed in the log with
the scene foreground-active and a mouse attached. So the pointer cannot be decoupled from
AssistiveTouch's system cursor, which is confined to the phone's own screen.

That matters because `GCMouse` delivers only to the foreground app. After roughly an inch of
swiping, the system cursor reaches a screen edge, a system gesture fires, the app is
backgrounded and the trackpad goes dead mid-motion - the scene log shows willDeactivate then
didEnterBackground with the phone scene at state 2. Guided Access (triple-click the side
button) pins the app foreground and disables those gestures, which is the right mode for a
docked browser regardless.

### Decision (2026-09-19): the phone screen is the only pointer on iPhone

The wired Magic Trackpad is disabled. On iPhone, pointing devices deliver input only through
AssistiveTouch, whose cursor is confined to the phone's own screen; `GCMouse` deltas are that
cursor's movement, so they fall to zero when it pins against the phone's edge with most of
the display still unreached. Proportional mapping of the phone screen onto the display made
every pixel reachable, and the owner still called it too janky, which is fair. Pointer lock
would fix this and exists on iPad only. `MouseInput` stays in the tree behind
`PointerController.Settings.externalPointingDevices` for that case. M5 is closed for iPhone.

### Measured 2026-09-20: a trackpad cannot work without AssistiveTouch, and why

The decision above reasoned that GCMouse deltas *are* the AssistiveTouch cursor's movement,
so they die at the phone's screen edges. Measured with AssistiveTouch off, on the real
hardware, that is wrong in a way that matters: there are no deltas at all.

iOS does enumerate the device to the app. With AssistiveTouch off, GameController reports
`GCMouse.current` = "Magic Trackpad" with left and right buttons, and re-reports it on every
scene activation. What it never delivers is input. Over a full session with the phone scene
foreground-active, the app active, the view first responder and that trackpad current:

```
[Mouse] attached: Magic Trackpad total=1 buttons=left+right assistiveTouch=false
[Heartbeat] phoneScene=0 app=0 idleTimerDisabled=true firstResponder=true
            current=Magic Trackpad  Magic Trackpad · raw · no motion · 0 clicks, 0 scrolls
            hover=0 indirectPan=0 scroll=0
```

Zero on every channel, and three separate channels were watched at once: GameController
deltas, UIKit hover and `.indirectPointer` touches, and scroll events through a touch-less
pan recogniser (the route UTM uses for trackpad scrolling on iOS). Not one event of any
kind, clicks included. A trackpad reporting its buttons but not its motion would have meant
only the pointer layer was missing; silence on all of them means the device is enumerated
but is not ours.

So AssistiveTouch is not one way to read the device, it is the only one. It owns the
pointer stack on iPhone, and with it off nothing converts that hardware's finger tracking
into events an app can see. `prefersPointerLocked`, which on iPad lets an app take the
device directly, is honoured on iPad only (`pointerLockState` stays nil here, confirmed
again in this session). Checked and ruled out along the way: the app is foreground
throughout (`GCController.shouldMonitorBackgroundEvents` is documented as ignored on iOS);
`UIApplicationSupportsIndirectInputEvents` is now declared, as UTM declares it, and changes
nothing; `GCEventInteraction`, the only new way to claim device events, covers gamepads and
(on visionOS) styluses, not mice.

What stays in the tree from this: the pointer policy now follows
`UIAccessibility.isAssistiveTouchRunning` live, so the trackpad is a free relative pointer
with raw deltas wherever those arrive and falls back to the phone-screen mapping while
AssistiveTouch is on; attachment happens on "did become current" as well as on connect; and
`scripts/trackpad-probe.sh` reruns the whole measurement in one command. The phone's screen
remains the pointer on iPhone.

Untested, and the only remaining lead worth a session: with AssistiveTouch **on**, now that
the app declares `UIApplicationSupportsIndirectInputEvents`, its cursor may deliver hover or
`.indirectPointer` touches carrying an absolute position. That would replace the
proportional mapping with the system cursor's actual coordinates and remove the drift and
re-syncing that made it feel bad. The probe already counts them; it needs one run with
AssistiveTouch enabled.

### Findings and decisions (2026-09-19, evening): the pointer rework

The owner's report after a day: clicks sometimes selected text instead of clicking, some
buttons did nothing, and the "Sign in with Google" prompt could not be clicked at all.
Causes found in the code and in WebKit, and what was done:

- **Accidental double-clicks.** The touchpad counted any two taps within 0.35 s as a
  double-click regardless of where they landed, and the tap and long-press recognisers
  both fired for a slow tap. A double-click on a button or a `div` selected the word under
  the cursor, which is the "selects the text" symptom. `TouchpadView` now classifies raw
  touches itself (tap = down/up within 0.3 s and 10 pt; hold still 0.35 s = press; two
  quick taps are a double-click only when they land within 40 display points) and the
  cursor shows a blue ring on every click so nobody taps twice to be sure.
- **Selection placed on every mousedown.** `bridge.js` put a collapsed caret range into the
  page on each press, firing `selectionchange` and leaving stray carets. The selection is
  now created only once the pointer actually drags, and never on buttons, links, form
  controls or `user-select: none` content. Pressing a button also no longer blurs the
  focused text field (Safari on macOS behaviour), so the composer keeps the keyboard after
  its Send button is clicked.
- **Cross-origin iframes were unreachable.** `elementFromPoint` stops at the `<iframe>`
  element and events dispatched to it never enter the framed document. Google Identity
  Services renders both the button and the One Tap prompt in an iframe from
  accounts.google.com, so nothing in them could be clicked. The script is now injected
  into every frame, in its own `WKContentWorld`, and the top frame forwards pointer, scroll,
  probe and text-input calls into frames (direct call when same-origin, `postMessage` with
  a per-launch token otherwise). Frames report focus, cursor shape, right-clicks and
  clipboard text back by message. Verified in `scripts/bridge-harness` with two local
  origins. XeOS, the reference app, documents this exact limitation ("almost impossible")
  and offers no fix.
- **Popups blocked.** WebKit's popup blocker (`allowPopUp()`) requires a user gesture or
  `javaScriptCanOpenWindowsAutomatically`, which defaults to NO on iOS. Synthetic clicks
  carry no gesture, so `window.open` and `target=_blank` links silently did nothing.
  The preference is now on; popups become tabs through `createWebViewWith`.
- **Shadow DOM.** `elementFromPoint` returns the host, so web components (YouTube, most
  Google properties, Material) never received the events. Hit testing now descends through
  `shadowRoot.elementFromPoint`, and ancestry walks step out through `getRootNode().host`.
- **`<select>` and file inputs.** `HTMLSelectElement::menuListDefaultEventHandler` ignores
  untrusted events, and on macOS a synthetic mousedown on a select still opened the native
  popup and blocked the main thread (found by the harness). Selects get no mouse events at
  all; the options are reported to the native side and drawn as a scrollable menu on the
  display, and arrows change the value when one is focused. `FileInputType` requires a
  real user gesture: file pickers cannot open from the display; the status bar says to use
  *Type on phone*. CSS `:hover` is likewise not updatable from script; hover-only menus
  stay closed.
- **Momentum and acceleration.** Two-finger scrolling now flings with 0.96/frame decay and
  locks to the dominant axis; cursor speed is velocity-based (base gain 3, up to 4x for a
  flick) so a slow finger is precise and one swipe still crosses the 4K panel.
- **Considered and not done: trusted events.** Private `UITouch` injection (KIF-style,
  still working on iOS 26 in-process) would make events trusted and fix hover, selects and
  file pickers, but it is unproven against a window on a secondary `UIScreen`, and touches
  in a desktop-mode WKWebView scroll on drag rather than select. Kept as a future
  experiment. Google additionally blocks sign-in inside web views by policy (UA and
  automation heuristics), which no event fidelity fixes.

### M2 — Fixes from first use (1–2 days)
- Whatever M1 shows: keys that never arrive, sites whose inputs reject the bridge, hint
  labels on hidden elements, zoom defaults, display reconnect glitches.
- Find in page (⌘F via `WKWebView.find`), reopen closed tab (⌘⇧T), history-based URL
  autocomplete on the phone field.
- **Accept:** a normal day of browsing with no dead ends.

### M3 — Browser features (2–3 days)
- Downloads (`WKDownload`) with export to Files, PDF viewing, popups → new tab (already
  wired), full-screen video plus a native "fill the display with the video" assist for sites
  that reject synthetic activation, camera/mic permission pass-through, Picture in Picture,
  per-site mobile/desktop UA toggle.

### M4 — Reliability (1–2 days)
- Cable unplug/replug, auto-lock while docked (`isIdleTimerDisabled`), memory pressure with
  many tabs, `WKWebView` process crash recovery, session restore.
- Content blocker via `WKContentRuleList` (optional).

### M5 — Pointer polish (after first use)
- Tune gain/acceleration and scroll direction from real use; verify `GCMouse` sees the wired
  Magic Trackpad on iPhone (with AssistiveTouch off) and that two-finger scroll arrives via
  `GCMouseInput.scroll`. If not, the phone touchpad is the pointer until a fix is found.
- Drag and drop, native-feeling text selection in inputs, cursor shapes for resize/grab.

### M6 — Stretch
- Two side-by-side windows or floating windows (XeOS-style), Studio Display speakers/mic
  routing, share-sheet "open on the display", keyboard-driven text selection.

## 5. Weekly redeploy (free Apple ID)

- `scripts/deploy.sh` builds, signs with the Personal Team and installs over USB or Wi‑Fi
  with `devicectl`. Run it every ≤7 days; the app keeps its data across reinstalls.
- Optional: a `launchd` agent on the Mac mini that runs the script every 6 days while the
  phone is on the same Wi‑Fi (documented in `docs/redeploy.md`).
- Alternative that avoids the Mac after setup: SideStore (or AltStore) refreshes free-account
  apps automatically on-device; still 7-day certs and the 3-app cap.
- Upgrade path: a paid developer account ($99/yr) makes profiles last a year and lifts the
  3-app cap. Nothing in this plan depends on it.

## 6. Risks and mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Some hardware keys never reach `pressesBegan`/`UIKeyCommand` on the phone scene (historically Tab and arrows were flaky in WKWebView, less so in plain UIKit) | Low–Medium | Verified on device in M1; `GCKeyboard` is the fallback for raw key state. |
| Insert-mode relay breaks on sites with custom editors (Google Docs, some chat apps) | Medium | Bridge dispatches keydown/keyup around each insertion; per-site fallback is the phone's own screen. |
| A wireless pointer later: Magic Trackpad/Mouse refuse Bluetooth on iPhone | Certain | Third-party Bluetooth mouse or phone-as-trackpad (M5). |
| Synthetic clicks lack user activation (fullscreen, popups, autoplay with sound, file pickers) | High | Native assists: our own "fill display with video" mode, `createWebViewWith` handles popups natively, phone-side taps for file pickers. |
| iPhone→Studio Display negotiates a low mode or nothing | Low–Medium | Verify in M1 with a USB 3 or Thunderbolt cable; expose mode picker in settings. |
| iOS 27 scene accessory API differs from docs | Low | UTM's PR is a working reference; keep the iOS 26 manifest path as a fallback. |
| Site breakage from `isTrusted: false` events | Medium | Test the user's real sites early (M3); keep a per-site "mobile UA" and "tap on phone" escape hatch. |
| Battery/thermal while docked at 4K | Low | The display powers the phone; suspend background tabs. |

## 7. Decisions and open questions

Decided by the owner on 19 Sept 2026:

- No wired peripherals. Keyboard over Bluetooth; trackpad deferred.
- Keyboard-only navigation is acceptable for v1; priority is getting something live.

Decided on 19 Sept 2026 (second round):

- Hardware: iPhone 15 on iOS 27, first-generation (2022) Studio Display, Thunderbolt cable.
  iPhone 15 outputs DisplayPort at up to 4K 60 Hz over that cable; the display scales it.
- Tabs in one window for v1. No floating windows.
- The phone's touchscreen as a fallback trackpad is wanted (M5 stays in the plan, pulled
  forward once the keyboard iteration is live).
- Must-work sites: claude.ai first, then the everyday set (Hacker News, Gmail, YouTube).
  claude.ai uses a ProseMirror contenteditable composer, so it is also the first real test
  of the insert-mode relay (text insertion via `execCommand`, Enter via synthetic keydown).
- App name and bundle ID: keep the defaults (`DisplayBrowser`, `com.grassten.displaybrowser`).
- Default search engine: Google.

Nothing is blocking. Next step is the first on-device build.

## 8. Sources

- Apple, *Presenting content on a connected display* (iOS 27 scene accessory behaviour, non-interactive role):
  https://developer.apple.com/documentation/uikit/presenting-content-on-a-connected-display
- Apple, `UISceneAccessory` (iOS 27.0+): https://developer.apple.com/documentation/uikit/uisceneaccessory
- Apple, `UISceneSession.Role.windowExternalDisplayNonInteractive` (iOS 16.0+):
  https://developer.apple.com/documentation/uikit/uiscenesession/role-swift.struct/windowexternaldisplaynoninteractive
- Apple DTS on iPhone external displays being non-interactive: https://developer.apple.com/forums/thread/773838
- Apple, `GCMouse` (iOS 14.0+): https://developer.apple.com/documentation/gamecontroller/gcmouse
- Apple, *Bring keyboard and mouse gaming to iPad* (GCMouse/GCKeyboard, iPhone has no pointer interaction):
  https://developer.apple.com/videos/play/wwdc2020/10617/
- UTM PR fixing external display under the iOS 27 SDK: https://github.com/utmapp/UTM/pull/7873
- Apple, *Charge and connect with the USB-C connector on your iPhone* (DisplayPort, 4K60, USB 3 cable):
  https://support.apple.com/en-us/105099
- 9to5Mac on iPhone 15 USB-C external displays incl. Studio Display: https://9to5mac.com/2023/09/16/iphone-15-usb-c-external-displays/
- Apple, *Set up and use Apple Studio Display*: https://support.apple.com/en-us/102286
- Magic Trackpad with iPhone (wired only): https://discussions.apple.com/thread/255189265
- Apple, *Use a pointer device with AssistiveTouch*: https://support.apple.com/en-us/111775
- AssistiveTouch pointer bug in landscape on iPhone (why we avoid relying on it): https://developer.apple.com/forums/thread/786963
- WKWebView fullscreen needs a real user gesture (feature request FB17301399): https://developer.apple.com/forums/thread/781675
- External UVC cameras are iPad-only: https://developer.apple.com/forums/thread/775883
- XeOS product page and App Store listing: https://externaldisplayiphone.com/ ,
  https://apps.apple.com/us/app/external-display-browser-xeos/id6758286241
- "No desktop mode in iOS 26/27" (XeOS blog, plus MacRumors iOS 27 coverage):
  https://externaldisplayiphone.com/blog/did-ios-26-add-desktop-mode ,
  https://www.macrumors.com/2026/09/14/ios-27-features-available-tomorrow/
- Free Personal Team limits: https://developer.apple.com/support/compare-memberships/ ,
  https://mybyways.com/blog/new-limitations-imposed-on-free-apple-developer-account/
- SideStore auto-refresh: https://techybuff.com/refresh-sidestore-sideloaded-automode/
