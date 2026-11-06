# Session state

#107 steps 0-6 done and committed.
- Step 5 (terminal): `pencil` verb (`p A1 5`) in Commands, legend `(P)encil`; Menu 15) Show Pencil Marks (on/off)
  → toggle_show_marks. Facade: render gains `marks_visible`, getCommandInput gains `show_marks` (scalar, after
  show_region). Large board: 3 lines × 5 cols per cell, `·` unset, filled cell digit centred; shared `largeLine` in
  styler.zig (ANSI styles whole cell block). Terminal criterion ticked on #107.
- Noted, not fixed: Import rejects a puzzle file with a trailing newline ("exactly 81 characters").
- Step 6 (web shortcuts): `menus/shortcuts.js` — one table (key, mod, shift, target selector); a key presses its
  control via click(), so it runs the button's own command. Cmd replaces Ctrl on Mac (`isMacPlatform`, case-insensitive:
  Chromium says "macOS"). Undo/Redo moved into the table (menu.js parseEditShortcut removed). Ignored while typing, in
  an open aria-modal dialog, on key repeat; a disabled target's key is still taken (no browser Save page). Menu items get
  a `.menu-shortcut` label, every target `aria-keyshortcuts`. Served by web_host (embed/router/mod).
- Noted, not fixed: digit keys still reach the board while the generating dialog is open (filled A1 in the demo).
- Next: step 7 (Android 360dp mark size check + Android test marking a cell) — needs the emulator; ask first.
