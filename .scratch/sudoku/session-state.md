# Session state

#107 steps 0-5 done and committed.
- Step 5 (terminal): `pencil` verb (`p A1 5`) in Commands, legend `(P)encil`; Menu 15) Show Pencil Marks (on/off)
  → toggle_show_marks. Facade: render gains `marks_visible`, getCommandInput gains `show_marks` (scalar, after
  show_region). Large board: 3 lines × 5 cols per cell, `·` unset, filled cell digit centred; shared `largeLine` in
  styler.zig (ANSI styles whole cell block). Terminal criterion ticked on #107.
- Noted, not fixed: Import rejects a puzzle file with a trailing newline ("exactly 81 characters").
- Next: step 6 (web shortcuts P, H, R, M; Ctrl/Cmd+S, Shift+S, O; Cmd undo/redo; menu shortcut labels) — wait for user.
