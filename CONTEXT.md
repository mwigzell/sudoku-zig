# CONTEXT — Sudoku in Zig (WASM)

## Project Goal

A playable Sudoku game as a WASM module compiled from Zig, running in the browser with a thin vanilla JS shell. A terminal front-end (AsciiRenderer) proves the architecture first; every front-end entry shares the same portable GameEngine core. (Note: a true TUI is an ncurses front-end — not implemented yet.)

See `.scratch/sudoku/prd.md` for full PRD and user stories.

## Coding Standards
See `docs/coding-standards.md` for all coding, testing, TDD methodology, and project architecture guidelines.

### JS flow-comment convention

For web-shell JS modules, comments should orient by **runtime flow and seam role**:

- Prefer short phase/signpost comments (e.g. startup phase boundaries, command lifecycle phases).
- Describe what the code is doing in the current architecture ("who owns what seam"), not commit history.
- Keep comments local and concise; avoid narrating obvious statements.
- Do not encode historical/process metadata in code comments (issue numbers, session/chunk references, dates).

### JS typedef convention

For web-shell JS modules, prefer explicit JSDoc typing to improve hover/help and cross-file navigation:

- Use shared aliases from `src/wasm/types.d.ts` for core seams (`GameApi`, session/startup/modal shapes).
- Annotate exported seam functions with `@param`/`@returns` when type intent is non-trivial.
- Avoid leaving broad `any` option fields when a concrete typedef exists or can be introduced cheaply.

## Language

### Board Layer

**Board**:
The outermost domain object holding the mutable game state: grid topology, timer, and derived conflict marks. Owns a Grid.
_Avoid_: Puzzle (that is the 81-character text Export and Import carry), GameState (implies framework)

**Cell**:
A single position on the board holding a value (empty or digit 1–9), locked/given flag, optional notes/candidates set, and per-cell conflict flags. Total: 81 cells across the full board.
_Avoid_: Tile, space, slot

### Grid Topology

**Box**:
The canonical owner of Cell[3][3]. Each Box knows its (boxRow, boxCol) position in the 3×3 meta-grid, which determines global (row, col) for each of its cells. Boxes contain; other structures derive.
_Avoid_: Region, square, block (unless used alongside "Box" as synonym)

**Grid**:
Immutable topology engine defining how 81 cells relate to one another — which belong together as a row, column, or Box. Contains the authoritative box[3][3] arrangement and provides RowView and ColView lenses across that owned data. The Grid never mutates; Board does.
_Avoid_: Layout matrix (implies rendering concern), Table

**RowView**:
A computed lens across three Boxes sharing a horizontal band, yielding 9 cell references corresponding to a global row index 0–8. Not an owned array — it assembles references from the Boxes that own the cells.
_Avoid_: Row slice (implies copying)

**ColView**:
A computed lens across three Boxes sharing a vertical band, yielding 9 cell references corresponding to a global column index 0–8. Like RowView, not an owned array.
_Avoid_: Column slice (implies copying)

### Rendering & Interaction

**Renderer** (native):
Interface for presenting Board state in the terminal. AsciiRenderer (ANSI or plain) is the concrete implementation today; it receives `Event` snapshots from the game loop and never reads Board internals directly. **All native terminal output** (board, prompts, session dialogs, **live puzzle-gen progress**) goes through the renderer **`Facade`** and its session **`Io.Writer`** — not stdout or `Io` hooks from domain modules. Gen progress: `Facade.reportGenProgress(GenProgressEvent)`. The browser does **not** use a Zig renderer — JS builds the DOM from wasm JSON (`GameSnapshot`).
_Avoid_: View (conflicts with RowView/ColView), UI, TUI (TUI = an ncurses front-end, not the current AsciiRenderer); parallel `Sudoku.out` / domain stdout for progress

**Event**:
Output of `GameEngine.exec()` after a gameplay command — `.ok` carries a `BoardView`, optional message, and `is_quit`; `.error_msg` carries a reason string. Native `Sudoku` passes this to the renderer facade. The wasm boundary serializes the same semantics as JSON (`boundary.zig` / `glue.js`). **Status copy is Event-sourced only**: `.ok.msg` → web status bar; `.error_msg` → acknowledgement modal (native `showError` analogue).
_Avoid_: Payload (ambiguous), State dump

**Command**:
Player action vocabulary (`fill`, `clear`, `undo`, `redo`, `quit`, plus session tags parsed but not executed in `GameEngine.exec`). Native: parsed from a terminal line. Wasm: JSON action payloads (`{"action":"fill","row":…}`). Carries intent, not state.
_Avoid_: Input action (framework term)

**GameEngine**:
Portable orchestrator. Gameplay `exec` (fill, clear, undo, redo, quit) mutates `State`, runs validation, and returns `Event`. Owns the SUD0 codec (`toSaveFormat` / `fromSaveFormat` on bytes). **No** `FileTransport`, paths, or `std.Io`. Session persistence is **not** in `exec`. Single cross-cutting native test seam: Command → GameEngine → Event.
_Avoid_: Engine alone (ambiguous — Solver Service also contains "engine" semantics), Controller (MVC framework term)

**Legend**:
State-aware command availability flags (`fill`, `clear`, `quit`, `undo`, `redo`, session commands). Native renderer formats these for the terminal; wasm exposes them as JSON via `getLegend()`.
_Avoid_: AvailableCommands (retired name)

### Validation & Solving

**Validator**:
Given a Board state, reports which cells conflict with the digit in their row (9-cell RowView), column (9-cell ColView), or Box (owned 3×3). Rules enforced at command time after every mutation.
_Avoid_: Checker (implies boolean only)

**PuzzleGen**:
Play path: **live generation** for `easy` / `medium` / `hard` via `generateForPlay` (fast strip, then dig-hole fallback), with **unique-solution** checks through **`solver.countSolutions`**. Optional **`GenProgressEvent`** callbacks during `generate()` — **no I/O inside this module**; hosts wire sinks (native Facade, wasm import, tests). **Test binary only:** fixed one-line fixtures (`useGenerateFixtures` / `builtin.is_test`). Legacy **`default`** remains a dot-blanked fixture string. Used by native startup/New, wasm `init`, and tests.
_Avoid_: stdout, threadlocal `Io`, or platform-specific generator policy inside `puzzle_gen`; treating canned lines as the play path outside tests

**Puzzle Repository** (domain slot):
Where puzzle data comes from. **`PuzzleGen` is the only implementation shipped** — live gen for play, fixtures for deterministic tests; no `PuzzleSource` trait yet. The wasm boundary passes difficulty via **`WireConfig`** at `init`; generated grids load as engine state (not a separate puzzle export on New). One-line strings cross to JS only as opaque text — picked or pasted puzzles go in through the core command flow (`flowRead`), `toPuzzle` brings them out — never by reimplementing the codec in JS.
_Avoid_: Puzzle store, PuzzleSource (name reserved for a future interface)

**Solver Service**:
Backtracking solver (`solver.zig`): completes boards, **`countSolutions`** (cap 2) for **generation uniqueness** and solvability probes, plus solve-for-me / hint paths. Pure — no I/O.
_Avoid_: Engine (collides with GameEngine)

### Hints (issue #48)

**Hint** (one command, one engine operation):
Digit advice backed by the **Solver Service**: a digit that appears in at least one solution of the board *as it stands* — a solvability query, **not** a candidate/constraint check (which can mislead or induce a dead end). Display-only: never writes cells, no history impact. If the board is in a no-solution state, hint answers that honestly instead of a digit — conflicts cannot express it; hint is the first feature that can.
_Avoid_: "suggestion", bare legal-digit check, a hint that could lead to an unsolvable state; separate "Board Hint" / "Cell Hint" menu items — one `hint` with an optional target

**Blocker**:
A cell you filled with a digit that **can't belong to any solution** of the board *as played* — the solver's no-solution verdict, pinpointed. **Global** violation: the board may show zero conflict flags yet a blocker exists, because conflicts are local (row/col/box) and blockers are solution-level. With unique-solution puzzles (all PuzzleGen output) blocker ⇔ a wrong player entry. Engine-pick hint ranks blockers first — the hint is the only feature that can name the culprit; the bit-mask conflict validator cannot.
_Avoid_: using "blocker" for conflict-flagged cells; a blocker is invisible to the validator

**Engine-pick mode** (`hint` with no target):
Engine picks the cell by locked ranking (issue #48): **(a) blocker** (name it) → **(b) empty cell with fewest local candidates** (solver-verified digit) → **(c) row-major tie-break**. Native: **`m` menu → Hint** with no `last_cell`; web: **Edit → Hint** while nothing is selected (deselect / Esc). The "what should I do next?" form.
_Avoid_: treating `hint` as always needing a named cell; answering a hint from local constraints alone

**Targeted mode** (`hint` with `{row, col}`):
User names the cell — native: `hint e5` (optional parser) or **menu Hint** when driver has `last_cell`; web: board `selection` when set (JS-owned, ADR-0011 target-as-arg). Engine answers that cell's solution-consistent digit (or the no-solution status).
_Avoid_: "hint at position", implying local-constraint derivation; a permanent auto-selected cell that silently forces targeted mode

### Flows and steps

**Flow**:
One piece of core behaviour run to its end: a command (Save, Save As, Export, Open, …), autosave, or startup. Core decides every move (`src/core/flow/`).
_Avoid_: naming a flow after one platform's handler

**Step**:
One operation a flow asks the platform to do, such as "ask this question" or "write the saved game to the current file". Named for what it achieves, not for the platform call that carries it out; a command's own step takes the command's name, and steps about the puzzle say `_puzzle` (ADR-0016). Each platform has one handler per step, used by every flow.
_Avoid_: generic steps told apart by a flag; a handler set per flow

| Step | The platform… |
|---|---|
| `resolve_default_target` | names the default file |
| `ask` | shows a two-button question |
| `save` | writes the saved game to the current file (web/Android: the bound file, else a picker), keeps the restore copy |
| `save_as` | writes the saved game to a file the player picks, suggesting the given name (native: the typed path) |
| `autosave` | writes the saved game to the bound or default file, never through a picker |
| `flush` | app closing: writes the saved game to the restore copy only |
| `export_puzzle` | writes the puzzle to a file; the current file is unchanged |
| `reclaim_file` | Android: lets the player pick the file an earlier install wrote, and writes the saved game there |
| `copy_puzzle` | copies the puzzle to the clipboard (native: prints it) |
| `paste_puzzle` | reads the puzzle from the clipboard |
| `restore` | startup: reads the saved game to restore |
| `open` | lets the player choose a saved game (native: reads the typed path) |
| `import_puzzle` | lets the player choose a puzzle file (native: reads the typed path) |
| `show_game` | draws the game with a status line |
| `generate_game` | generates a puzzle at the given difficulty |
| `forget_current_file` | stops restoring the file at startup, deleting it when told |
| `persist_settings` | stores the settings |
| `show_status`, `show_error`, `done` | ends the flow |

`save`, `save_as` and `autosave` carry `replace`: a handler writing a fixed file (native path, host default file, bound file) answers `exists` without writing when the file is there and `replace` is false; core then reissues with `replace` or asks "Replace file?" first, per the **Lane**. A picker never answers `exists`. A step a platform never receives (e.g. `reclaim_file` on native and web) answers failed with a reason for the log.

**Answer**:
What the platform reports back after a step (`Input`): the result, or a failure with a reason for the log. Writes answer `wrote` (`ok`, `exists`, `cancelled`, `taken`, `failed`); `restore`, `open`, `import_puzzle` and `paste_puzzle` share one `read` answer (bytes and an optional name, `cancelled`, or `failed`).

**Adapter**:
The platform code that carries out steps: native `Storage` and renderer; on web `flows/web_steps.js`, on Android `flows/android_steps.js` over the Java file bridge, both built on `flows/steps.js` and run by `step_runner.js`. It does mechanics only and decides nothing.

### What gets written

**Saved game**:
The full game (board, givens, history, status) in the SUD0 format, written by Save, Save As and autosave.
_Avoid_: platform function names (`toSaveFormat`, `fromSaveFormat`) when describing behaviour

**Puzzle**:
The board's cell values as exactly 81 characters of text, one per cell, row by row; any other length is rejected. Export and Copy write it with `0` for an empty cell; Import and Paste also accept `.` as empty.
_Avoid_: "line" or "puzzle line"; platform function names (`toPuzzle`, `fromPuzzle`)

### Files

**Current file**:
The file the current game belongs to (`FileSession`), set by Open, Save and Save As, and written by autosave.

**Bound file**:
On web and Android, the player's real file that the current file is tied to: a browser file handle or an Android document.

**Default file / default folder**:
`sudoku.sud` in the default folder (`Documents/Sudoku` on desktop, `Download/Sudoku` on Android). Autosave writes it when there is no current file. Core owns the file name and the **default folder name** `Sudoku` (`save_defaults.zig`); each platform chooses only the parent folder (Android reads the name through `JniHost.defaultFolderName`).

**Restore copy**:
The host's private copy of the game in its hidden data dir, read by Auto Restore at startup when the player's file is elsewhere.

**Picker**:
The platform's own file chooser (browser or Android). It asks its own replace question. On Android every picker starts in the bound file's folder, else in the default folder; the player can still browse away.

**Lane**:
Whether the next write continues the current file (continuation: no question) or starts fresh (detached: "Replace file?" when the file exists). Save As always starts a new lane.

### App Shell & Deployments

Front-end **entries** share one core; **shell** and **host** mean different layers. Use this table before inventing a new folder (e.g. an “Android shell” that duplicates JS UI):

| Term | Meaning in this repo | Android (ADR-0013) |
|------|----------------------|---------------------|
| **Native app shell** | `src/native/shell/` — terminal command loop, menu, `FileTransport` | Not used |
| **Web app shell** | `src/wasm/**/*.js`, `page.html`, `glue.js` — DOM, menubar, `exec` | **Same files**, loaded in WebView |
| **`web_host`** | Zig loopback HTTP + embedded bytes (`src/web_host/`) | Same module, background thread |
| **Android platform entry** | `src/android/` — JNI + minimal Java/DEX bootstrap (Activity, WebView, manifest) | Lifecycle + WebView; **not** a second JS shell |

There is **no** separate Android app shell beside native and wasm. Informal “Android shell” in ADRs means the thin **process host** (lifecycle + WebView + JNI), not new game UI.

**N front-end entries** (ADR-0011; `main` dispatches only):

| Entry | Wiring |
|--------|--------|
| Native terminal | `desktop_terminal` → `Host` + `Sudoku` |
| Desktop web | `desktop_web` → `web_host` + browser |
| Android host | `src/android/` → `web_host` + WebView (ADR-0013) |

**Sudoku** (`native/shell/shell.zig`, native app shell):
Owns the command loop and the renderer facade. Each command runs through the core command flow (`runCommandFlow` → `runFlow`); `runFlow` hands each step to the renderer (ask, show, generate progress, copy output) or to **Storage**. This is the native integrated e2e seam.
_Avoid_: folding session I/O into GameEngine

**Storage** (`native/shell/storage.zig`, native app shell):
Carries out the native file and settings steps: name the default target, `save` / `save_as` / `autosave` (`saveGame`), `export_puzzle`, `restore`, `open` / `import_puzzle` (the typed path), forget the current file, persist settings and the current-file pointer. Owns the `FileTransport` and `SettingsPersist`; decides nothing.
_Avoid_: policy here (which file, when to ask, what status to show — core decides)

**Web app shell** (`page.html`, `glue.js` and the `src/wasm/` modules, one concern each, grouped by role: `menus/` (menubar and each menu), `flows/` (`step_runner.js`, the step handlers `steps.js` / `web_steps.js` / `android_steps.js`, `startup.js`, `autosave.js`, `session.js`), `dialogs/`, `gen/` (worker generation and progress), with `app_boot.js`, `app_wire.js`, `board.js`, `status_bar.js`, `host_api.js`, `files.js`, `clipboard.js`, `client_log.js` at the top):
JS owns fetch, DOM, file UX, and user acknowledgement. Calls wasm exports; never parses SUD0 or projects a terminal screen. Gameplay goes through `exec(action_json)`; file and settings commands run core flows. Board cell selection (`readSelection`, pointer on the play grid) is shell-owned; **Edit → Hint** passes it as an optional hint target when set.
_Avoid_: reintroducing a wasm REPL or ASCII screen feed

**RendererKind** (`-r`, native only):
The user-facing renderer *place*: `ansi`, `ascii`, `tui`, `web`. `-r web` runs a loopback static server for embedded assets until the process stops (Ctrl+C); there is no native `Sudoku` play loop — the browser + JS shell is the runtime. Renderer selection is native-only; the wasm deployment is web by construction.
_Avoid_: calling the browser renderer "wasm"

**Host** (`native/host.zig`, terminal only):
Native terminal substrate — builds `IoSession`, selects AsciiRenderer facade arms. Not loopback web serving; that is **`web_host`**. Wasm has no `Host` type; the JS page is the substrate.
_Avoid_: folding `serve` / loopback into `Host`; "session" (that's the terminal substrate under it)

**web_host** (`src/web_host/`):
Loopback static server for the **web app shell** — routes, embedded page/JS/wasm, `host-config.json`, settings POST. Desktop `-r web` and Android WebView both use this layer; desktop browser open stays in **`native/desktop_web.zig`** (`open_browser`), not inside `web_host`.
_Avoid_: duplicating menubar/DOM in native or Java; calling it `native/host`

### Platform thinness contract (all front-end entries)

Front-end layers are adapters. They do I/O, lifecycle, and presentation; shared seams own behavior.

| Concern | Authority | Front-end role | Never in front-end |
|---|---|---|---|
| Domain rules and state semantics | `src/core/engine/`, `src/core/board/`, shared codecs | submit commands, render returned state | reimplementing game behavior |
| Session semantics (save/open/restore/new, conflict rules) | shared policy modules + host/domain seams | issue intent requests, present user prompts/results | local policy forks in JS/Java/renderer |
| Startup behavior | `src/core/startup/policy.zig` + `src/core/flow/startup.zig` (`StartupFlow`) | read the current file, draw, ask, generate, forget the file when told | per-platform startup decision trees |
| Configuration meaning and persistence schema | `src/core/config.zig` + `src/core/settings_store.zig` + host persistence seam | edit/view settings through exposed interfaces | parallel config schemas or defaults that override host contract |
| Cross-platform command availability semantics | engine/legend + shared contracts | wire controls to existing contracts | feature-specific rule variants per platform |
| Text the user sees (dialogs, status line, generation progress) | whoever implements the behaviour: core for engine, flows and generation (`src/core/`), the platform only for what it alone does | show core's text as-is; report a failure with a reason for the log | wording, fallback messages or raw error text for behaviour core owns; copies of core's formatters |

Rule: every supported front-end entry must remain transport-thin and behavior-consistent by consuming shared contracts, not redefining them.
Policy centralization is mandatory: in this shared-core multi-front-end architecture, front ends transport/render only; they do not fork rule decisions (persistence/autosave semantics, startup policy, or log filtering policy).
Text ownership follows the behaviour: if core implements it, core writes the words and adapters pass their technical reason to core for the log. A platform writes its own text only for something core does not handle (e.g. the web boot dialog when wasm fails to load). Either way, dialog and status text is full sentences. Generation is core behaviour on every platform: progress lines are core's `formatProgressEvent` text, native and web alike, and the web generating dialog's messages and method label come from core through `getGenText`.

### Policy authority map (core vs platform call sites)

Use this as a quick audit table when reviewing changes. Core owns policy; platform entries call into it.

| Policy | Core authority | Platform call sites |
|---|---|---|
| Command semantics + `Event` meaning | `src/core/command.zig`, `src/core/engine/game_engine.zig` | Native: `src/native/shell/shell.zig` (`engine.exec`). Web/Android: wasm API in `src/entry_wasm.zig`, called by `src/wasm/board.js`, `src/wasm/menus/{menu,file_menu}.js`. |
| Startup choreography (restore / new / idle, restore failure, solved restore, generation failure) | `src/core/startup/policy.zig` (`evaluate`), `src/core/flow/startup.zig` (`StartupFlow`) | Native: `src/native/shell/shell.zig` (`runStartupFlow` → `runFlow`). Web/Android: `src/wasm/flows/startup.js` (`runStartupFlow`) with the platform's step handlers after `app_boot.js` wires the idle session. Host JSON carries config and `startup_save_path` only; `DELETE /current-file` forgets (optionally deletes) the host's current file. |
| Autosave trigger set (which commands autosave) | `src/core/file_policy.zig` (`commandTriggersAutoSave`), applied by `src/core/flow/autosave.zig` | Play, edit, settings and load commands: the core command flow (`src/core/flow/command.zig`) runs autosave after the command; native `runCommandFlow`, web `runBoardCommand` / `runSessionCommand` → wasm `commandStart`. |
| Overwrite/replace lane policy (`detached` vs `continuation`) | `src/core/file_policy.zig`; state in `src/core/flow/file_session.zig` (`FileSession`) | Core records each load inside the command (`FileSession.noteLoad` for New/Open/Import/Paste). Native and web/Android run New/Open/Import/Paste through the core command flow (`open`, `import_puzzle`, `paste_puzzle`, `generate_game` steps); no adapter or host-side context. |
| Save / Save As / autosave choreography (name the target: typed path, else current file, else the platform default → write without `replace` → on `exists` reissue or ask → status; Save refused while Auto Save is on; Android "earlier install" ask → `reclaim_file` / `save_as`) | `src/core/flow/{step,save,autosave}.zig` (`Step` / `Input`); Save / Save As run inside `CommandFlow` | Native: `src/native/shell/shell.zig` (`runCommandFlow` → `runFlow`), file steps in `src/native/shell/storage.zig` (`Storage`). Web/Android: `src/wasm/flows/step_runner.js` (`runCommand`) with the handlers in `web_steps.js` / `android_steps.js`. Fixed-file writes answer `exists`; pickers own their own overwrite question. |
| Export / Copy (puzzle to a file or clipboard, default export name, status text) | `src/core/flow/export.zig` (`ExportFlow` → `export_puzzle` / `copy_puzzle`), run inside `CommandFlow` | Native: `src/native/shell/shell.zig` (`runCommandFlow`; Copy prints the puzzle). Web/Android: `file_menu.js` Export and `menu.js` `handleCopyPuzzle` via `runCommand`. |
| Settings schema + persistence semantics (which commands persist, the `settings.json` body) | `src/core/config.zig`, `src/core/settings_store.zig`, `src/core/flow/settings.zig` (`SettingsFlow` → `persist_settings`, run as a phase of `src/core/flow/command.zig` `CommandFlow`) | Native: `src/native/shell/shell.zig` (`runCommandFlow` → `runFlow`) → `src/native/shell/storage.zig` (`Storage.persistSettings` → `settings_store.save`). Web/Android: the shared `persistSettings` handler (`src/wasm/flows/steps.js`) posts core's body as-is through `host_api.js`; `src/web_host/mod.zig` merges/saves via `settings_store`. |
| Save format (SUD0 codec) | `src/core/engine/game_engine.zig` (+ wasm export surface in `src/entry_wasm.zig`) | Native: `src/native/shell/storage.zig` (`Storage.saveGame` for Save, Save As and autosave, `open` for Open) via `FileTransport`. Web/Android: wasm `toSaveFormat` out; picked bytes in through `flowRead`. |
| Log-level filtering policy | `src/core/logger.zig` (`min_level`) + startup/config wiring | Native: CLI/startup + engine config updates. Web/Android: host startup config + `/client-log` bridge in `src/web_host/mod.zig`. |

Startup outcomes, the same on every platform: a failed restore shows the idle board, asks "The file {file} could not be restored. Do you want to delete it?" (Delete / Keep) and always forgets the current file; a restored solved game asks "Puzzle solved" (New game / Keep), and New game generates at the saved difficulty; a failed generation shows the idle board then the error; a cancelled one goes straight to idle.

**Desktop web entry** (`native/desktop_web.zig`):
Wires **`web_host.runWithHostConfig`**, fatal bind errors, and **`whenHostReady`** → **`open_browser`**. Called from `main` when `-r web`.
_Avoid_: loopback or embed logic here; folding terminal `Host` into this module

**Desktop terminal entry** (`native/desktop_terminal.zig`):
Wires **`Host`**, renderer facade, and **`Sudoku`** play loop. Called from `main` for non-web renderers.
_Avoid_: web_host or browser open here

**Android platform entry** (`src/android/`, issue #64):
Minimal Java/DEX + JNI (`jni_host.zig`) — package **`com.wigzell.sudoku_zig`**, `MainActivity`, WebView, permissions, cleartext localhost. Starts **`web_host`** on a background thread; **`loadUrl`** when the port is bound. Launch: a native splash covers the WebView until the page reports boot-ready; the system bars stay dark until the splash is gone, then take the theme (`setSystemBars` calls are held until then).
_Avoid_: `android/shell` JS, Gradle app layer (default path), EGL UI in the same entry

**FileTransport** (`native/shell/file_transport.zig`, native arm):
Fn-pointer vtable for file read/write/resolve. **Owned by native `Storage`** (held by `Sudoku`) — not by `GameEngine`. The wasm path passes opaque bytes instead (`toSaveFormat` out, `flowRead` in); no wasm transport arm.
_Avoid_: "transport" alone, io (the point is GameEngine carries none)

**Config** (`config.zig`):
Nominal preferences — `difficulty`, `log_level`, `theme`, `show_region`, `warn_solvability` on disk; **`Config`** also carries renderer kinds for native host routing (CLI per run, not **`settings.json`**). Not puzzle cells or undo history. `GameEngine` owns `cfg` at `init`. Startup: load player prefs → CLI on full `Config` → save player prefs (**ADR-0014**). In session, disk-backed fields mutate via commands/`exec` and platform UI. They do not live in `Legend`, `State`, or SUD0.
_Avoid_: folding prefs into Legend or save files; JS boot defaults that override host-resolved config

**State**:
Board (flat 81 incl. given bits) + mutation history. No I/O. The unit the SUD0 codec and wasm boundary deal in. `GameEngine` wraps `State` and nominal `Config`.
_Avoid_: Engine (engine is a runtime object)

### WASM Wire (`wasm/wire.zig`, `wasm/boundary.zig`, `entry_wasm.zig`)

**WireConfig**:
Wasm wire twin of the `Config` fields JS reads/writes — `PlayerDifficulty` (1/2/3), log level, `theme`, `show_region`. Maps to `config.Config` at `init`; `getConfig()` returns the same JSON shape. Native-only renderer fields stay off the wire.
_Avoid_: passing puzzle bytes across the boundary; ad-hoc config JSON shapes

**GameSnapshot**:
JSON-serializable display twin of `BoardView` — per-cell `value`, `given`, `conflict`. Returned by `getState()` and embedded in successful `exec` responses. DOM shell renders from this shape.
_Avoid_: duplicating SaveFormat fields in JS

**entry_wasm**:
Second entry point (not `entry_native.zig`). Exports structured API: `init`, `exec`, `getLegend`, `getConfig`, `getState`, `toSaveFormat`, `toPuzzle`, and the core flow (`commandStart` / `flowNext` / `flowRead`, and `flowFail` when the web side cannot carry a flow on). JSON strings in linear memory (NUL-terminated); SUD0 bytes for save/load. Contract tested by `glue.test.mjs`.
_Avoid_: `step(line)`, `page_bytes_out`, or other REPL imports (removed — see ADR-0010)

**glue.js**:
Thin loader/instantiator — marshals JSON and byte buffers across the wasm export table. Shared by the served page and node contract tests.
_Avoid_: embedding game rules or SaveFormat parsing

## Architectural Decisions

See `docs/adr/` for numbered ADRs as cross-cutting decisions are recorded (e.g., ADR-0010 structured wasm boundary, ADR-0011 layer ownership, ADR-0014 persistent settings and in-app editing, ADR-0013 Android entry options).
