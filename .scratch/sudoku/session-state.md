# Session state

#107 steps 0, 1, 2 done and committed.
- Step 2: fill replaces cell marks + auto-clears digit's marks in row/col/box (CellMutation.old_marks, cleared_peers);
  Undo restores, Redo re-clears; Clear removes marks of an empty marked cell; canClear covers marks.
- Parity: fill_clears_peer_marks, fill_undo_restores_marks, clear_removes_marks.
- Not yet saved: old_marks/cleared_peers in the cell save entry (step 4). Undo after reload restores values, not marks.
- Next: step 3 (Solve and Hint) — wait for user.
