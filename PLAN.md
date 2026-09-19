# Plan: iPhone → Studio Display "desktop Safari"

**Goal.** Plug an iPhone into an Apple Studio Display and get a full-screen, desktop-class
browser window on the display, driven by an Apple Magic Keyboard and Magic Trackpad. The
phone itself becomes a dock/controller. Think XeOS ("External Display Browser"), built for
one person's setup, installed from Xcode with a free Apple ID.

**Non-goals (for now).** App Store distribution, running arbitrary iOS apps on the display,
iCloud tab/password sync with real Safari, multi-user features.

---

## 1. What we are working with (facts, verified Sept 2026)

| Topic | Fact | Consequence |
|---|---|---|
| Stock iOS + external display | iOS only *mirrors* the phone (phone-shaped image between black bars). No desktop mode shipped in iOS 26 or iOS 27 (released 14 Sept 2026). Hidden Stage Manager code seen in 26.1 was removed in 26.2. | We must draw the display ourselves. |
| What apps may do on the display | Apps get a `windowExternalDisplayNonInteractive` scene: full-screen, but **the system delivers no touch/pointer/keyboard input to it**. Interactive external scenes exist only on M-series iPads. Confirmed by Apple DTS. | All input must be captured by the app on the phone side and forwarded into the display window ourselves. This is the core engineering problem. |
| iOS 27 API change | Apps built with the iOS 27 SDK are **no longer offered** the external-display scene from the Info.plist manifest. You must call `registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration:))` on a view controller. Older OS versions still use the manifest. (UTM hit exactly this and ships both paths.) | Support both paths behind `#available(iOS 27, *)`. |
| iPhone video out | iPhone 15 and later (USB-C) output DisplayPort at up to **4K 60 Hz**. Needs a USB 3 capable cable (the in-box cable is USB 2 and will not carry video). | Studio Display is 5K; expect a 3840×2160 (or lower) mode scaled by the display. Pick the best `UIScreen.availableModes` entry ourselves. |
| Studio Display as a hub | The display's upstream port provides power and exposes its downstream USB-C ports, speakers, mic and camera to the host. iPhone charges from it. | Keyboard/trackpad can plug into the display; one cable to the phone. |
| Magic Trackpad on iPhone | **Bluetooth pairing is refused on iPhone.** Works **wired** (USB-C cable, or Lightning-to-USB-C for older trackpads) as a pointer device. | Trackpad goes into a Studio Display USB-C port. Must verify the app sees it (see spike M2). |
| Magic Mouse on iPhone | Not supported at all. | Out of scope. |
| Magic Keyboard on iPhone | Pairs over Bluetooth like any keyboard; also works wired. Touch ID does not work with iPhone. | Fine. |
| Pointer input to apps | iPhone has no system pointer (`UIPointerInteraction`/hover are iPad only). With AssistiveTouch on, a mouse moves a fake finger on the phone screen. The GameController framework's `GCMouse`/`GCKeyboard` (iOS 14+) deliver raw deltas/keys to the foreground app. | Plan A: `GCMouse` deltas drive our own cursor drawn on the display. Plan B: phone screen as a touch trackpad. Both need a spike. |
| External camera | UVC (USB webcam) capture is iPad-only. The Studio Display camera will not work as an iPhone camera. | Video calls use the phone's own camera. Display speakers/mic over USB audio should work (verify). |
| Free Apple ID signing | Personal Team: profiles expire after **7 days**, max **3 apps per device**, **10 App IDs per week**, no push/iCloud/associated-domains entitlements, Developer Mode must be on. | Weekly reinstall from the Mac mini. We need none of the restricted entitlements. Automate the redeploy (section 5). |
| XeOS (reference app) | WKWebView-based "desktop" on the display: full-resolution browsing, no black bars, Bluetooth mouse/keyboard support, on-screen trackpad and keyboard on the phone, floating tabs/windows, downloads/PDFs, full-screen video, camera/mic, content blocker, all on-device. v2 added window management and a file system. | Good feature checklist. We can't see their code; the architecture below is our own derivation. |

## 2. Product definition

**When docked** (external display connected):

- Display: one browser "desktop" filling the screen. Tab strip + URL/search bar at the top,
  page below, a custom arrow cursor. Desktop-class rendering (desktop content mode, sensible
  zoom for a 27" panel, not phone-sized text).
- Phone: a controller page. Shows connection status, a large touch trackpad area (fallback
  when no physical trackpad), a text field that routes typing to the page (fallback when no
  keyboard), and quick actions (new tab, back, reload, zoom, settings).
- Keyboard: type into pages, standard shortcuts (⌘L, ⌘T, ⌘W, ⌘R, ⌘[, ⌘], ⌘1–9, ⌘+/−/0,
  ⌘F, ⌘⇧T, Esc).
- Trackpad: move cursor, click, right-click (two-finger click), two-finger scroll, hover.
  Pinch zoom and drag are stretch goals.

**When undocked**: the app is a plain single-tab phone browser (needed anyway: Apple requires
apps to be functional without the display, and it is how you set things up).

**Persistence**: cookies, logins, history and bookmarks persist in the app's default
`WKWebsiteDataStore`. Password AutoFill works in WKWebView; nothing syncs with real Safari.

## 3. Architecture

```
┌───────────────── iPhone ─────────────────┐    ┌──────── Studio Display ────────┐
│ PhoneScene (windowApplication)           │    │ DisplayScene                    │
│  ControllerView: status, touch trackpad, │    │  (windowExternalDisplayNon-     │
│  text relay field, quick actions         │    │   Interactive, full screen)     │
│                                          │    │  DesktopShell (UIKit)           │
│ InputHub  ◄── GCMouse / GCKeyboard       │    │   ├─ TabStrip + URLBar          │
│   (raw deltas, keys)                     │───►│   ├─ WKWebView (active tab)     │
│   ◄── UIKit presses (fallback)           │    │   └─ CursorLayer (our arrow)    │
│   ◄── touch trackpad / relay field       │    │                                 │
│                                          │    │  InputBridge.js (user script)   │
│ BrowserModel: tabs, history, bookmarks,  │    │   synthesizes pointer/mouse/    │
│  downloads, settings (shared by both)    │    │   wheel/keyboard DOM events     │
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
4. **Input is a first-class subsystem (`InputHub`)** that normalises every source into one
   event stream (`cursorMove`, `button`, `scroll`, `key`, `text`) and one consumer that
   either targets the native shell (tab strip, URL bar) or the page (via `InputBridge.js`).
5. **Virtual cursor**: a `CALayer` arrow on the display window, position integrated from
   `GCMouse` deltas (with acceleration), clamped to screen bounds. Hit-testing decides
   whether a click goes to native chrome (`UIView.hitTest` + a `VirtualPointerTarget`
   protocol on our controls) or to the page.
6. **Page event injection** via `evaluateJavaScript`: `document.elementFromPoint`, then
   dispatch `pointermove/mousemove` (hover), `pointerdown/mousedown/mouseup/click`,
   `contextmenu`, `wheel` + `scrollBy` for scroll, `focus()` for editable targets, and
   text insertion for typing. Synthesised events are `isTrusted: false`; sites that gate on
   user activation (fullscreen, popups, autoplay-with-sound, file pickers) need native
   assists (see risks).
7. **Keyboard** primary path: make the display window key and let the hardware keyboard
   reach WKWebView natively. If the system refuses to route keys into a non-interactive
   scene (spike), fall back to `GCKeyboard` + UIKit `pressesBegan` on the phone scene and
   inject through the bridge. App-level shortcuts are `UIKeyCommand`s on the phone scene.

## 4. Milestones

Each milestone ends with something installable and a short acceptance test on the real
hardware. Spikes (M1, M2) are deliberately first because they decide whether the rest is
possible as designed.

### M0 — Scaffold and redeploy loop (½ day)
- Xcode project generated from `project.yml` (XcodeGen) so the project file stays
  reviewable in git. Bundle ID fixed once (free accounts get only 10 App IDs per week).
  Deployment target iOS 26; iOS 27 paths behind `#available`.
- `scripts/deploy.sh`: `xcodebuild … -allowProvisioningUpdates` + `xcrun devicectl device
  install app` to the phone over USB or Wi‑Fi.
- README with the one-time setup (Developer Mode, trust computer, Personal Team in Xcode).
- **Accept:** app installs and launches from the Mac mini with one command.

### M1 — Spike: full-screen page on the Studio Display (1 day)
- External scene via Info.plist manifest (iOS 26) and `UISceneAccessory` (iOS 27).
- Enumerate `availableModes`, pick the largest, log `bounds`/`scale`/`nativeScale`.
- Show a WKWebView loading a fixed URL, desktop content mode, `pageZoom` tuned so text on
  the 27" panel is comfortable.
- Handle connect/disconnect/reconnect and phone lock (does the display stay on?).
- **Accept:** a page fills the whole display, correct aspect, no black bars, at the highest
  mode the iPhone→Studio Display link negotiates. Record the mode we get.

### M2 — Spike: input feasibility (1–2 days) — *decision gate*
Tests to run on the phone with the trackpad plugged into the display and the keyboard on
Bluetooth, each with AssistiveTouch **off** and **on**:
- Does `GCMouse.current` connect for the wired Magic Trackpad? Do we get deltas, button
  presses, and scroll (`GCMouseInput.scroll`) from two-finger swipes?
- Does `GCKeyboard` report keys? Do UIKit `pressesBegan`/`UIKeyCommand` fire?
- If the display window is made key, does hardware keyboard typing land in a focused
  `<input>` in the display-side WKWebView without any bridge?
- Does the phone-scene touch trackpad path work as a fallback (it should; it is plain
  touches).
- Does a click synthesised via `evaluateJavaScript` open a link, submit a form, and play a
  YouTube video? Does `requestFullscreen()` / `window.open()` work from that context?
- **Accept:** a written matrix of what works. Choose Plan A (GCMouse) or Plan B (phone as
  trackpad) for the cursor, and native vs bridged keyboard. Update section 3 accordingly.

### M3 — Cursor, click, scroll, hover (2–3 days)
- `InputHub` + `CursorLayer` with acceleration, clamping, auto-hide after idle.
- `InputBridge.js` user script: element-from-point, hover, click, double-click,
  right-click → a native context menu drawn on the display (Open in new tab, Copy link,
  Back/Forward/Reload), wheel scrolling with momentum, cursor shape from CSS `cursor`
  (arrow/hand/text).
- Native chrome hit-testing so the cursor can click tabs and the URL bar.
- **Accept:** navigate Hacker News, Gmail and YouTube with trackpad only; scroll feels right.

### M4 — Keyboard (1–2 days)
- Typing into page inputs and contenteditable (native path, or bridge with
  `execCommand('insertText')` / `beforeinput` for the fallback).
- App shortcuts listed in section 2; URL bar editing with autocomplete from history.
- Phone-side relay text field and on-screen keyboard fallback.
- **Accept:** log into a site, write an email, use ⌘L/⌘T/⌘W/⌘R without touching the phone.

### M5 — Browser features (3–4 days)
- Tabs (open/close/reorder/restore), URL + search bar (default search engine setting),
  history, bookmarks, find in page (⌘F), page zoom (⌘±), desktop/mobile UA toggle.
- Popups → new tab, downloads (`WKDownload`) with a downloads panel and Files export,
  PDF viewing, full-screen video (`isElementFullscreenEnabled`, plus a native "make the
  video fill the display" assist for sites that reject synthetic activation), camera/mic
  permission pass-through, Picture in Picture.
- **Accept:** a normal day of browsing with no dead ends.

### M6 — Phone controller UI (1–2 days)
- SwiftUI controller page: connection status, touch trackpad (tap, two-finger scroll,
  two-finger tap for right-click), relay keyboard, quick actions, settings (zoom, cursor
  speed, search engine, content blocker on/off, mode selection).
- **Accept:** everything is reachable from the phone when the keyboard/trackpad are absent.

### M7 — Reliability and polish (2 days)
- Cable unplug/replug, phone lock and auto-lock while docked (`isIdleTimerDisabled` while
  docked), memory pressure with many tabs (suspend background tabs), crash recovery of
  `WKWebView` (`webViewWebContentProcessDidTerminate`), session restore, low-power/thermal.
- Content blocker via `WKContentRuleList` compiled from an EasyList subset (optional).
- **Accept:** a week of daily use without needing to force-quit.

### M8 — Stretch
- Two side-by-side windows or floating windows (XeOS-style), drag and drop, pinch zoom,
  Studio Display speakers/mic routing, Handoff-style "open this page on the display" from
  the phone share sheet, keyboard-driven link hints.

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
| `GCMouse` does not see the wired Magic Trackpad on iPhone, or gives no scroll deltas | Medium | Plan B: phone screen as trackpad (M6 path) is guaranteed to work; a third-party Bluetooth mouse is a cheap test. M2 decides. |
| Hardware keyboard does not route into the non-interactive display scene | Medium | Bridge path via `GCKeyboard` + UIKit presses on the phone scene; typing injected through the bridge. |
| Synthetic clicks lack user activation (fullscreen, popups, autoplay with sound, file pickers) | High | Native assists: our own "fill display with video" mode, `createWebViewWith` handles popups natively, phone-side taps for file pickers. |
| iPhone→Studio Display negotiates a low mode or nothing | Low–Medium | Verify in M1 with a USB 3 or Thunderbolt cable; expose mode picker in settings. |
| iOS 27 scene accessory API differs from docs | Low | UTM's PR is a working reference; keep the iOS 26 manifest path as a fallback. |
| Site breakage from `isTrusted: false` events | Medium | Test the user's real sites early (M3); keep a per-site "mobile UA" and "tap on phone" escape hatch. |
| Battery/thermal while docked at 4K | Low | The display powers the phone; suspend background tabs. |

## 7. Open questions for the owner

Answers change scope; defaults in brackets are what the plan assumes.

1. Which iPhone and iOS version? [iPhone 15 or later, iOS 26.x or 27.x]
2. Which Studio Display (2022 Thunderbolt 3 model, or a 2026 model) and which cable will
   connect the phone? [2022 model, Thunderbolt/USB 3 cable]
3. Magic Trackpad generation and whether you are OK running it **wired** into the display
   (Bluetooth pairing to iPhone is refused by iOS). [yes, wired]
4. Keyboard over Bluetooth or wired? [Bluetooth]
5. Single window with tabs for v1, or do you want XeOS-style floating windows from the
   start? [tabs first]
6. Should the phone act as a trackpad/keyboard fallback, or is that unnecessary? [yes]
7. Any must-work sites (Google Workspace, Microsoft 365, banking, YouTube) to use as the
   acceptance list? [HN, Gmail, YouTube, one banking site]
8. Content blocker wanted in v1? [no, M7]
9. App name and bundle ID (fixed once because of the 10-App-ID/week cap).

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
