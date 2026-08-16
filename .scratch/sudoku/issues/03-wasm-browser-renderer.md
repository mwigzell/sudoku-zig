triage: ready-for-human

## Parent
## Parent

`.scratch/sudoku/prd.md`

### Step 0: WASM toolchain prototype (spike)
- Create `examples/wasm-hello/` with a minimal Zig module compiled to `wasm32-freestanding`
- Export a simple function (e.g. `add(a, b)`) and call it from a JS shell in an HTML page
- Prove the build path works on the dev machine: `zig build-lib --target wasm32-freestanding` → `.wasm` → browser loads it via `WebAssembly.instantiate`
- Document any gotchas (memory sharing, string boundary crossing) for later steps

## Steps
## What to build

Extract rendering behind an interface now that duplication exists (TUI + browser). Compile the same Zig GameEngine as a WASM module. Thin vanilla JS shell listens for JSON events from Zig exports and renders DOM from those snapshots. Commands flow in the opposite direction: JS sends command strings (e.g., `"fill 3 5 7"`) through exported entry points. Both renderers — TUI and browser — must work simultaneously with zero code duplication in game logic.

Key decisions that may arise during implementation (decide now, inline if precise):
- Command schema: string format over the WASM boundary (must match or generalize the TUI command format). You may choose a typed struct if Zig's WASM ABI supports it cleanly — keep it simple.
- Event schema: JSON snapshot of full `Board` state pushed after each command. Must contain everything a renderer needs to draw the grid (cell values, given/locked flags, conflict flags).
- `build.zig`: add both native and WASM build steps; TUI target uses `main.zig`, WASM target strips I/O and exposes exported functions.

Tests: same integration tests from issue #2 still pass — they exercise GameEngine's command→event seam independently of any renderer.

## Acceptance criteria

- [ ] Renderer interface (or equivalent Zig trait/struct vtable) exists with at least one rendering method (e.g., `render(board_snapshot)`)
- [ ] TUI renderer is a concrete implementation of the interface (refactored, not rewritten)
- [ ] WASM build target produces `.wasm` via `build.zig`
- [ ] JS shell loads the WASM module in a browser page and renders the same puzzle from issue #1
- [ ] Player can fill/clear cells in the browser (issue #2 commands work over WASM)
- [ ] Conflicts are visually highlighted in the browser grid
- [ ] Both TUI (`zig build run`) and browser renderers operate with the same GameEngine code — no duplication of domain logic

## Blocked by

Issue 40 (wasm-renderer-stub) — toolchain, Facade dual-renderer proof, build plumbing
