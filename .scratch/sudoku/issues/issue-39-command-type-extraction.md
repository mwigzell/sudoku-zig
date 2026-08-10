triage: ready-for-human

## Working mode

Refactor — split `command/parse.zig` into behaviour-free types (generic) and ASCII text parsing (renderer-specific).

## Context

`command/parse.zig` conflates two responsibilities that the WASM renderer proves are distinct:

1. **Command data types** (domain-neutral): `CommandTag`, `Command` union, `FillData`, `ClearData`, `SaveData`, etc. These define what `GameEngine.exec()` consumes — every renderer must produce these.
2. **ASCII text parsing + disambiguation** (renderer-specific): `parseWithCommands()`, prefix matching, case-insensitive abbreviation resolution, ambiguity messages. Only exists because a terminal user types raw text into a line buffer. A WASM renderer produces structured data from clicks and DOM events — no text to parse.

The WASM renderer cannot import `command/parse.zig` just for the types without dragging in ASCII disambiguation logic it will never call. That's seam leakage.

## Steps

### Step 1: Create `src/command.zig` (top-level)
Pure data types, zero behaviour — the domain types `GameEngine.exec()` consumes:
- Move `CommandTag` enum from parse
- Move `FillData`, `ClearData`, `SaveData`, `OpenData`, `NewData` structs from parse
- Move `Command` union (tagged on CommandTag) from parse
- Move `ParseResultTag`, `ParseCommandResult` from parse
- Keep `getName(tag)` helper — it's data, not behaviour

### Step 2: Move ASCII parsing to `src/renderer/ascii/parser.zig`
Everything that turns raw text into commands:
- `parseWithCommands()` and all its internals (`prefixMatch`, `dispatchToParser`, individual verb parsers like `parseFill`, `parseClear`, etc.)
- `acronymOf()` / prefix disambiguation logic
- Ambiguity message building
- The comptime command table/registration (used by parse, so stays with the parser)

### Step 3: Wire up imports
Every file that imported from `command/parse.zig` for types now imports from `src/command.zig` instead. AsciiRenderer's `getCommandInput` imports its text parser from its local `parser.zig`. Parse tests move alongside the parser.

### Step 4: Verify test suite and coverage
All existing parse tests follow their code into `parser.zig`. No behavioural change — just location. All 202+ tests must compile and pass.

## Acceptance criteria

- [ ] `src/command.zig` contains only data types (structs, enums, unions) and trivial helpers that use them (like `getName`)
- [ ] `src/command/parse.zig` no longer exists — its contents are split between `src/command.zig` (types) and `src/renderer/ascii/parser.zig` (behaviour)
- [ ] No module in the project imports ASCII parsing logic as a side effect of needing command types
- [ ] AsciiRenderer's `getCommandInput` sources its parser from its own package (`./parser.zig`)
- [ ] All 202+ tests compile and pass — zero behavioural change
- [ ] WASM renderer can import command types without pulling in any ASCII or text-parsing code
