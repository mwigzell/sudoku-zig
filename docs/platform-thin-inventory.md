# Platform Thinness Inventory

What each front end (web JS, Android WebView + bridge, native terminal) still does, and why it is adapter work rather than policy. Core decides; adapters carry out steps and report facts (`src/core/flow/`, ADR-0011, ADR-0014).

- `CORE` - decided in shared code; adapters only call it.
- `KEEP` - adapter mechanics (I/O, lifecycle, presentation), with the reason it cannot live in core.

## Commands

| Command | Core owns | Adapter does | Tag |
|---|---|---|---|
| New | Generation, board swap, status text, `FileSession.noteLoad(.new_game)`, then the autosave flow | Difficulty dialog, generating modal / worker, render | `CORE` |
| Open | Decode, board swap, status text, `noteLoad(.open)` (working file), then the autosave flow | File picker or Android open bridge; binding the picked handle so later writes reach it | `CORE` |
| Import / Paste | `importFromLine` / `pasteFromLine` codec and status text, `noteLoad(.import / .paste)`, then the autosave flow | Text file picker; clipboard read (or native `paste` line input) | `CORE` |
| Save / Save As | `SaveFlow`: target choice, overwrite question, refusing Save while Auto Save is on, status text, working file | Picker, bound handle, Android bridge or download; host restore copy | `CORE` |
| Autosave | `AutosaveFlow` after every command; Android "earlier install" question and retry (`Wrote.taken` → `pick_existing` / `pick_new`) | Writing the bound file; the two Android pickers | `CORE` |
| Export | `ExportFlow` (`write` step, "exported to:" status, errors) | Text picker or download; native writes through the file transport | `CORE` |
| Copy | `ExportFlow.toClipboard` (`copy_line` step, status, errors) | Clipboard write (web) or printing the line (native: no clipboard) | `CORE` |
| Undo / Redo / Hint / Solve / fill | Engine command, status text, win detection ("You win!"), then the autosave flow | Key and menu wiring, render | `CORE` |
| Settings edits | `SettingsFlow` decides whether `settings.json` is written | Settings dialog; host POST or native `settings_store` write | `CORE` |
| Startup | `StartupFlow`: restore, auto-new, first board | Fetching host config and the current file | `CORE` |
| Menu enablement | `GameEngine.getLegend()` (Save off while Auto Save is on) | Disabling items from the legend | `CORE` |

## Adapter mechanics

| Area | File/symbols | Why it stays in the adapter | Tag |
|---|---|---|---|
| Web status and modals | `src/wasm/status_bar.js` (`applyEventStatus`), `error_modal.js` (`showErrorModal`) | DOM presentation of core text | `KEEP` |
| Web board and selection | `src/wasm/board.js` | DOM rendering and pointer/key input | `KEEP` |
| Web step handlers | `src/wasm/step_runner.js`, `autosaveHandlers`, `saveHandlers` | Carry out one step each with browser APIs; no branching on outcomes | `KEEP` |
| Web pickers, download, clipboard | `src/wasm/file_menu.js` (`persistBytes`, `pickBytes`, `persistPuzzleText`), `clipboard.js` (`startCopyPuzzleOnClick`, `readClipboardText`) | Browser and Android bridge APIs exist only in the page | `KEEP` |
| Menubar drag-release | `src/wasm/menu_bar.js` | DOM event mechanics | `KEEP` |
| Android WebView bootstrap | `MainActivity.java` (`onCreate`, `injectBridgeShim`), `page.html` boot-ready signal | WebView lifecycle | `KEEP` |
| Android URI bridge | `MainActivity.java` (`saveCurrentSudokuFile`, `saveSudokuFileToExisting`, `openSudokuFile`) | Storage Access Framework and MediaStore; reports `default_taken` as a fact for core | `KEEP` |
| Android host lifecycle | `src/android/jni_host.zig` | Loopback host thread start/stop | `KEEP` |
| Native renderer and loop | `src/native/host.zig`, `src/native/shell/shell.zig` (`turn`, `runFlow` step execution) | Terminal substrate and step execution against the file transport | `KEEP` |
