# Session state

#107 steps 0-4 done and committed.
- Step 4: settings reader ignores unknown fields (PARSE_OPTIONS); cell entry appends old_marks + cleared_peers (18 B),
  solve entry appends 9 mark planes (144 B); reader reads known fields, ignores trailing bytes, reads pre-marks entries
  with defaults, refuses entries shorter than base. ADR-0018 records "entries may grow".
- Parity: relaunch_restores_marks_and_their_undo. Web demo: reload + Undo restores marks.
- Next: step 5 (terminal) — wait for user.
