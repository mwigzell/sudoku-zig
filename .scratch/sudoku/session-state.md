# Session state

#107 steps 0-7 done and committed.
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
- Step 7 (Android): FileBridgeTest#pencilModeMarksACellWithAllNineMarksInsideItAtLeastTheFloorSize — Pencil + 1..9 on
  an empty cell; WebView does not expose marks to accessibility, so it reads the screen: ink in each of the nine slots,
  slot >= 8dp. Runs on the Pixel 8 as is (user dropped the 360dp resize; #107 criterion reworded and ticked).
  Few, spaced screen reads (5 × 1s): an earlier 250ms screenshot poll coincided with the emulator going offline.
- Noted: marks are not read by screen readers (WebView a11y) — candidate issue.
- Next: step 8 (parity fixtures, CONTEXT.md, verify/glue/android-test green; user runs full android-test) — wait for user.
