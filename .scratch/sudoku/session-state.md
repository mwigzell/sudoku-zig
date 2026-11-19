# Session state — bookmark notices

Updated: 2026-11-18. Cycle complete, uncommitted, awaiting owner review.

## Change

Undo now tells the player when the bookmark matters (owner chose wording option b):

- landing on it (`pointer == bookmark`, `pointer > 0`): `At the bookmark (move {d}). The next undo drops it.`
- crossing it (`bookmark > pointer`): `Bookmark at move {d} cleared: undone past it.` and `bookmark = null`.
- a bookmark at move 0 is kept and gets no next-undo claim (nothing further to undo).

## Files

- `src/core/engine/bookmark.zig` — `AT_BOOKMARK_FMT`, `BOOKMARK_CLEARED_FMT` (core-owned text).
- `src/core/engine/undo.zig` — `BookmarkNotice` + `bookmarkNoticeAfterUndo` replaces `discardBookmarkBelowPointer`; notice appended per branch because the `.solve_batch` path calls `beginEventMsg()` and would otherwise drop it.
- Tests in `undo.zig`: landing notice, clearing notice, move-0 edge case, sentence check. Existing undo tests unchanged.

## Gates

- `zig build verify` green: 17.03s vs 18.0s budget; timing gate passed.
- `zig build run -- -h` rc 0 (entry point compiles).
- No parity/fixture change needed: no scenario uses bookmark steps.

Not committed. Not pushed.

## Prior state (superseded) — #127 menu bar / portrait

Closed work; kept here only as history. Commit history is the record.
