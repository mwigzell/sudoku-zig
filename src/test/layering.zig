// Test-only gate: no file-scope `@import` under `src/core/` may reach the platform adapters.
//
// Core is one portable implementation every front end compiles; `src/native/` is the desktop
// adapter (entry, terminal renderer, shell). A test that needs a native helper imports it inside
// its own `test { … }` block, where nothing reaches production code.
const std = @import("std");

/// Directory the gate reads, and the one no import in it may reach into (both repo-relative).
const CORE_DIR = "src/core";
const NATIVE_DIR = "src/native";

/// A file-scope import that reaches the native adapters.
const Found = struct {
    /// 1-based line the `@import` sits on.
    line: usize,
    /// The import's path text as written, without its quotes.
    import_path: []const u8,
};

/// Fold `import_path` against `base_dir` into a normalised repo-relative path, `.` and `..` resolved.
fn resolveImportPath(gpa: std.mem.Allocator, base_dir: []const u8, import_path: []const u8) ![]u8 {
    const joined = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base_dir, import_path });
    defer gpa.free(joined);

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, joined, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            // A `..` that climbs out of the repo root is kept: it cannot name a core module.
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) _ = parts.pop();
            continue;
        }
        try parts.append(gpa, part);
    }
    return std.mem.join(gpa, "/", parts.items);
}

/// True when a repo-relative path sits inside the native adapters (`src/native/…`, not `src/native_x`).
fn reachesNative(resolved: []const u8) bool {
    if (!std.mem.startsWith(u8, resolved, NATIVE_DIR)) return false;
    return resolved.len == NATIVE_DIR.len or resolved[NATIVE_DIR.len] == '/';
}

/// The first file-scope `@import` in `source` that reaches the native adapters, or null.
/// `base_dir` is the repo-relative directory the file sits in, so an import's target can be resolved.
///
/// Tokenizing rather than matching lines is what keeps the two exemptions honest: a comment is
/// never a token, and a `test { … }` block is tracked by brace depth so its imports are skipped.
fn findNativeImport(gpa: std.mem.Allocator, source: [:0]const u8, base_dir: []const u8) !?Found {
    var tokenizer: std.zig.Tokenizer = .init(source);
    var depth: usize = 0; // `{` nesting: a file-scope declaration sits at 0
    var test_at: ?usize = null; // brace depth of the `test { … }` block we are inside
    var test_body_follows = false; // saw `test` at file scope; the next `{` opens its block

    while (true) {
        const token = tokenizer.next();
        const text = source[token.loc.start..token.loc.end];
        switch (token.tag) {
            .eof => return null,
            .l_brace => {
                depth += 1;
                if (test_body_follows) {
                    test_at = depth;
                    test_body_follows = false;
                }
            },
            .r_brace => {
                if (test_at) |block_depth| {
                    if (depth == block_depth) test_at = null;
                }
                depth -= 1;
            },
            .keyword_test => if (depth == 0) {
                test_body_follows = true;
            },
            .builtin => {
                if (test_at != null or !std.mem.eql(u8, text, "@import")) continue;
                // `@import` takes one string literal; anything else is not a path this gate reads.
                if (tokenizer.next().tag != .l_paren) continue;
                const argument = tokenizer.next();
                if (argument.tag != .string_literal) continue;
                const quoted = source[argument.loc.start..argument.loc.end];
                const import_path = quoted[1 .. quoted.len - 1];
                const resolved = try resolveImportPath(gpa, base_dir, import_path);
                defer gpa.free(resolved);
                if (!reachesNative(resolved)) continue;
                return .{ .line = std.mem.count(u8, source[0..token.loc.start], "\n") + 1, .import_path = import_path };
            },
            else => {},
        }
    }
}

test "a file-scope core import into the native adapters is a violation" {
    const source =
        \\const std = @import("std");
        \\const path = @import("../native/shell/path.zig");
        \\const config = @import("config.zig");
    ;
    const found = (try findNativeImport(std.testing.allocator, source, "src/core")).?;
    try std.testing.expectEqual(@as(usize, 2), found.line);
    try std.testing.expectEqualStrings("../native/shell/path.zig", found.import_path);
}

test "an import inside a test block or a comment is not a file-scope import" {
    const source =
        \\// const path = @import("../native/shell/path.zig");
        \\const std = @import("std");
        \\const help = @import("../../native_tools/help.zig");
        \\
        \\test "a native helper stays inside the test" {
        \\    const disambiguate = @import("../native/ascii/disambiguate.zig");
        \\    _ = disambiguate;
        \\}
    ;
    try std.testing.expect(try findNativeImport(std.testing.allocator, source, "src/core") == null);
}

test "no file-scope import under src/core reaches the native adapters" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var core_dir = try std.Io.Dir.cwd().openDir(io, CORE_DIR, .{ .iterate = true });
    defer core_dir.close(io);
    var walker = try core_dir.walk(gpa);
    defer walker.deinit();

    var files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        files += 1;

        const source = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(source);
        const base_dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ CORE_DIR, std.fs.path.dirname(entry.path) orelse "." });
        defer gpa.free(base_dir);

        const found = (try findNativeImport(gpa, source, base_dir)) orelse continue;
        const file = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ CORE_DIR, entry.path });
        defer gpa.free(file);
        std.debug.print("core imports a platform adapter: {s}:{d} @import(\"{s}\")\n", .{ file, found.line, found.import_path });
        return error.TestNativeImportUnderCore;
    }
    // A gate that walked nothing would pass silently; core always has sources.
    try std.testing.expect(files > 0);
}
