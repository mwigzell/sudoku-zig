Status: needs-triage

## Problem

**S4 from full code review:** Coding standard #1 requires *"Every public function must have a header comment explaining its purpose, parameters, and return value."* Several public surfaces are undocumented.

---

## Gaps

| Module | Missing docs on |
|--------|----------------|
| `puzzle_gen.zig` | `Difficulty`, `PuzzleGen.generate()`, `countGivens()` |
| `game_engine.zig` | `fill()`, `fillAndRender()` (inline comments exist but no proper `///` header docs) |
| `board.zig` | `getBoxDigitBits`, `setCell`, `clearCell` |
| `logger.zig` | the `Logger` generator itself |

## Acceptance Criteria

- [ ] Each listed public function/type has a `///` doc comment covering purpose and parameters
- [ ] No other undocumented public surfaces introduced during work
