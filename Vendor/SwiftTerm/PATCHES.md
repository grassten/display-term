# Vendored SwiftTerm

Upstream: https://github.com/migueldeicaza/SwiftTerm, tag `v1.20.0`, commit `5d14406`. MIT
(see `LICENSE`). Only `Sources/SwiftTerm` is kept. `Package.swift` is trimmed to the library
target, and the git build-info plugin is replaced by a static `SwiftTermBuildInfo.swift`.

To see our changes: `git diff <vendoring commit>.. -- Vendor/SwiftTerm`.

## 1. Text and erases remove sixel / iTerm2 images under them (16 Oct 2026)

Upstream attaches each inline image to buffer lines as one strip per row and removes a
strip only on a full-screen erase (`ED 2`), a Kitty delete, or when the line scrolls out.
Writing text over the strip, or `ED 0`/`ED 1`/`EL`/`ECH`/`ICH`/`DCH`, left it on screen.
tmux clears and redraws with exactly those sequences, so under tmux `clear` did nothing and
yazi previews never went away.

- `TerminalImage.cellSpan` (default 0): number of columns a strip covers. `AppleImage`
  sets it from the placed size for sixel and iTerm2 images; Kitty placements keep 0 because
  that protocol layers images over text and deletes them explicitly.
- `Buffer.eraseImages(lineAt:start:end:)` drops strips overlapping a column range and
  keeps the lines-with-images count right.
- Called from `insertAsciiRun`, `insertCharacter`, `eraseInBufferLine` (EL, ED, line
  resets), `cmdEraseChars`, `cmdInsertChars`, `cmdDeleteChars`.

A strip is removed whole when any of its columns is touched (xterm keeps the untouched
pixels). That is enough for tmux and file-manager previews, which redraw whole regions.
Candidate for upstreaming.

## 2. One-finger drag scrolls programs that track the mouse (16 Oct 2026)

On iOS, while the program has mouse reporting on (tmux `mouse on`, vim `mouse=a`), upstream's
pan gesture sends button-1 press/drag/release, so swiping on the phone made tmux select text.

- `TerminalView.touchDragScrolls` (default false; `Pane` sets it true): `panMouseHandler`
  sends wheel up/down events instead, one per line of finger travel, at the touch's cell.
- Taps still click, and the long-press menu still offers Select / Copy / Paste.

App-specific behaviour, not for upstreaming as is.
