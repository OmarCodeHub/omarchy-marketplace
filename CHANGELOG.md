# Changelog

Notable changes to Plugin Depot. The version here is the one in
[`manifest.json`](manifest.json), which is what the marketplace listing shows.

This project follows [semantic versioning](https://semver.org):

| | when it goes up |
|---|---|
| **major** | something that was working stops working: a setting is removed, the plugin id changes, a documented entry point or command disappears |
| **minor** | a new user-visible capability |
| **patch** | fixes, performance and internals, with no new capability |

## 1.1.0

### Added

- **Bar layout editor.** Omarchy can move and place bar widgets from the command
  line but shows the arrangement nowhere. The new **Bar layout** view draws the
  three sections the way the bar is laid out, left to right, with every placed
  widget in order and everything installed but unplaced below it. Widgets can be
  dragged, or moved with the keyboard. **Undo my changes** puts the bar back the
  way it was when the view opened.
- **Keyboard navigation across the whole app**, not just the bar editor. Arrows
  and `hjkl` move the cursor, `Tab` steps between views, `Ctrl` chords go
  straight to a view, `Ctrl+Enter` runs whatever action the selected plugin is
  offering, and `Esc` steps back out of whatever is covering the list.
- **Drag and drop** for arranging the bar, alongside the keyboard.

### Changed

- **Every key now means the same thing in every view.** Four of them did not.
  `Ctrl+B` went to the bar from the list and back to the list from the bar, so
  the hint footer had to label one chord two ways. `Ctrl+,` was a toggle for the
  same reason. `Esc` stepped out of settings and out of the detail pane but had
  no rung for the bar editor, so from there it closed the whole window instead
  of going back. `Tab` changed the view from the list but did nothing from the
  bar or from settings. Destinations are now always destinations, `Esc` is the
  only key that goes back, and the model is written down rather than left to be
  inferred.
- The hint footer wraps instead of eliding, and names only the keys that do
  something in the view you are standing in.
- The update check is cached for fifteen minutes, with `--refresh` to force a
  live check. It had no cache at all and was costing 811ms of every open, all of
  it network. The same call now takes 14ms.
- The reduced catalogue index dropped from 2.7MB to 2.1MB. The install note was
  repeated across all 3,124 listings for six distinct strings, so the notes are
  interned and each listing carries an index into them. `observedCommit` was
  written into every record and read by nothing, so it is gone.
- The manifest now declares its license, so the marketplace listing names MIT
  rather than pointing at the repository.

### Fixed

- **The advertised single-key shortcuts did nothing.** The panel focuses the
  search field when it opens and the shell's key dispatcher is blocked while
  that field has focus, so every bare letter typed into the box and filtered the
  list. Pressing `b` did not go back, it searched for the letter b. Global
  actions moved onto `Ctrl` chords, which fire regardless of focus.
- The confirmation dialog had no keyboard handling at all, and the panel's
  dispatcher is deliberately blocked behind it, so every action that changes the
  system needed the mouse to finish or to back out of. `Enter` and `Esc` now
  work there.
- Clicking a bar widget could displace it onto the first widget in its column
  until something else was moved.
- The header status line rendered as a truncated fragment. The rest of that row
  is fixed width, so at the width Hyprland hands this panel there was no slack
  left for it at all.

## 1.0.0

First release. Browse the marketplace, install pinned to the reviewed commit,
update with a read-only diff first, enable, disable and remove, plus a bar
widget that carries a count when updates are waiting.
