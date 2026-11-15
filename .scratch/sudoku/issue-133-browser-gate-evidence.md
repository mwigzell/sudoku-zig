# #133 — browser gate: recipe, evidence, and why the filed recipe could not run

Run: 2026-11-15, `develop` at `33611bb` (the merge of sandcastle run 1794716532214).
Host: confucius, Chrome 151 headless via `agent-browser 0.43.0`.

## The filed recipe cannot run

> run `-r web` with a corrupt `config.json`, trigger a save, and read core's sentence in the page's status line

ADR-0021 decides that a `config.json` which exists and cannot be used is **refused at startup**.
The desktop entry turns that into exit 1, so no page exists to trigger anything:

```
info(sudoku): starting desktop: sudoku-zig 0.1.0 debug (33611b) — built 2026-11-15 — MIT
warning(sudoku): config file does not parse: SyntaxError
error: System
  config.zig:177 in resolveStartupConfig
  entry_native.zig:55 in main
```

The refusal reaches a *page* only when the settings file becomes unusable (or unwritable)
**after** the host is already serving. That is the reachable case, and it is the one that was run.

## Runnable recipe

1. Sandbox the app's state so the player's real files are never touched:
   `HOME=/tmp/sudoku-gate BROWSER=/bin/false zig build run -- -r web`
   (data dir becomes `$HOME/.local/share/sudoku`; `BROWSER=/bin/false` keeps the opener chain quiet).
2. Start healthy (no `config.json` at all → first start), open the served URL.
3. Acknowledge the boot prompt, then **Save As** — with no current file, Save is disabled and
   Save As is the action that writes the file and records the pointer.
4. Corrupt the settings file mid-session: `printf '{ this is not json' > <data dir>/config.json`.
5. Save As again → core's sentence in the status line.
6. Repair it: `printf '{"config":{"difficulty":"easy"},"current_file":null}' > <data dir>/config.json`.
7. Save As again → the save succeeds and the pointer is recorded.

Headless Chrome cannot show the OS save dialog, so `window.showSaveFilePicker` was replaced with a
fake handle (no-op writable). Only the OS dialog is substituted; the page, the wasm core, the host
and the HTTP round trip are real. `adb`-style device gates need a device; this one needs a dialog.

## Evidence

Refused half — status line and the acknowledgement core asks for:

```
status-bar text: "The game could not read its settings file. Repair or delete it, then try again."
prompt-dialog:   title "Error"   text "The game could not be saved."   button "OK"
host log:        error(web_host): client-log [flow] write of sudoku.sud failed: current-file persist failed: 500
```

Repaired half:

```
status-bar text: "The game was saved to gate.sud."
config.json:     "current_file":"/tmp/sudoku-gate/.local/share/sudoku/gate.sud"
host log:        info(sudoku): SAVE wrote 299 bytes -> .../gate.sud
                 info(web_host): current-file write: bytes=299 target=.../gate.sud restore_copy=true
```

## Side finding — #135 reproduced live

On the refused save, the bytes had already landed before the pointer write was refused:

```
info(sudoku): SAVE wrote 15 bytes -> .../gate.sud
warning(sudoku): config file does not parse: SyntaxError     ← pointer write refused (500)
```

and a `DELETE /current-file` carrying the delete flag removed `gate.sud` while the pointer write was
refused again, leaving a settings file that pointed at a deleted game. That is #135's claim, with a
transcript.

## Note on the host half (no browser needed)

`POST /current-file` with the settings file corrupt answers 500 with core's sentence in the body;
after the file is repaired it answers 204 and stores the pointer.
