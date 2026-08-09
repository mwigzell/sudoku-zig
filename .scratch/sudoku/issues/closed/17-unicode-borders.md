Status: closed

## Triage
Date: 2026-07-18

### Notes
- Purely cosmetic: swap ASCII borders (`+-|`) for Unicode box-drawing (`╭─┬╮│┼╰─┴╯`)
- No logic changes — just template character substitution in styler + helper strings
- Applies to both PlainStyler and AnsiStyler

## Parent
`.scratch/sudoku/prd.md`

## What to build
Replace ASCII border characters with Unicode box-drawing equivalents across the render path:
- Column separator `|` → `│` (U+2502)
- Horizontal rule `-` → `─` (U+2500)
- Box intersection `+` → `┼` (U+253C)
- Header column join → `├` style equivalent

Affects:
1. PlainStyler / AnsiStyler — `{s}` template string separators and vertical bars  
2. `ascii_renderer.zig` helpers — `columnHeader()` and `horizBorder()` return value strings  

## Scope

.**17.1 — Update ascii_renderer.zig helper strings** ✓

Replace ASCII literals in `columnHeader()` and `horizBorder()`. Tests updated to match new expected output.

.**17.2 — Update PlainStyler + AnsiStyler format templates** ✓

Swap separators in the `{d}| ...` bufPrint template used by both styler impls. Both test cases updated. Verified via existing styler tests.

## Acceptance criteria
- [x] Column header uses ` │ ` instead of ASCII bar separator  
- [x] Box borders use `─`, `┼`, corners (`╭╮╰╯`) — no `+-|` remaining  
- [x] Data rows rendered identically except border characters changed  
- [x] AnsiStyler bold wrapping around given digits still correct  
- [x] All 41 tests passing with updated expected strings
- [ ] Box borders use `─`, `┼`, corners (`╭╮╰╯`) — no `+-|` remaining  
- [ ] Data rows rendered identically except border characters changed  
- [ ] AnsiStyler bold wrapping around given digits still correct  
- [ ] All 38 tests passing with updated expected strings  

## Blocked by
Issue 16 (closed)
