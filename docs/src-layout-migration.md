# Source Layout Migration Map (#73)

This map records the role-based source relocation for issue #73.

## Final role layout

- `src/core/` — domain and policy modules
- `src/test/fixtures/` — fixture assets
- `src/` root — process/platform entry files (`entry_native.zig`, `entry_wasm.zig`, `entry_android.zig`) and slow test entry (`entry_verify_slow.zig`)

## Migration table (old -> new)

- `src/about.zig` -> `src/core/about.zig`
- `src/command.zig` -> `src/core/command.zig`
- `src/config.zig` -> `src/core/config.zig`
- `src/event.zig` -> `src/core/event.zig`
- `src/file_policy.zig` -> `src/core/file_policy.zig`
- `src/logger.zig` -> `src/core/logger.zig`
- `src/save_defaults.zig` -> `src/core/save_defaults.zig`
- `src/settings_store.zig` -> `src/core/settings_store.zig`
- `src/solver.zig` -> `src/core/solver.zig`
- `src/version.zig` -> `src/core/version.zig`
- `src/board/*` -> `src/core/board/*`
- `src/engine/*` -> `src/core/engine/*`
- `src/puzzle_gen/*` -> `src/core/puzzle_gen/*`
- `src/renderer/*` -> `src/core/renderer/*`
- `src/startup/*` -> `src/core/startup/*`
- `src/entry_verify_slow.zig` is the canonical `verify-slow` entry module; slow suites live under `src/test/slow/`
