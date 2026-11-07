# Session state

#107 steps 0-8 done and committed.
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
  slot >= 8dp. Passed on the Pixel 8 and on a 360dp phone (720x1280 @320) (user dropped the 360dp resize; #107 criterion reworded and ticked).
  Few, spaced screen reads (5 × 1s): an earlier 250ms screenshot poll coincided with the emulator going offline.
- Noted: marks are not read by screen readers (WebView a11y) — candidate issue.
- Step 8: parity scenario mark_undo_redo (the only missing pencil case: Redo of a mark); mutation check proved web and
  android compare it. CONTEXT.md "Pencil marks" section. verify + glue green.
- Generating dialog: progress block holds its tallest height (wrapped rows on narrow phones made it jitter); user
  confirmed on phone, plus pencil marks on phone.
- Hand check show_marks off (mark, Undo, Redo; Clear): Android (user), web and terminal (agent, sandboxed) all pass.
- Full android-test green on 360dp emulator (21 tests). Contradicting-mark core test added. #107 closed.
- Next: #117 with #115; triage #116, #111.

## #117 (core owns selection + frame)
- Step 1 done: `src/core/frame.zig` (Frame: board, status, selected, region mask, marks_visible; `build(engine, status, selected)`);
  `Facade.render(frame)`; styler shades from frame.region (inPeerRegion/CellSelection gone); selected cell marked only
  while region shown (step 5 drops that). Selection still shell's last_cell. Demo -r ansi: fill A1 shades 20 cells.
- Note: `zig test --test-filter` / `-Dtest-filter` don't match nested-module tests; check with the full `zig test src/entry_native.zig -lc` run.
- Next: Step 2 (core owns selection, terminal) — wait for user.
