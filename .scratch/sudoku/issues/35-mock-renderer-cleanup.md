## What to do

Replace the remaining `MockRenderer`-backed tests in `sudoku.zig` with real `AsciiRenderer + MockSource` integration tests. Issue 34 converted the three `run:` e2e tests but ~7 rigged `handleResult` tests remain that call `MockRenderer`, bypassing the renderer's dialog caching, parsing, and intercept logic.

### Current State

The `"full seam: open loads saved game"` test was just rewritten using this pattern (passes all 219 tests). It proved viable. The remaining MockRenderer users in `sudoku.zig`:

| # | Test Name | Line ~# | Pattern |
|---|---|---|---|
| 1 | `Sudoku.init uses config difficulty to build the board` | 130 | Just checks engine.board after init |
| 2 | `Sudoku.init with .medium difficulty loads medium puzzle` | 146 | Same as #1 |
| 3 | `Sudoku stores io field during init` | 376 | Doesn't even need a renderer, just proves IO wiring |
| 4 | `full seam: f A3 4 -> prefix dispatch -> fill (0,2)=four` | 388 | Calls handleResult with pre-parsed command + checks MockRenderer call_count and rendered cells |
| 5 | `handleResult: save success produces status msg...` | 480 | Drive parse("save") + check mock.call_count for re-render via handleResult() |
| 6 | `handleResult: open success produces status msg...` | 508 | Drive parse("open /path") directly, bypassing dialog cache entirely — exactly what Issue 32 fixed |
| 7 | `handleResult: open with relative path resolves without panic` | 539 | Same as #6 |
| 8 | `handleResult: save uses default filename and returns success` | 571 | parse("save") + mock call_count check |
| 9 | `handleResult: subsequent save reuses previous filename with feedback` | 597 | Two mocked parse calls, checks mock.call_delta |

### Why

MockRenderer shortcuts every input path by returning pre-built `ParseCommandResult`. This means:
- **No dialog intercept execution** — the renderer's save/open caching logic isn't exercised by tests that matter
- **Path data stuffed in at parse time** — exactly what Issue 32 was designed to stop
- **Mocks count renders but don't prove they happened** — `mock.call_count > 0` is true because you called render, not because the system actually went through a save→handleEvent→render loop driven by real user input

### Target

Convert each test to the proven pattern:

```zig
var aw = std.Io.Writer.Allocating.init(alloc);
defer aw.deinit();
const responses = [_][]const u8{ /* canned command strings + dialog answers */ };
const source: input_source.ReaderSource = .{.mock = input_source.MockSource.init(alloc, &responses)};
var renderer = ascii_renderer.AsciiRenderer(styler_t.PlainStyler).init(alloc, io, &aw.writer, &s, source);
defer renderer.deinit();
const f = facade.Make(ascii_renderer.AsciiRenderer(styler_t.PlainStyler)).make(&renderer);
var sudoku_instance = try Sudoku.init(cfg, &f, io);
defer sudoku_instance.engine.deinit();
sudoku_instance.run() catch {};
// assertions against engine state or output buffer
```

### What stays

MockRenderer's own unit tests (lines 85-132 in `mock_renderer.zig`) stay intact — they verify queue exhaustion → quit and ordered playback. The MockRenderer struct itself can remain as long as its internal tests pass.

### Design Decisions to Make

For the `handleResult: <verb> success` tests (#5-9): do we convert them all to full `.run()` loops? Many assertions about "renderer was called" are redundant if we're exercising real output — verifying the AllocatingWriter's buffer grew after each command is equivalent. The `"legend refreshed"` claims may need different verification since legend state lives inside the renderer and isn't directly exposed. This needs a pass through to decide which assertions survive conversion vs. get dropped as untestable without more mocks.

### Steps

| # | Description |
|---|-------------|
| 1 | Convert `Sudoku.init` tests (#1-3): trivial — just needs *something* wired to facade, real renderer with empty mock source works fine. |
| 2 | Convert `full seam: f A3 4 -> prefix dispatch` (#4): feed `"fill A3 4"` command through canned input. Verify board state post-run, not mock call counts. | 
| 3-7 | Convert the five `handleResult` save/open/relative tests (#5-9) — these are the most rigged (bypassing dialog cache). Will need careful assertion translation from "mock.call_count > X" to verifying output buffer / engine state changes. |
| 8 | Run full test suite, verify pass rate >= 219. |

### Acceptance criteria

- [ ] 1. `sudoku.zig` has zero references to `MockRenderer`. (Its own tests in mock_renderer.zig stay.)
- [ ] 2. All assertions have equivalents — board state checks replace "mock called" where the real thing happened anyway.
- [ ] 3. Test count does not drop below current coverage (some may merge into combined runs: fill + save + open round-trip).
- [ ] 4. No failures introduced by removal (existing MockRenderer unit tests pass independently).
