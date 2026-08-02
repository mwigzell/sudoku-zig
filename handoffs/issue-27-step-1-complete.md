# Handoff: Issue 27 (path.zig module) — Step 1 complete, Step 2 next

## Current state

**Date:** 2026-08-04  
**Issue:** #27 path.zig module for OS-aware data directory resolution  
**Parent:** Issue #25 Step 11 (dependency — open crashes on relative paths)  

**Completed:**
- `src/path.zig` created with `getHomeDir()` function using `std.c.environ`
- Test passes: `zig test src/path.zig -lc` → 1/1 pass  
- Committed at `04a26f2 feat(27): step 1 — create path.zig with getHomeDir()`

**Not yet in root.zig test discovery:** `std.c.environ` requires `-lc` linkage. Zig 0.17's build system addTest doesn't expose LinkLibC. Will be addressed at Step 4 (wire into exe module which links libc natively).

## Next: Step 2 — getDataDir()

Add `getDataDir(gpa, io)` to path.zig that:
- Calls getHomeDir(), formats "{home}/.local/share/sudoku/"
- Creates directory tree with cwd.createDirPath(io, data_dir) [catch {}]  
- Returns allocated string on stack (caller frees)

## Open questions resolved in previous sessions

### Environ approach - why not use std.c.environ directly?
The original spec used `Environ{ .use_global }` which doesn't compile on Linux because `Environ.Block` is `PosixBlock` there. We switched to walking the null-terminated array manually — same global Zig reads from (`std/start.zig`) but without requiring libc linkage in test runner.

### Absolute path detection
`path[0] == '/'` is sufficient for Linux absolute path detection — no need for heavier checks.

## Implementation pattern established
```zig
pub fn c = struct {
    pub extern var environ: [*:null]?[*:0]u8;
};
// Walk until null, sliceTo on '=' separator, verify "HOME" prefix, dupe value
```

## Suggested skills
- `tdd` — test-first approach with red/green cycle  