triage: closed

## Working mode

Refactor — type consolidation + rename. Zero behavioural change.

## Preamble

Grilled decision from architecture review (2026-08-11): three types need to go home where produced/consumed, one struct needs its real name revealed, and facade.zig stops alias-re-exporting types from parse. All changes are renames + file moves — imports update everywhere the types surface.

## Steps

### Step 1: Kill facade alias-re-exports
facade currently aliases three types from command/parse via `pub const X = command_parse.X`. Delete all three — callers import parse directly next time they need one of these types.
- [x] Remove lines 3-5 (SaveFileResult, OpenFileResult, ParseCommandResult aliases)

### Step 2: Rename PuzzleReturn → PuzzleResult + move to parse
PuzzleReturn is a command data payload (wraps owned puzzle string or Cancelled). Same shape as SaveFileResult/OpenFileResult — belongs with them in parse. Renamed for consistency ("-Result" suffix family). Currently in facade.zig, should be alongside other parsed-command data types.

### Step 3: Move NewGameChoice + NewGameChoiceResult from parse → facade
These define the renderer↔engine UI dialog contracts for `.new` sub-dialogs. Not parsing logic, not command data — they're a Facade-level seam. WASM renderer will also produce them. Currently buried in parse.zig (534 lines) where other parsed-result types live alongside them. They belong with facade.Error and the vtable signatures that consume them for new-game flow.

### Step 4: Rename AvailableCommands → Legend + move from game_engine to legend
AvailableCommands is a state-aware legend configuration: game engine sets the booleans, AsciiRenderer/WasmRenderer display it via showLegend(). The name "available commands" hid its actual job — it's the legend entity itself. It gets decorated as "(S)ave [Ctrl+Z]Quit" etc. by `command/legend.zig` which already owns formatting + decoration logic; disambiguate provides prefix entries. Rename + move ties them together at the seam.
- [x] Rename struct AvailableCommands → Legend in game_engine, move declaration to command/legend.zig
- [x] Update all callers of getNames/getAvailableCommands to use Legend/getLegend terminology
- [x] Update Facade showLegend_fn signature from AvailableCommands → Legend (getCommandInput_fn is NOT changed — see Step 5)
- [x] Update game_engine method getAvailableCommands() → getLegend() returning Legend

### Step 5: Narrow getCommandInput parameter surface
getCommandInput doesn't need the full Legend struct — it only needs the array of command names that parseWithCommands will use to resolve prefixes and dispatch. Passing raw `[]const []const u8` strings shrinks the interface to exactly what gets parsed and removes Legend from inside the parsing seam.
- [x] Rename Facade getCommandInput_fn parameter from AvailableCommands → `names: []const []const u8`
- [x] Update all callers (AsciiRenderer, tests) to pass the names array directly instead of constructing/passing a full Legend struct
- [x] Verify showLegend still receives Legend for display formatting

## Acceptance criteria

- [x] facade.zig has zero alias-re-exports — no `pub const X = command_parse.X` pattern remains
- [x] PuzzleResult sits in command/parse.zig (renamed from PuzzleReturn)
- [x] NewGameChoice + NewGameChoiceResult moved to renderer/facade.zig (from parse)
- [x] Legend struct lives in command/legend.zig (renamed from AvailableCommands)
- [x] Game engine method returns Legend via getLegend() instead of getAvailableCommands()
- [x] Facade vtable uses Legend type in showLegend_fn only (getCommandInput_fn takes raw name strings, not Legend)
- [x] All imports updated: any file importing these types through facade or parse now points at the correct home
- [x] No behavioural change — all tests compile and pass `zig build test`
