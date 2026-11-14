# ADR-0021 — A startup Config read refuses anything but a missing file

Status: accepted
Date: 2026-11-14
Related: ADR-0014 (settings file), ADR-0020 (`config.json` and the config table)

## Context

`config_store.loadOrDefault` and `loadOrDefaultInDir` returned `Config.default()` for **every** failure: a file that could not be read, one that did not parse, and one holding a value the config table rejects all looked like a first start with no file. The module's `Error` set advertised five members (`OutOfMemory`, `InvalidJson`, `UnsupportedValue`, `WriteFailed`, `System`), while the read path could produce one of them — `OutOfMemory` from `configPath`. So every caller's error branch was written, compiled, and never exercised: `setCurrentFile`'s `try`, the Android host's `catch`, and the desktop entry's `catch unreachable` were all dead for a bad file.

Nothing in the repo stated what the read *ought* to do, so the tests could not either: `config_store.zig` asserts "a bad value, a non-object config or unparsable bytes load the defaults", which is a snapshot of the implementation's choice rather than a check on it. Any change to the choice would have been written into the same commit as its test, and the two would agree again.

The write path already refused: `writeFailed` logs the reason and returns `Error.System`.

## Decision

The rule is decided once, in core, and every front end only renders its outcome.

1. **File missing** (`error.FileNotFound`) → `Config.default()`, one info line (`expected: … yet`), startup proceeds. A first start is normal.
2. **File present but unreadable, unparseable, or holding a value the table rejects** → one log line carrying `@errorName`, then `Error.System`. Startup does not proceed.
3. **Write failure** is unchanged: `writeFailed` logs its one line and returns `Error.System`; startup does not proceed.
4. **The reason is logged, the return collapses.** Every failing read branch logs the system name it caught and returns `Error.System`, the way `writeFailed` and `game_engine`'s open arms already do. A caller that needs the distinction reads the log line; no arm re-words it.
5. **The rule covers every read of `config.json`**, which makes `setCurrentFile`'s read strict too: it reads the Config it must preserve, so a file it cannot read is refused rather than quietly repaired. The read inside `save` / `saveInDir` stays lenient — it holds the Config already and may repair the file it is about to rewrite.
6. **A test asserts the rule, not the implementation.** Each case in the decision above gets a test that would fail if the code took the other reading. A test that both readings satisfy is not evidence and must not be cited as such.

## Consequences

- One behaviour for a bad file on every arm: it is refused, with its reason in the log, instead of being replaced by defaults.
- A first start never stops: only a file that exists and cannot be used refuses.
- The failure channel of `Error` is now used, so the callers that already handled it are reached: the `-r web` host's pointer write refuses instead of repairing a corrupt file, and the Android host keeps defaulting while logging one warn line (its own arm is a separate slice).
- The desktop entry's `catch unreachable` on this seam was already reachable through `save` before this decision and must become a `try`; that defect is its own change, not this rule's. It is now a `try`: the seam declares `error{System}`, which `main` already carries, so a refused startup exits 1 with core's line on stderr instead of trapping.
- `config.json` keeps its shape and `current_file` its meaning, so an older app still reads it.
- Front ends gain no text: core owns the log lines, and any player-facing sentence for a refused startup is core's to write when a front end needs one.

## References

- `src/core/config_store.zig` (`loadOrDefault`, `loadOrDefaultInDir`, `loadBytes`, `parseFile`, `configPath`, `saveInDir`, `setCurrentFile`)
- `src/core/startup/config.zig` (`resolveStartupConfig`)
- `src/android/jni_host.zig`, `src/web_host/mod.zig` (`setCurrentFile`, `loadCurrentFile` callers)
- `src/entry_native.zig` (`main`'s read of the seam)
