Status: needs-triage
Type: task
Blocked by: 02-game-engine-exec, 04-exec-wires-validator, 05-styler-conflict-decoration

## What to build

Rewrite `main.zig` to the command loop anatomy from the parent issue's preamble. Replace "render once and exit" with an infinite loop that reads player commands, routes them through exec, and handles parse/exec errors via an acknowledge gate.

### Loop pieces
| Piece | Role | Owner |
|-------|------|-------|
| R — Render | `engine.render()` | game_engine |
| P — Prompt | `print("> ")` | main |
| L — Read line | `readUntilDelimiterOrEof(buf, '\n')`; EOF → break | main |
| Pr — Parse | `command.parse(line)` → ParseCommandResult | command |
| Sw — Switch | `.valid` → exec; `.invalid_message` → acknowledge + continue | main |
| E — Exec | `engine.exec(cmd)` → CommandResult | game_engine |
| A — Acknowledge gate | print message, consume Enter press, loop continues | main |

### Verify before code
Current `main()` calls `engine.render()` once then returns. P, L, Pr, Sw, A pieces don't exist yet as code.

### Test (write first)
T6 is too integration-heavy for inline tests — verify via manual run instead.

### Code (write after test)
Rewrite `main.zig`:
1. Initialise engine + renderer (unchanged)
2. Enter `while (true)` loop
3. R — `engine.render()` (full redraw, always first)
4. P — print `"> "` prompt
5. L — read line from stdin; EOF or error → break
6. Pr — result = `command.parse(line)`
7. Sw — on `.valid`: route to exec; on `.invalid_message`: call `waitAck(msg); continue`
8. E — execResult = `try engine.exec(cmd)`:
   - `.quit` → break (exit program)
   - `.ok` → loop continues immediately
   - `.error_msg` → `waitAck(msg); continue`
9. Loop repeats from R

Define `fn waitAck(writer: anytype, msg: []const u8) anyerror!void`:
- Write error message + newline to stdout via writer
- Prompt `"> "` (press Enter to continue)
- Read empty line from stdin
- Loop continues after acknowledgement

### Verify after (manual run)
- `zig build run` renders board, prompts `> `
- Type `fill A1 7` (empty cell) → cell updates on next render, loop continues
- Type `fill given_cell` → error message displayed, press Enter, prompt returns
- Type garbage → parse rejection displayed, press Enter, prompt returns
- Type `quit` → program exits cleanly
- `zig test src/root.zig` all prior tests still pass (T6 is main-level integration; coverage comes through manual run)
