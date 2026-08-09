Status: closed
Type: task
Blocked by: (none)

## What to build

New file `src/command.zig` — Command union type + parser returning ParseCommandResult. Chess-style coordinates A–I × 1–9. Three command variants: fill, clear, quit. Unrecognised input falls through as a rejection string, not an invalid Command variant.

### Verify before code
Confirm no `src/command.zig` exists; confirm `game_engine.zig` has no `exec()` or `Command` import.

### Test (write first)
- `"parse fill command A1 7 → .valid with row 0, col 0, digit seven"`
- `"parse clear command C3 → .valid clear at row 2 col 2"`
- `"parse quit → .valid quit"`
- `"parse empty line → .invalid_message"`
- `"parse unknown verb → .invalid_message describing the issue"`
- `"parse fill with out-of-range coordinates (J1) → .invalid_message"`
- `"parse fill A1 with non-digit value → .invalid_message"`

### Code (write after test)
- Define `pub const Command = union(enum) { fill, clear, quit };`
- Add data fields: `fill` carries `{ row: u4, col: u4, digit: cell.CellValue }`; `clear` carries `{ row: u4, col: u4 }`
- Define `pub const ParseCommandResult = union(enum) { valid: Command, invalid_message: []const u8 };`
- Chess-style coordinate parser: column A–I → 0–8, row digit 1–9 → 0–8
- `fn parse(input_line: []const u8) ParseCommandResult`
- Trim leading/trailing whitespace before parsing

### Verify after
`zig test src/command.zig` passes all tests. No warnings.

### root.zig update
Add `const command = @import("command.zig");` and reference inside root `test {}` tuple so Zig discovers the test blocks.
