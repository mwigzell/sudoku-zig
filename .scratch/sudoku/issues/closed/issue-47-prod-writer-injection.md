triage: needs-triage
Status: closed

## Inject the prod-branch output writer instead of fabricating stdout inside the factory

`ascii_renderer_alloc.zig` coverage is **76.25%** — the uncovered lines are `prodBranch` (lines 19–40): the real-terminal wiring. The factory hard-codes `std.Io.File.stdout()` (line 20), which both breaks in-process testability and violates "entry point owns process handles" (main already owns stdin via `init`).

### Target shape — IoSession (converged 2026-08-15; source of truth)

> Note: exact 0.17 spellings (inner `Io.Writer` field names, `Allocating.create` shape) to be confirmed against the toolchain's std during chunk 1 — this sketch defines the *structure*, not the spelling.

```zig
pub const WriterSource = union(enum) {
    stdout: std.Io.File.Writer,     // process-owned fd; no allocator involvement
    mock: std.Io.Writer.Allocating, // owns a heap buffer; only its deinit() finishes it
};

pub const IoSession = struct {
    reader: ReaderSource,
    writer: WriterSource,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *IoSession) void {
        switch (self.writer) {
            .stdout => {},            // value on the stack; fd belongs to the process
            .mock => |*w| w.deinit(), // releases inner buffer via self.alloc
        }
    }
};
```

- Terminal I/O session only: keyboard-in / screen-out + the deinit allocator.
- **`alloc` is load-bearing, not borrowed:** per-branch; feeds the mock writer's `deinit()` and the contexts' renderer/styler allocations — mock branch carries `std.testing.allocator` (leak-checked), prod carries the page allocator.
- **No `io` member on the session:** `std.Io` is a copyable token; each channel captures its own copy at init (source changes below). An envelope-level io would keep the shared-token-passing pattern alive for no benefit.
- **Engine is NOT a consumer of IoSession:** save/open is a file-I/O channel; `GameEngine` keeps receiving `io` directly, separately.
- **Why the writer union needs a deinit tag and the reader union does not:** `ReaderSource` owns no heap state (holds caller-owned `responses`; `dupe`d lines go back to the caller); the `.mock` writer variant owns a buffer only its own `deinit()` can release. The tag is what lets `IoSession.deinit()` finish it off.
- Collapses the `makeFacade(is, alloc, io)` trio to `makeFacade(session)`; `sudoku.zig:26` (`is.allocatorForTest()`) becomes `session.alloc` and the accessor can go.

> **Constructed only at the entry points** — `main.zig` / test entries, the only places with both `std.Io` and the right allocator. Variants held by value:

```zig
var w = std.Io.File.stdout().writer(init.io); // confirm exact 0.17 spelling
var session = IoSession{
    .reader = ReaderSource.stdin(StdinSource{ .allocator = alloc, .io = init.io }), // field names per chunk 2
    .writer = .{ .stdout = w },
    .alloc = alloc,
};
// ... game loop ...
session.deinit();

// test entries: same shape, .mock variants (chunk 4)
```

**Source changes (per-source, both branches stay self-contained):**
- `StdinSource` captures `std.Io` at init — today `readLine(io)` threads io only because the `ReaderSource` union signature needs a common parameter and `MockSource` ignores it (`_ = io`, input_source.zig:48).
- Once both variants own what they need at init, `ReaderSource.readline()` drops the io parameter, and `AsciiRenderer` drops its `io` field (only uses: lines 107, 175).

### Steps — four chunks, minimal churn, each ends green and is one commit

**Chunk 1 — prod writer injection (issue core, minimal form)**
1. RED: `integrated e2e - prodBranch renders real grid into in-memory writer` — builds the prod-path facade with an injected in-memory writer, asserts buffer content. Fails: no injected-writer entry exists.
2. GREEN: factory prod path accepts a caller-owned `Io.File.Writer`; `ProdFacadeContext.writer` borrows it; delete `alloc.create` (ascii_renderer_alloc.zig:19) and `alloc.destroy` (:80) — the field is only referenced by that destroy (grep before deleting); main.zig constructs the writer stack-local and threads it: `Sudoku.init` → `buildFacade`.
3. Verify: `zig build test` (<5s), `zig build run` still prints the puzzle, `zig build cov` shows ascii_renderer_alloc.zig above 76.25%.
4. Commit.


**Chunk 2 — StdinSource io capture (pure refactor, no behaviour change)**
1. `StdinSource` captures `io` at init; `ReaderSource.readline()` drops the io parameter (`_ = io` in MockSource disappears); `AsciiRenderer` drops its `io` field (uses: lines 107, 175).
2. Verify: full suite green, identical `zig build run` output. Commit.


**Chunk 3 — introduce WriterSource + IoSession (prod side only)**
1. New module `src/io_session.zig` with the shapes above (the sketch is the spec); reachable from `sudoku.zig` so its tests enter the suite.
2. main.zig builds the `IoSession` value; `Sudoku.init(cfg, session, io)` (io stays for the engine); `buildFacade(session)`; `sudoku.zig:26` becomes `session.alloc`; drop `ReaderSource.allocatorForTest()` once unused.
3. Prod context borrows `*Io.Writer` off the union accessor. Verify suite green + `zig build run`. Commit.


**Chunk 4 — move mock writer ownership into the union**
1. `MockFacadeContext` stops owning its `Writer.Allocating` (delete its create/deinit/destroy); the mock variant lives by value in `session.writer.mock`; test entries build the mock session and call `session.deinit()`.
2. Verify: full suite green — the testing-allocator leak check now covers the mock buffer via `IoSession.deinit`; coverage; `zig build run`. Commit.


**After all chunks:** `zig build clean`, full `zig build test` + `zig build cov`, record final percentages.

**Close-out (2026-08-16):** `zig build clean` → full suite green; `echo quit | zig build run` → exit 0. Final coverage: `ascii_renderer_alloc.zig` 95.88%, `io_session.zig` 100.00%, `ascii_renderer.zig` 92.58% (issue baseline >76.25% cleared with margin). Post-close review followups in the same session: dead main.zig comment removed, `.stdout` accessor test added, branches consolidated on generic `buildContext`, duplicate branch test removed, `clearScreen` removed entirely (user decision).

### References


- Predecessor: `closed/issue-46-eliminate-duplicated-vtable-wrappers.md`
- WASM renderer (seam context, not the justification): `issue-40-wasm-renderer-stub.md`, `03-wasm-browser-renderer.md`
- Stdio plumbing sources: `input_source.zig`, `sudoku.zig` (lines 25–36), `main.zig`
