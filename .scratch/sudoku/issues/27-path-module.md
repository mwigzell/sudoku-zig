## Parent
`.scratch/sudoku/issues/25-save-restore.md` (Step 11 dependency)

## What to build

New module `src/path.zig` with OS-aware data directory resolution, replacing ad-hoc path handling in `handleResult()` with proper platform-convention paths.

### Module surface (`path.zig`)

```zig
fn getHomeDir(gpa: std.mem.Allocator) anyerror![]u8 { ... }
pub fn getDataDir(gpa: std.mem.Allocator, io: std.Io) anyerror![]u8 { ... }
pub fn resolveSavePath(gpa: std.mem.Allocator, data_dir: []const u8, path: []const u8) anyerror![]u8 { ... }
```

## Proposed fix

### `getHomeDir()` — Linux (now), compile_error elsewhere

```zig
fn getHomeDir(gpa: std.mem.Allocator) anyerror![]u8 {
    const env = std.c.environ;
    for (env, 0..) |pair, i| {
        if (pair == undefined) return error.EnvironmentVariableMissing;
        const prefix = "HOME=";
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (eq == prefix.len and std.mem.eql(u8, pair[0..eq], "HOME")) {
            return gpa.dupe(u8, std.mem.sliceTo(pair[eq + 1..], 0));
        }
    }
    return error.EnvironmentVariableMissing;
}
```

- Uses `std.c.environ` directly — same global envp Zig reads from on Linux (`std/start.zig`).
- Walks null-terminated array, finds HOME= prefix with `mem.indexOfScalar`, extracts value with `mem.sliceTo()`.
- **Corrected 2026-08-04:** Original `Environ{ .use_global }` approach doesn't compile on Linux — `Environ.Block` is `PosixBlock` (no `.use_global`) there.
- Caller owns returned memory via `gpa`. Memory freed via errdefer at call site.
- Propagates `error.EnvironmentVariableMissing` if HOME unset.

### `getDataDir()` — mkdir -p + return path

```zig
pub fn getDataDir(gpa: std.mem.Allocator, io: std.Io) anyerror![]u8 {\n    const home = try getHomeDir(gpa);
    errdefer gpa.free(home);\n\n    const data_dir = try std.fmt.allocPrint(gpa, "{s}/.local/share/sudoku", .{home});

    // Ensure the directory tree exists (mkdir -p equivalent)\n    const cwd = try std.Io.Dir.cwd();\n    _ = cwd.createDirPath(io, data_dir) catch {};
\n    return data_dir;
```

**Note:** `std.Io.Dir.createDirPath(io, sub_path)` is `mkdir -p` on 0.17. We silently ignore errors — save/open themselves will fail with real errors if the directory truly can't be accessed.

### Platform TODOs (future issues needed)

| OS | getHomeDir source | getDataDir convention | Status |
|----|-------------------|----------------------|--------|
| Linux | `$HOME` env var | `~/.local/share/sudoku/` | ✅ Implement now |
| macOS | `$HOME` env var | `~/Library/Application Support/sudoku/` | ❌ compile_error, future issue needed |
| Windows | `%USERPROFILE%` or SHGetKnownFolderPath | `%LOCALAPPDATA%/sudoku/` | ❌ compile_error, future issue needed — getAlloc won't work on Windows (WTF-16) |

### Integration points

```zig
.save => {
    const data_dir = try mypath.getDataDir(gpa, io);
    errdefer gpa.free(data_dir);
    const resolved = try mypath.resolveSavePath(gpa, data_dir, DEFAULT_SAVE_FILE);
    errdefer gpa.free(resolved);
    self.engine.saveGame(io, resolved) catch |err| { ... };
},
.open => |o_data| {
    const data_dir = try mypath.getDataDir(gpa, io);
    errdefer gpa.free(data_dir);
    const resolved = try mypath.resolveSavePath(gpa, data_dir, o_data.path);
    errdefer gpa.free(resolved);
    self.engine.openGame(io, resolved) catch |err| { ... };
},
```

**Requires:** `gpa` at the call site. Use `std.heap.page_allocator` for short-lived path strings — allocations are tiny (~50-100 bytes), freed immediately via errdefer. Decision made 2026-08-04: no need to thread through init() or add struct field.

### Files involved

| File | Change |
|------|--------|
| `src/path.zig` | **New** — getHomeDir(), getDataDir(), resolveSavePath() |
| `src/sudoku.zig` | Import path.zig; wire into handleResult .save/.open blocks |
| `src/root.zig` | Add test discovery for path.zig |

## Steps (vertical slice)

| Step | Description |
|------|-------------|
| 1 | Create `src/path.zig` with `getHomeDir()` — Linux only, compile_error otherwise |
| 2 | Add `getDataDir()` — allocates `~/.local/share/sudoku/`, creates dir if missing via createDirPath |
| 3 | Add `resolveSavePath()` — takes `(gpa, data_dir, path)`; joins relative path against data dir; passes absolute (`path[0] == '/'`) through via dupe as owned copy |
| 4 | Wire into `sudoku.zig` handleResult for both .save and .open |
| 5 | Tests: getHomeDir returns HOME, getDataDir creates directory, resolveSavePath handles both cases |

## Acceptance Criteria

- [ ] `getHomeDir()` returns `$HOME` on Linux, compile_error on other OSes
- [ ] `getDataDir(gpa, io)` returns `~/.local/share/sudoku/` and ensures the directory exists
- [ ] `resolveSavePath(gpa, data_dir, "game.sud")` → absolute path under data dir
- [ ] `resolveSavePath(gpa, data_dir, "/abs/path.sud")` → `/abs/path.sud` passthrough (returns owned copy)
- [ ] No memory leaks — errdefer discipline on all allocs
