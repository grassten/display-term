# CLAUDE.md — operating guide for this repo

Read this first. It tells you what the project is, which environment you are in, and the
exact procedure to build, install and debug the app on the owner's iPhone so the owner does
not have to type commands.

## What this is

**Display Term**, an iPhone app that puts an iTerm2-style SSH terminal on an external
display (Apple Studio Display, first gen, Thunderbolt cable). The phone is the controller:
iOS delivers no input to the external-display scene, so every keystroke is captured on the
phone and relayed, and the phone's screen is the trackpad. Undocked, the phone is a terminal
itself. `PLAN.md` has the decisions, architecture, milestones and what is still untested.
`README.md` is the user-facing cheat sheet. `docs/mockups/index.html` is the agreed look.

The GitHub repository is public at `github.com/grassten/display-term` (renamed from
`external-display-safari` and made public on 26 Nov 2026); the local checkout folder still
has the old name. Keep secrets, LAN addresses and personal details out of commits.

Until 16 Oct 2026 this repo was a WKWebView browser ("Display Browser"); that code and its
plan are in git history up to commit `5b65eed`.

Owner's setup: iPhone 15 on iOS 27, Mac mini with Xcode 27, free Apple ID (Personal Team,
7-day provisioning profiles). Magic Keyboard over Bluetooth. The Mac mini is the default SSH
target (Remote Login on; tmux installed via Homebrew for session persistence).

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
                                SwiftPM packages are declared here: SwiftTerm (local, Vendor/), swift-nio-ssh 0.15.0 (exact),
                                swift-nio, swift-nio-transport-services, swift-collections pinned 1.2.1 (see below).
Vendor/SwiftTerm/               SwiftTerm 1.20.0, vendored and patched. PATCHES.md lists every change; keep it current.
Config/Local.xcconfig.example   Template. The real Config/Local.xcconfig is git-ignored and holds DEVELOPMENT_TEAM.
scripts/bootstrap.sh            One-time: creates Local.xcconfig, runs xcodegen.
scripts/deploy.sh               Build + sign + install + launch on the phone. Run weekly (profile expires in 7 days).
Sources/App/                    AppDelegate, PhoneSceneDelegate, DisplaySceneDelegate (display mode selection)
Sources/Model/                  AppState (dock state, stores), Workspace (tabs), Tab + PaneNode (split tree), Pane (SwiftTerm view +
                                SSH session + reconnect), Profile(Store), Keymap (iTerm2 defaults, keymap.json), Theme(Store), TerminalAppearance
Sources/SSH/                    SSHConnection (NIOTS bootstrap, NIOSSHHandler, session/exec channels), SSHAuth (key-then-password,
                                trust-on-first-use host keys), DeviceKey (Keychain ed25519), HostKeyStore, HostBrowser (Bonjour _ssh._tcp)
Sources/Input/                  KeyRelayView (first responder on the phone while docked; forwards to the display's TerminalView),
                                Commands (actions), PointerController, TouchpadView, MouseInput (kept for a future iPad, unused)
Sources/UI/Display/             DisplayRootViewController (tab bar, pane layout, status bar, PointerSurface), PaneView, TabBarView,
                                StatusBarView, CursorView, ContextMenuView
Sources/UI/Phone/               PhoneRootViewController (docked/undocked layouts, UIKeyCommands), ExtraKeysView, PromptCenter,
                                SettingsViews (SwiftUI: hosts, appearance, shortcuts, device key)
Sources/Resources/Fonts/        JetBrainsMonoNerdFontMono-{Regular,Bold,Italic,BoldItalic}.ttf (PostScript names JetBrainsMonoNFM-*)
docs/mockups/index.html         Mockups; A (display) and 1 (phone docked) were chosen.
```

Bundle ID: `com.grassten.displaybrowser` (set in `project.yml`). Do not change it: free
accounts get 10 App IDs per week and changing it burns one and loses app data. The display
name is "Display Term"; `PRODUCT_NAME` stays `DisplayBrowser` on purpose.

## Build, install and run on the phone (Mac mini)

Prerequisites, once:

```bash
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain     # SwiftTerm has a Metal shader; the Xcode 27 beta ships without the toolchain
scripts/bootstrap.sh                             # creates Config/Local.xcconfig + generates the .xcodeproj
# DEVELOPMENT_TEAM is the OU= field of the signing certificate, not the ID in parentheses:
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

Put the team ID in `Config/Local.xcconfig`. If no "Apple Development" identity exists, the
owner must sign in to Xcode once (Xcode > Settings > Accounts > add Apple ID). Ask the owner
to do that step; it needs their password.

On the phone, once: Settings > Privacy & Security > Developer Mode on (reboots); connect to
the Mac by USB once and tap Trust; after the first install, Settings > General > VPN & Device
Management > trust the developer app. Tell the owner exactly which of these prompts to tap.

Every deploy:

```bash
scripts/deploy.sh                          # picks the first paired iPhone; DEVICE=<udid> to choose
```

The script: regenerates the project, builds Debug with `-allowProvisioningUpdates
-skipPackagePluginValidation -skipMacroValidation` (SwiftTerm ships a build-tool plugin that
command-line xcodebuild otherwise refuses), writes the full log to `build/xcodebuild.log`,
installs with `xcrun devicectl device install app`, then launches the app. On failure it
prints the `error:` lines. Fix the code, re-run. Do not edit the generated `.xcodeproj`.

Compile check without a phone (what the first implementation was verified with):

```bash
xcodegen generate --quiet && xcodebuild -project DisplayBrowser.xcodeproj -scheme DisplayBrowser -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath ~/Library/Developer/Xcode/DerivedData/DisplayBrowser-deploy \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO build > build/xcodebuild.log 2>&1; grep error: build/xcodebuild.log
```

DerivedData deliberately lives at `~/Library/Developer/Xcode/DerivedData/DisplayBrowser-deploy`,
outside the repo. This checkout sits on the Desktop, which is iCloud-synced (Desktop &
Documents), and the iCloud file provider stamps `com.apple.FinderInfo` on the built `.app`.
Codesign then fails with `resource fork, Finder information, or similar detritus not allowed`.
Do not move the build back inside the repo. Override with `DERIVED=<path>` if needed.

Package gotchas found on 16 Oct 2026: `swift-collections` 1.5+ uses Swift 6.3 experimental
features the Xcode 27 beta compiler rejects, so it is pinned to 1.2.1 in `project.yml`;
SwiftTerm is vendored at 1.20.0 because its `main` API differs
(1.20.0 has `TerminalView.getTerminal()` and a public `selection`; `main` hides both and adds
Kitty-clipboard delegate methods) and because we patch it (`Vendor/SwiftTerm/PATCHES.md`).
Bumping means re-copying upstream `Sources/SwiftTerm`, re-applying the patches, and
re-checking `Pane`'s `TerminalViewDelegate` conformance and `DisplayRootViewController`'s
engine calls.

Inline images (16 Oct 2026): SwiftTerm draws sixel and iTerm2 images. Under tmux only sixel
gets through, and only because the Mac mini's `~/.tmux.conf` has `allow-passthrough on` and
`terminal-features ',xterm-256color:sixel'`. The `img`, `pdf` and `md` helpers live in the
Mac's `~/.zshrc` (SSH sessions only).

Find the device UDID if needed:

```bash
xcrun devicectl list devices
```

## Reading the app's log

Launch with console attached to see `NSLog` output live:

```bash
BUNDLE_ID=com.grassten.displaybrowser
UDID=$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(x["hardwareProperties"]["udid"] for x in d["result"]["devices"] if x["hardwareProperties"].get("platform")=="iOS"))')
xcrun devicectl device process launch --console --terminate-existing --device "$UDID" "$BUNDLE_ID"
```

Look for `[Display] modes: [...] using WxH scale=…` when the display is plugged in, and
`[Display] root appeared bounds=…`. Record the modes line in `PLAN.md` the first time.

Wi‑Fi works for install and launch once the phone has been paired over USB and both are on
the same network, so the owner can leave the phone docked to the display.

## Verification checklist after each deploy

Ask the owner to have the display connected and the keyboard paired, then walk through and
record results (works / fails / notes) in `PLAN.md`:

1. First run: the Mac mini appears in the host list; Save & Connect shows the host-key
   fingerprint, then the password prompt; a shell prompt appears on the phone.
2. `ls`, `vim`, `htop`, `tmux ls` render correctly; rotating the phone resizes the shell.
3. Second connect (⌘T) needs no password ("key" in the status line).
4. Plug the display in: the terminal fills it, no black bars; the phone shows the docked
   layout; typing on the Magic Keyboard lands in the pane.
5. ⌘D, ⌘⇧D, ⌘⌥arrows, ⌘⇧↩, ⌘W, ⌘T, ⌘1–9, ⌘⇧[ / ⌘⇧] all do what iTerm2 does.
6. Every key class reaches the shell: ⌃C/⌃D/⌃R, Tab, Esc, arrows (in zsh and in vim),
   ⌥←/⌥→ word moves, ⇧⇥, Fn keys, ⌫, key repeat. Note which ⌘ chords iOS keeps.
7. Trackpad: tap focuses a pane, hold-then-drag selects and ⌘C/⌘V round-trips, two fingers
   scroll scrollback and `less`, two-finger tap opens the menu, dragging a divider resizes.
8. Lock the phone, unlock: panes reconnect and (with tmux) reattach to the same shells.
9. Unplug the display: sessions continue on the phone; replug: back on the display.
10. Kill the app and relaunch: same tabs and splits, same tmux sessions.

Known likely first-run issues: key forwarding from `KeyRelayView` into SwiftTerm's
`pressesBegan`/`insertText` (if keys double or vanish, the fallback is an own key encoder);
selection coordinates vs scrollback; `swift-nio-transport-services` Bonjour connect failing
(then use a manual `host:port` profile); password auth disabled in the Mac's `sshd_config`
(then copy the public key from Settings and add it by hand).

## Weekly redeploy (free account limitation)

The provisioning profile expires 7 days after each install and the app stops launching.
Re-run `scripts/deploy.sh` before then. To automate on the Mac mini, install a launchd agent
that runs it every 6 days while the phone is on Wi‑Fi (not yet set up; add
`scripts/install-launchd.sh` when asked).

## Conventions

- Swift 5 language mode, UIKit lifecycle; SwiftUI only for settings forms via
  `UIHostingController`. Dependencies are SwiftPM packages declared in `project.yml`.
- All keyboard handling lives on the phone: shortcuts are `UIKeyCommand`s generated from the
  `Keymap` on `PhoneRootViewController`; everything else goes to the focused pane's
  `TerminalView` (directly when undocked, via `KeyRelayView` when docked). The display scene
  receives no system input. Pointer events reach `DisplayRootViewController` only through
  `PointerSurface`.
- Pointer coordinates: `PointerController.position` is in display-window points;
  `DisplayRootViewController` converts to the pane's terminal view and to a cell
  (`Position`, screen rows) before touching SwiftTerm's `selection` or mouse reporting.
- Anything that talks to the remote goes through `Pane` → `SSHConnection`; bytes in via
  `TerminalView.feed`, bytes out via `TerminalViewDelegate.send`. Callbacks from NIO arrive
  on the main queue.
- `keymap.json` is the source of truth for shortcuts; `Keymap.defaults` must stay iTerm2's.
- Commit small, descriptive changes. Update `PLAN.md` when a milestone's status changes or a
  decision is made. Do not put model identifiers in commits or code.
- `main` is the deployable branch. Work on a feature branch, merge when it builds.
