Status: closed
Triage: ready-for-agent

- 2026-08-07: User requested "integrated e2e - " prefix convention for all MockSource + AsciiRenderer e2e test names. Applied to existing 4 integrated tests in sudoku.zig (lines 425, 629, 665, 704). Convention saved to persistent memory for future test naming.

### Categorization (triage decision)

**Bucket 1 — Simplified (just init + validate)**: Replace MockRenderer with real renderer but don't need a full `.run()` loop. These verify constructor/field wiring, not gameplay.
| # | Test | Rationale |
|---|------|-----------|
| 1 | `Sudoku.init uses config difficulty to build the board` (line 130) | Just calls init, checks one cell on engine.board |
| 2 | `Sudoku.init with .medium difficulty loads medium puzzle` (line 146) | Same pattern as #1, different difficulty |
| 3 | `Sudoku stores io field during init` (line 376) | Only assertion is `_ = sudoku_instance.io;` — proves the field exists. Trivial init wiring test. |


**Bucket 2 — Converted to integrated e2e**: Full `.run()` loop with real AsciiRenderer + MockSource to exercise dialog caching, parsing, and intercept logic end-to-end.
| # | Test | Rationale |
|---|------|-----------|
| 4 | `full seam: f A3 4 -> prefix dispatch` (line 388) | Currently calls handleResult with pre-parsed command. Feed `"fill A3 4"` through canned input, verify board state + undo availability post-run. |
| 5 | `handleResult: save success produces status msg, re-render, legend refresh` (line 480) | Drives parse("save") but bypasses dialog intercept. Convert to full run loop with canned `"save"` → filename prompt → verify output buffer grew. |
| 6 | `handleResult: open success produces status msg, re-render, legend refresh` (line 508) | Drives parse("open /path") directly — exactly what Issue 32 fixed. Convert to canned `"open"` → filename prompt. |
| 7 | `handleResult: save uses default filename and returns success` (line 571) | Similar to #6 but for save path with default filename. Convert to full run loop asserting output buffer grew after save. |


**Bucket 3 — Redundant, drop entirely**: Duplicated coverage or assertions that no longer add value.
| # | Test | Rationale |
|---|------|-----------|
| 8 | `handleResult: open with relative path resolves without panic` (line 539) | Just verifies "no panic on relative path". The path resolution via path.zig is already covered by bucket 2 test #6 above, and the regression panic fix is tested at a different level. Dropping this adds no coverage loss. |
| 9 | `handleResult: subsequent save reuses previous filename with feedback` (line 597) | Tests dialog caching (second save skips prompt). Already covered by existing e2e test "integrated e2e - run: fill → save → quit" which drives the full input loop through real renderer dialogs. Redundant after that conversion. |

### Current State

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

### Steps

| # | Description |
|---|-------------|
| 1-3 | Convert `Sudoku.init` tests (bucket 1): replace MockRenderer with real renderer + empty mock source. These verify constructor wiring, assert against engine state only. |
| 4-7 | Convert the four bucket 2 tests to integrated e2e: full `.run()` loop with canned input through real AsciiRenderer dialogs. Verify board / undo status and output buffer growth. Prefix "`integrated e2e -`" per naming convention. |
| 8 | Drop test #8 (`handleResult: open with relative path resolves without panic`) — redundant after bucket 2 test #6 covers path resolution |
| 9 | Drop test #9 (`handleResult: subsequent save reuses previous filename`) — covered by existing `integrated e2e - run: fill → save → quit` |
| 10 | Run full test suite, verify pass rate >= 219 (accounting for 2 dropped tests) |
### Acceptance criteria

- [x] 1. `sudoku.zig` has zero references to `MockRenderer`. (Its own tests in mock_renderer.zig stay.)
- [x] 2. Bucket 1 tests simplified to init + engine state assertions only, no run loop needed.
- [x] 3. Bucket 2 tests converted to full e2e with "`integrated e2e - `" prefix, exercising dialog intercepts through real AsciiRenderer.
- [x] 4. Bucket 3 tests dropped — their coverage is duplicated by existing integrated e2e tests.
- [x] 5. No net loss of test coverage over pre-conversion baseline (verify with `zig build cov`). Coverage: 96.79% (up from ~96.77%).
- [x] 6. MockRenderer's own unit tests in mock_renderer.zig still pass independently.
