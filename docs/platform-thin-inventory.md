# Platform Thinness Inventory

Purpose: implement Issue #72 step 2 by cataloging behavior currently implemented in platform adapters and tagging each item as:

- `KEEP` - adapter concern (I/O, lifecycle, presentation wiring).
- `EXTRACT` - shared semantic concern that should live in shared seams.

Scope: `src/wasm/`, Android bootstrap/bridge, and native UI-session layers.

## Legend

- `Adapter` = entry/UI layer (`wasm` shell + page wiring, Android WebView bootstrap, native terminal driver/renderer wiring).
- `Shared seam` = domain/policy modules consumed by adapters.

## Inventory

| Area | File/symbols | Current behavior | Tag | Target home |
|---|---|---|---|---|
| Web status rendering | `src/wasm/shell.js` (`applyOkStatus`, `applyEventStatus`, `showErrorModal`, `wireErrorModal`) | Maps engine/host responses to status bar/modal UI | `KEEP` | wasm adapter |
| Web board rendering/selection | `src/wasm/board.js` (`renderBoard`, `wireSelection`, `parsePlayKey`) | DOM rendering and selection/input wiring | `KEEP` | wasm adapter |
| Web menu/pointer wiring | `src/wasm/menu.js` (`wireEditMenu`, `handleCopyPuzzle`, `handlePastePuzzle`) | Binds DOM controls to existing commands | `KEEP` | wasm adapter |
| Web file picker wiring | `src/wasm/file_menu.js` (`persistBytes`, `pickBytes`, `downloadBytes`) | Browser/bridge file picker and download plumbing | `KEEP` | wasm adapter |
| Android WebView bootstrap | `src/android/bootstrap/MainActivity.java` (`onCreate`, `injectBridgeShim`) | Starts WebView, injects JS bridge, boot splash/error UX | `KEEP` | Android adapter |
| Android URI I/O bridge | `src/android/bootstrap/MainActivity.java` (`saveSudokuFile`, `openSudokuFile`) | Marshals bytes to/from Android document providers | `KEEP` | Android adapter |
| Android host lifecycle | `src/android/jni_host.zig` (`startHost`, `readyPort`, `stopHost`) | Starts/stops loopback host thread and reports bound port | `KEEP` | Android adapter entry |
| Native renderer lifecycle | `src/native/host.zig` (`facade`, `writer`, session init) | Constructs terminal substrate and renderer facade | `KEEP` | native adapter |
| Native command/session loop | `src/native/shell/shell.zig` (`turn`, renderer dispatch) | Reads command input and presents output | `KEEP` | native adapter |
| Startup payload parsing in web adapter | `src/wasm/shell.js` (`assertHostStartupConfig`, `initializeWebSession`, `offerInitialNewGame`) | Adapter validates/branches on startup semantics | `EXTRACT` | shared startup seam + host payload contract |
| Session policy branching in web adapter | `src/wasm/shell.js` (session orchestration helpers) | Adapter encodes semantic session decisions | `EXTRACT` | shared policy seam |
| Session policy branching in native adapter | `src/native/shell/shell.zig` (session-side behavior decisions) | Native entry carries behavior semantics not shared | `EXTRACT` | shared policy seam consumed by entries |
| Semantic event-name mapping in adapters | `src/wasm/shell.js` + UI callers | Adapter defines behavior transition vocabulary | `EXTRACT` | shared contract module |
| Duplicate decision paths across adapters | `src/wasm/*` + `src/native/shell/*` + host wiring | Same behavior class decided in multiple entry layers | `EXTRACT` | single authority module + thin adapter calls |
| Contract-shape literals in page wiring | `src/wasm/artifacts/page.html` (boot flow + session orchestration) | Entry page carries behavior sequencing details | `EXTRACT` | wasm adapter should call thin helper API only |

## Step-2 Output: extraction backlog

1. Introduce thin adapter-facing APIs that accept intent and return outcome payloads from shared seams.
2. Replace adapter-side behavior branching with calls into shared authority modules.
3. Leave adapter-only responsibilities (I/O bridges, rendering, lifecycle callbacks, DOM/terminal wiring) in place.

This inventory intentionally separates transport/presentation concerns from behavior semantics so Step 3 can move only the `EXTRACT` rows.
