triage: ready-for-agent
status: closed

## buildFacade allocator mismatch — GPF on e2e tests

`buildFacade()` sets `renderer.allocator = arena`. When MockSource returns a `std.testing.allocator` slice, renderer calls `self.allocator.free(raw)` → arena frees testing memory → GPF.

### Fix: Switch on input_source in buildFacade

Inside `.ansi`, switch on the `ReaderSource` to get the correct allocator via `is.allocatorForTest()`. The allocator is transparent — always the right one for the job:

1. **Stdout strategy buffer:** allocated from source's allocator (not arena stack literal)
2. **Styler:** heap-allocated on source's allocator (fixes dangling stack pointer too)
3. **Renderer internal allocator:** passes source's allocator through `init()`

Effect: tests use `std.testing.allocator`, production uses `page_allocator`. No split inits.

### Steps

1. Switch on `ReaderSource` tag inside `.ansi` branch of buildFacade
2. Get allocator from source via `is.allocatorForTest()`, pass to renderer init
3. Allocate Styler on the source's allocator (not stack)

### Acceptance Criteria

x Step 1: root.zig test tuple includes all missing modules
x Step 2: buildFacade switches on ReaderSource, uses correct allocator everywhere
x Step 3: All e2e tests pass without GPF
x Step 4: Production path unchanged (AnsiStyler, real stdout)
x Step 5: allocatorForTest() field name fixed in input_source.zig
x Step 6: Full suite passes via zig build test — 214/214 pass, no GPF
