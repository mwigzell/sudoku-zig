# Zig Testing Guide (0.17)

Zig **0.17** does not throw away the testing model. The `test` block idiom is still the core design. What changed in recent versions is mostly **how tests interact with std APIs** (especially I/O) and **how `build.zig` wires tests up**.

## Short answer

| Question | Answer |
|---|---|
| Is testing broken? | **No** — `test` blocks, `std.testing`, and `zig test` still work |
| Do you need to update? | **Maybe** — if you use `build.zig` test filtering, `b.args`, or pre-0.16 std APIs in tests |
| What is the idiom? | Colocated `test` blocks + `std.testing` + import-graph discovery |

---

## The Zig idiom (still correct in 0.17)

### 1. Colocate tests with the code they exercise

This matches the stdlib: tests live in the same `.zig` file as the implementation, not in a separate `tests/` tree (though that is allowed if you import the file).

```zig
pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "addition" {
    try std.testing.expectEqual(@as(i32, 5), add(2, 3));
}
```

### 2. Use `std.testing` and always `try` assertions

Assertions return errors. Missing `try` is a compile error.

```zig
const std = @import("std");
const testing = std.testing;

test "equality" {
    try testing.expectEqual(@as(u32, 42), 40 + 2);
    try testing.expectEqualStrings("hello", "hello");
    try testing.expectError(error.OutOfMemory, failingCall());
}
```

### 3. Discovery is via the import graph

`zig test src/root.zig` runs tests in `root.zig` **and every file it imports**. Tests in `tests/foo.zig` are invisible unless something imports that file.

### 4. Use the test harness globals

| Global | Purpose |
|---|---|
| `std.testing.allocator` | Leak/double-free detection (test builds only) |
| `std.testing.io` | I/O, timing, concurrency, randomness in tests |
| `std.testing.random_seed` | Deterministic randomness |

```zig
test "file read" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var file = try io.openFileAbsolute("foo.txt", .{});
    defer file.close(io);

    const contents = try file.readToEndAlloc(gpa, std.math.maxInt(usize));
    defer gpa.free(contents);
    // ...
}
```

`std.testing.io` landed in **0.16** and remains the idiomatic approach in **0.17**. It replaces ad-hoc `std.Io.Threaded.init_single_threaded` setup in tests.

### 5. Named vs unnamed tests

```zig
test { /* always runs, even with --test-filter */ }

test "edge case: empty input" { /* filterable by name */ }

test add { /* doctest — documents `add` */ }
```

### 6. `build.zig` for project-level test runs

```zig
const unit_tests = b.addTest(.{
    .root_module = my_module, // or .root_source_file = b.path("src/root.zig")
    .target = target,
    .optimize = optimize,
});

const run_tests = b.addRunArtifact(unit_tests);
const test_step = b.step("test", "Run unit tests");
test_step.dependOn(&run_tests.step);
```

---

## What actually changed around 0.17

### Testing itself: mostly stable

The `test` keyword, `std.testing` assertions, comptime tests, and `zig test` are unchanged. Testing is not broken as a language feature.

### 0.16 migration (still relevant if you are upgrading)

If you are coming from **0.15 or earlier**, tests are where many breakages show up, because std now threads an `Io` handle through I/O:

- `std.fs.*` → `std.Io.Dir` / `std.Io.File` + `io` parameter
- `std.time.Timer` → `std.Io.Timestamp` / `io.sleep`
- `std.Thread.Pool` → `Io.async` / `Io.Group`
- `std.crypto.random` → `io.random(&buf)`

Pattern: pass `std.testing.io` into anything under test that touches I/O.

### 0.17: build system, not test syntax

0.17's big change is the **configure/maker split** in the build system. That affects how you *run* tests from `build.zig`, not how you write `test` blocks.

**Broken in 0.17:**

```zig
// OLD — b.args is gone in configure phase
const unit_tests = b.addTest(.{
    .root_source_file = b.path("src/root.zig"),
    .filters = b.args orelse &.{},
});
```

**0.17 idiom:**

```zig
const test_filters = b.option(
    []const []const u8,
    "test-filter",
    "Skip tests that do not match any filter",
) orelse &.{};

const unit_tests = b.addTest(.{
    .root_module = my_module,
    .filters = test_filters,
    .target = target,
    .optimize = optimize,
});
```

Then:

```bash
zig build test -Dtest-filter=my_test_name
```

Other common `build.zig` fixes:

- `if (b.args) |args| run_cmd.addArgs(args)` → `run_cmd.addPassthruArgs()`
- `b.getInstallPath()` → `b.graph.path(.install_prefix, ...)`
- Prefer `.root_module` over bare `.root_source_file` where modules are shared

Direct `zig test foo.zig --test-filter foo` still works outside the build system.

---

## Recommended test structure

```
src/
  root.zig          ← library root, re-exports modules
  math.zig          ← impl + test blocks together
  parser.zig        ← impl + test blocks together
build.zig           ← `zig build test` step
```

**Do:**

- One logical concern per `test "..."` block
- `std.testing.allocator` for anything that allocates
- `std.testing.io` for anything that does I/O, sleeps, or spawns tasks
- `refAllDecls(@This())` in a root test if you need private decls exercised:

```zig
test {
    std.testing.refAllDecls(@This());
}
```

**Avoid:**

- Orphan test files not imported from a root
- Using `std.heap.page_allocator` in tests when `testing.allocator` catches leaks
- Spinning up your own `Io.Threaded` in every test when `std.testing.io` exists
- Relying on `b.args` for test filtering in 0.17

---

## Do you need to update?

| Your situation | Action |
|---|---|
| Simple `test` blocks, no I/O, `zig test` directly | Probably fine as-is |
| Tests using `std.fs`, timers, threads, process spawn | Update to pass `std.testing.io` (0.16+) |
| `build.zig` uses `b.args` for test filters or run args | Update for 0.17 (`b.option` + `.filters`, `addPassthruArgs`) |
| Still on 0.15 APIs (`usingnamespace`, old `ArrayList`, etc.) | Full 0.16 migration first, then 0.17 build tweaks |

0.17.0 is primarily a build-system release. The testing *language* is stable; the migration pain is in **stdlib I/O (0.16)** and **build.zig wiring (0.17)**.

---

## References

- [Zig Test documentation](https://zig.anydocs.dev/test/)
- [0.16.0 Release Notes](https://ziglang.org/download/0.16.0/release-notes.html) — `std.testing.io` and `Io` migration
- [Zig Devlog 2026](https://ziglang.org/devlog/2026/) — 0.17 build system rework
