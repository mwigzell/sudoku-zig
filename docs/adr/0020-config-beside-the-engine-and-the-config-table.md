# ADR-0020 — Config beside the engine, one config table, `config.json`

Status: accepted
Date: 2026-11-07
Supersedes: ADR-0014's "Authority and runtime copy", "Persistence file" and native menu seam; ADR-0009's per-pref `getCommandInput` scalars

## Context

Adding or removing one Config field meant editing every layer by hand, in the same order. `show_marks`, one boolean, appeared 99 times across 27 files. Each field had its own command (`toggle_region`, `set_theme`, … nine in all) with its own `Command` tag, parser arm, wasm action and JS caller. The facade and terminal menus took the fields one by one as arguments. The config JSON was written and read field by field in `wire.zig`, `boundary.zig` and `settings_store.zig`, and the page listed the fields again in `glue.js`, `startup.js` and `types.d.ts`. The engine stored the whole Config but used two fields.

## Decision

- **Config is held beside the engine**, like `FileSession`: each platform holds engine, file session and Config. The engine is given the fields it plays by (`warn_solvability`, `show_marks`); the command flow owns `set_config`; wasm `getConfig` reads Config directly.
- **One config table in core** (`src/core/config_table.zig`, comptime, read-only): one row per saved Config field with its label and kind — on/off, or fixed choices with a name and a label each. A comptime check ties the rows to Config's saved fields and the choices to the field types. Difficulty offers Easy, Medium, Hard, never `default`.
- **Every Settings menu is drawn from the table** — terminal Menu → Settings and web File → Settings — and shows every Config field with core's label. Extras stay hand-placed (web View: theme, Show Region, Show Pencil Marks; web File → Auto Save; terminal Menu: region, marks) and take their words from the table too. The page gets the table once at boot (`getConfigTable`: `{on, off, rows}`).
- **One command:** `set_config { field, value }` with an explicit value; a toggle sends the opposite of the current value. Core checks it against the table and refuses an unknown field or a value the row does not offer with its own sentence (`UNKNOWN_FIELD_MSG`, `BAD_VALUE_MSG`). Every accepted change persists (`ConfigFlow` → `persist_config`). `toggle_pencil_mode` stays its own command: it is not Config.
- **`config.json`** holds `{"config": {…}, "current_file": …}`, written and read generically by walking the table. Every read — the file, the host config, `POST /config.json`, CLI `-d`/`-v` — goes through the table's check. `renderers` (preferred, fallback) is CLI-only and never saved. Startup stays defaults → `config.json` → CLI overrides → save.
- **The wire uses the file's format:** bools, choices by name (`"easy"`, `"info"`, `"dark"`) for `getConfig`, the host config, `bootstrapHostConfig`, `persist_config` and generation requests.
- **The facade** takes `Config` as one value per call (`getCommandInput(names, cfg)`); the terminal renderer imports the table for labels and choices. It still holds no pointer to core state.

## Consequences

- Adding a field touches only `Config` and the table in production code; tests that spell out the whole config JSON list it too. Test builds prove it with `Config.test_probe` (a `bool` under `builtin.is_test`, `void` and unsaved otherwise): it is listed in the terminal's Settings, set by `set_config`, written to `config.json` and read back, and crosses the wire in the table and config JSON. The web dialog is generic over the table; its test adds a row and gets the control and the action with no web change.
- In the app `Config` still has a `test_probe: void` field; every walk over Config's fields goes through `Config.isSaved` or the table, which skip it.
- Front ends keep no field lists or labels of their own; a front end that needs a field's words reads the table.
- Field names a front end places by hand (View items, Auto Save) are named once per front end (`settings.js` constants).
- Native Settings numbering follows the table's row order.

## References

- `src/core/config.zig`, `src/core/config_table.zig`, `src/core/config_store.zig`, `src/core/flow/config.zig`, `src/core/flow/command.zig`
- `src/native/ascii/renderer.zig` (Settings menu), `src/core/renderer/facade.zig`
- `src/wasm/boundary.zig` (`writeConfigTableJson`, `writeConfigJson`, `parseAction` `set_config`), `src/entry_wasm.zig` (`getConfigTable`)
- `src/wasm/menus/settings.js` (generated dialog, `setConfigAction`, `toggleConfigAction`), `src/wasm/menus/menu_bar.js` (labels from the table)
