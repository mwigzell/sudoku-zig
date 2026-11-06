# Session state

#107 steps 0-3 done and committed (+ refactor 185f62d: one unitsMask; #115 filed for front-end region copies).
- Step 3: Solve clears marks via placeSolution (shared by Solve and Redo, each digit through fill.clearMarks);
  BoardSnapshot.mark_bits restores them on Undo. Hint test proves marks unchanged.
- Parity: solve_clears_marks, solve_undo_restores_marks, hint_leaves_marks.
- Not yet saved: cell entry old_marks/cleared_peers and solve entry mark_bits (step 4).
- Next: step 4 (saved marks) — wait for user.
