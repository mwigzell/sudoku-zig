Triage: closed

### Depends on Issue 33 (MockRenderer command queue) — Steps 1-3 already done
### Must complete before Issue 33 Step 5 can be written
## What to fix

`MockRenderer.getCommandInput()` returns pre-baked `ParseCommandResult` from a command queue with **all data fields filled in** — including filenames that only exist because tests stuffed them in. This bypasses the real renderer's secondary dialog intercepts where user input is gathered *after* the initial parse to augment the command before exec().

Real `AsciiRenderer.getCommandInput()` (lines 162-170) intercepts `.save_as` after parsing, calls `self.saveAsDialog()` for filename, then overwrites `SaveData.path` with real user input. MockRenderer has the same interface method but does its thing in parallel: it just returns what's queued without calling secondary dialogs at all.

**The fundamental problem:** All 3 dialog methods — `saveAsDialog()`, `openDialog()`, and `newGameOptions()` — are already proven to work against canned input via `MockSource` in AsciiRenderer's own unit tests (lines 272-565). Those tests feed strings into a fake readline and the real dialog logic executes. We're not missing any mock functionality — we just need those same e2e `run:` tests to use the **real** renderer instead.

### Root cause
The Facade pattern is fine for runtime, but our e2e tests (`sudoku.zig` line 617 and 646) construct a MockRenderer that shortcuts every input path. The fix isn't to add more mock stubs — it's to construct an AsciiRenderer with mocked readline (MockSource) in the e2e tests instead. Commands, dialog responses, everything comes from the same string queue naturally — exactly as they would in production.

### Design: Replace MockRenderer with AsciiRenderer + MockSource in e2e tests
- `AsciiRenderer.init(alloc, mockSource)` — already exists and works (see lines 290-293)
- Feed command strings AND dialog response strings from the same canned source
- Real parsing, real intercept logic, real dialog methods — all tested end-to-end

### Steps

| # | Description |
|---|-------------|
| 1 | Re-write `"run: fill → save → quit"` to use AsciiRenderer with MockSource instead of MockRenderer. Feed command strings `fill 3a7`, `save`, `quit` as canned responses. Wrap in Facade (same as today). |
| 2 | Re-write `"run: save_as writes file and re-renders"` — feed `save_as` string, then filename string for the dialog response from MockSource. Assert save used the dialog filename. |  
| 3 | Run full test suite — verify all e2e tests pass alongside existing unit tests (MockRenderer's own unit tests at line 85 onwards can stay). |

### Acceptance criteria

- [x] 1. e2e `run: fill → save → quit` rewritten with AsciiRenderer + MockSource.
- [x] 2. Dialog responses are real input strings from MockSource, not pre-baked command data.
- [x] 3. All tests still pass (existing MockRenderer unit tests retained).
