//! The Android device gate: one instrumented run for a named method set, recorded as evidence.
//!
//! The device suite is the only proof an Android-only change works, and `zig build verify` cannot
//! reach it. This gate runs the methods a branch must prove and writes a JSON record naming what was
//! required, what ran, the commit and the outcome — the record a reader checks before accepting the
//! branch. A dirty worktree and a missing device are refusals, never skips: evidence from uncommitted
//! code, or from a run that did not happen, proves nothing. The process runner and the clock are
//! injected, so the unit suite proves the record without a device.

const std = @import("std");

/// One `FileBridgeTest` method the run must prove, and why this branch needs it.
pub const Method = struct {
    /// JUnit method name, as `src/android/test/FileBridgeTest.java` declares it.
    method: []const u8,
    /// What proving it answers for this branch, so the record explains its own requirement.
    why: []const u8,
};

/// What a device run can prove.
pub const Result = enum { passed, failed };

/// The record one device run leaves behind. These field names are the JSON keys `accept` and the
/// archive read, so they are a contract rather than an implementation detail.
pub const Evidence = struct {
    /// The issue whose branch required the run; absent for a run outside an issue.
    issue: ?u32 = null,
    /// The methods this branch must prove, each with the reason it is required.
    required: []const Method,
    /// The methods the instrumented run executed.
    methods: []const []const u8,
    /// The command the run made, so a reader can repeat it.
    command: []const u8,
    /// Whether the run passed.
    result: Result,
    /// The `adb` serial of the one device the run proved itself on.
    device: []const u8,
    /// Wall-clock seconds the instrumented run took.
    duration_s: u64,
    /// The commit the run proved; a record naming another commit proves nothing.
    commit: []const u8,
    /// Whether the worktree was clean, as the run required.
    clean_tree: bool,
    /// When the record was written, UTC ISO 8601.
    at: []const u8,
};

/// What a child process produced.
pub const Outcome = struct {
    /// Whether the process exited zero.
    ok: bool,
    /// Captured stdout when the caller asked for it; owned by the caller's allocator.
    stdout: []u8,
};

/// Runs one command: production spawns it, tests answer from a table.
pub const RunFn = *const fn (ctx: ?*anyopaque, io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, capture: bool) Outcome;

/// Epoch seconds from the wall clock: production reads the system clock, tests freeze it.
pub const NowFn = *const fn (ctx: ?*anyopaque, io: std.Io) u64;

/// What the gate takes from the machine it runs on, so a unit test can stand in for it.
pub const Deps = struct {
    /// Handed to `run` and `now` unchanged; null on the real machine.
    ctx: ?*anyopaque = null,
    /// The child-process runner.
    run: RunFn,
    /// The wall clock.
    now: NowFn,
};

/// Everything one gate run is told: where the Android tooling is, what it must prove, where the
/// record goes.
pub const Request = struct {
    /// The methods this run must prove, in the order the caller named them.
    required: []const Method,
    /// Path of the evidence JSON this run writes.
    evidence_path: []const u8,
    /// Android SDK root.
    sdk_root: []const u8,
    /// API level the app APK targets.
    api_level: u32,
    /// The built app APK the device run installs.
    app_apk: []const u8,
    /// The test run's scratch directory.
    out_dir: []const u8,
    /// The test APK's manifest.
    manifest: []const u8,
    /// The test source the scenarios live in.
    java_source: []const u8,
    /// The issue whose branch required the run.
    issue: ?u32 = null,
    /// The serial `ANDROID_SERIAL` named, when the caller set it; null means the one attached device.
    device: ?[]const u8 = null,
};

/// Why a gate run stopped. `runGate` reports each on stderr, so a caller only has to exit non-zero.
pub const Error = error{
    /// `git status --porcelain` reported changes, so the code under test is not the code committed.
    DirtyWorktree,
    /// No device is attached; the run is never skipped for want of one.
    NoDevice,
    /// More than one device is attached and none is named, so the record could not say which one was proved.
    ManyDevices,
    /// The branch commit could not be read, so the record could not name it.
    UnknownCommit,
    /// The instrumented run failed; the failed record is written all the same.
    TestsFailed,
    /// The record could not be written.
    WriteFailed,
    /// A string this run had to build did not fit in memory.
    OutOfMemory,
};
/// Where the run's lines go: stderr on the real machine, a fixed buffer in a test, so a refusal's
/// wording is checked rather than its absence.
var report_sink: ?*std.Io.Writer = null;

/// One line about what the run refused or did, prefixed with the tool the reader invoked. A sink
/// too small for the line still reaches stderr, so no line is dropped in silence.
fn report(comptime fmt: []const u8, args: anytype) void {
    if (report_sink) |sink| {
        sink.print("android-gate: " ++ fmt ++ "\n", args) catch {
            std.debug.print("android-gate: " ++ fmt ++ "\n", args);
        };
        return;
    }
    std.debug.print("android-gate: " ++ fmt ++ "\n", args);
}

/// The gate's one instrumented run for a named method set, recorded as evidence.
///
/// Refuses before running when the worktree holds uncommitted changes (the code under test would not
/// be the code a reader can check) or when there is no device to prove the run (a run that did not
/// happen proves nothing). A failed run still writes its record, marked `failed`, because a refusal
/// a reader cannot see is worse than a red one.
pub fn runGate(io: std.Io, gpa: std.mem.Allocator, request: Request, deps: Deps) Error!void {
    return gateRun(io, gpa, request, deps) catch |err| {
        // Every refusal names its reason where it refuses; an allocation failure is the one with no
        // line behind it, so the run supplies that line rather than exiting on a bare status.
        if (err == Error.OutOfMemory) report("the run stopped, out of memory: {s}", .{@errorName(err)});
        return err;
    };
}

/// What `runGate` does once it has a line for the one failure it cannot name itself.
fn gateRun(io: std.Io, gpa: std.mem.Allocator, request: Request, deps: Deps) Error!void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    try requireCleanTree(io, a, deps);
    const commit = try readCommit(io, a, deps);
    const device = try selectDevice(io, a, deps, request.device);

    const methods = try methodNames(a, request.required);
    const csv = try std.mem.join(a, ",", methods);
    const argv = try testArgv(a, request, csv);
    const command = try std.mem.join(a, " ", argv);

    const started = deps.now(deps.ctx, io);
    const outcome = deps.run(deps.ctx, io, a, argv, false);
    const finished = deps.now(deps.ctx, io);

    const evidence = Evidence{
        .issue = request.issue,
        .required = request.required,
        .methods = methods,
        .command = command,
        .result = if (outcome.ok) .passed else .failed,
        .device = device,
        .duration_s = finished -| started,
        .commit = commit,
        .clean_tree = true,
        .at = try isoUtc(a, finished),
    };
    try writeEvidence(io, a, request.evidence_path, evidence);

    if (!outcome.ok) {
        report("the device run failed ({d} method(s) on {s}); the failed record is in {s}", .{ methods.len, device, request.evidence_path });
        return Error.TestsFailed;
    }
    report("{d} method(s) passed on {s} in {d}s; record in {s}", .{ methods.len, device, evidence.duration_s, request.evidence_path });
}

/// Refuse before running: evidence from uncommitted code proves nothing.
fn requireCleanTree(io: std.Io, a: std.mem.Allocator, deps: Deps) Error!void {
    const status = readStdout(io, a, deps, &.{ "git", "status", "--porcelain" }) orelse {
        report("git status --porcelain could not be read, so a clean worktree cannot be shown; commit the work first", .{});
        return Error.DirtyWorktree;
    };
    if (std.mem.trim(u8, status, " \t\r\n").len == 0) return;
    report("refusing a dirty worktree — evidence from uncommitted code proves nothing:\n{s}", .{status});
    return Error.DirtyWorktree;
}

/// The branch tip the run proves, or a refusal: a record that cannot name its commit proves nothing.
fn readCommit(io: std.Io, a: std.mem.Allocator, deps: Deps) Error![]const u8 {
    const raw = readStdout(io, a, deps, &.{ "git", "rev-parse", "HEAD" }) orelse {
        report("the branch commit could not be read (git rev-parse HEAD)", .{});
        return Error.UnknownCommit;
    };
    const commit = std.mem.trim(u8, raw, " \t\r\n");
    if (commit.len == 0) {
        report("git rev-parse HEAD named no commit", .{});
        return Error.UnknownCommit;
    }
    return commit;
}

/// The device that proves the run: the serial `ANDROID_SERIAL` named, else the only attached device.
/// A missing device, a named one that is not attached, or a crowded list with none named is refused
/// with the instruction that fixes it — a run that did not happen proves nothing.
fn selectDevice(io: std.Io, a: std.mem.Allocator, deps: Deps, requested: ?[]const u8) Error![]const u8 {
    const listed = readStdout(io, a, deps, &.{ "adb", "devices" }) orelse {
        report("adb devices could not be read — is platform-tools on PATH? start a device with {s}", .{START_SCRIPT});
        return Error.NoDevice;
    };
    if (requested) |serial| {
        if (serial.len > 0) {
            if (!listsDevice(listed, serial)) {
                report("ANDROID_SERIAL names {s}, which adb devices does not list as connected; start it with {s}", .{ serial, START_SCRIPT });
                return Error.NoDevice;
            }
            return serial;
        }
    }
    const found = parseDevices(listed);
    if (found.count == 0) {
        report("no device attached — start one with {s}; this run is never skipped", .{START_SCRIPT});
        return Error.NoDevice;
    }
    if (found.count > 1) {
        report("{d} devices attached — set ANDROID_SERIAL to the one that proves the run", .{found.count});
        return Error.ManyDevices;
    }
    return found.first;
}

/// Whether `adb devices` output lists `serial` as connected.
fn listsDevice(listed: []const u8, serial: []const u8) bool {
    var lines = std.mem.splitScalar(u8, listed, '\n');
    _ = lines.next(); // the "List of devices attached" header
    while (lines.next()) |line| {
        const found = connectedSerial(line) orelse continue;
        if (std.mem.eql(u8, found, serial)) return true;
    }
    return false;
}

/// Run one command and hand back its stdout; `null` when the command could not be read. The arena
/// owns the bytes, so the caller never frees them.
fn readStdout(io: std.Io, a: std.mem.Allocator, deps: Deps, argv: []const []const u8) ?[]const u8 {
    const outcome = deps.run(deps.ctx, io, a, argv, true);
    if (!outcome.ok) return null;
    return outcome.stdout;
}

/// The devices `adb devices` lists, as the gate needs them: how many are connected, and the first.
const Devices = struct {
    /// Serial of the first connected device, empty when none is connected.
    first: []const u8 = "",
    /// How many devices are in the `device` state.
    count: usize = 0,
};

/// The serial on one `adb devices` line when its state is `device`, else null. An `offline` or
/// `unauthorized` device is attached but unusable, so it is not a device the run can use.
fn connectedSerial(line: []const u8) ?[]const u8 {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    const serial = fields.next() orelse return null;
    const state = fields.next() orelse return null;
    if (!std.mem.eql(u8, state, DEVICE_STATE)) return null;
    return serial;
}

/// Read `adb devices` output: every line after the header whose state is `device`.
fn parseDevices(text: []const u8) Devices {
    var found: Devices = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    _ = lines.next(); // the "List of devices attached" header
    while (lines.next()) |line| {
        const serial = connectedSerial(line) orelse continue;
        found.count += 1;
        if (found.count == 1) found.first = serial;
    }
    return found;
}

/// The method names, in the order the caller named them.
fn methodNames(a: std.mem.Allocator, required: []const Method) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (required) |entry| try names.append(a, entry.method);
    return names.items;
}

/// The argument list `scripts/android-test.sh` takes, with the methods as one comma-separated value
/// it splits into a single `-e class` list.
fn testArgv(a: std.mem.Allocator, request: Request, methods_csv: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(a, "bash");
    try argv.append(a, TEST_SCRIPT);
    try argv.append(a, request.sdk_root);
    try argv.append(a, try std.fmt.allocPrint(a, "{d}", .{request.api_level}));
    try argv.append(a, request.app_apk);
    try argv.append(a, request.out_dir);
    try argv.append(a, request.manifest);
    try argv.append(a, request.java_source);
    try argv.append(a, methods_csv);
    return argv.items;
}

/// Write the record as one JSON object with a trailing newline, so a reader parses a whole file.
fn writeEvidence(io: std.Io, a: std.mem.Allocator, path: []const u8, evidence: Evidence) Error!void {
    var aw = std.Io.Writer.Allocating.init(a);
    defer aw.deinit();
    var s: std.json.Stringify = .{ .writer = &aw.writer };
    try writeEvidenceObject(&s, evidence);
    try aw.writer.writeAll("\n");
    std.Io.Dir.writeFile(std.Io.Dir.cwd(), io, .{
        .sub_path = path,
        .data = aw.written(),
        .flags = .{ .truncate = true },
    }) catch |err| {
        report("the record for {s} could not be written: {s}", .{ path, @errorName(err) });
        return Error.WriteFailed;
    };
}

/// One member per field, in the order a reader opens them; `issue` is written only when the run
/// belongs to one, so an unattached run carries no invented number.
fn writeEvidenceObject(s: *std.json.Stringify, evidence: Evidence) std.json.Stringify.Error!void {
    try s.beginObject();
    if (evidence.issue) |issue| {
        try s.objectField("issue");
        try s.write(issue);
    }
    try s.objectField("required");
    try s.beginArray();
    for (evidence.required) |entry| {
        try s.beginObject();
        try s.objectField("method");
        try s.write(entry.method);
        try s.objectField("why");
        try s.write(entry.why);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("methods");
    try s.beginArray();
    for (evidence.methods) |method| try s.write(method);
    try s.endArray();
    try s.objectField("command");
    try s.write(evidence.command);
    try s.objectField("result");
    try s.write(@tagName(evidence.result));
    try s.objectField("device");
    try s.write(evidence.device);
    try s.objectField("duration_s");
    try s.write(evidence.duration_s);
    try s.objectField("commit");
    try s.write(evidence.commit);
    try s.objectField("clean_tree");
    try s.write(evidence.clean_tree);
    try s.objectField("at");
    try s.write(evidence.at);
    try s.endObject();
}

/// Epoch seconds as `YYYY-MM-DDTHH:MM:SSZ`: the form a reader sorts and a human reads.
fn isoUtc(a: std.mem.Allocator, epoch_seconds: u64) ![]const u8 {
    const seconds = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const year_day = seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = seconds.getDaySeconds();
    return std.fmt.allocPrint(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

/// The real machine: child processes, and the system clock.
const system_deps: Deps = .{ .run = systemRun, .now = systemNow };

/// Spawn `argv`: streamed when the run wants its output on this terminal (the instrumented run),
/// captured when the gate reads it (`git`, `adb`).
fn systemRun(ctx: ?*anyopaque, io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, capture: bool) Outcome {
    _ = ctx;
    if (!capture) {
        var child = std.process.spawn(io, .{ .argv = argv }) catch |err| {
            report("{s} could not start: {s}", .{ argv[0], @errorName(err) });
            return .{ .ok = false, .stdout = &.{} };
        };
        const term = child.wait(io) catch |err| {
            report("{s} could not be waited for: {s}", .{ argv[0], @errorName(err) });
            return .{ .ok = false, .stdout = &.{} };
        };
        return .{ .ok = term.success(), .stdout = &.{} };
    }
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch |err| {
        report("{s} could not run: {s}", .{ argv[0], @errorName(err) });
        return .{ .ok = false, .stdout = &.{} };
    };
    gpa.free(result.stderr);
    return .{ .ok = result.term.success(), .stdout = result.stdout };
}

/// The wall clock in epoch seconds; a clock before the epoch reads as zero rather than wrapping.
fn systemNow(ctx: ?*anyopaque, io: std.Io) u64 {
    _ = ctx;
    const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    return if (seconds < 0) 0 else @intCast(seconds);
}

/// The one device-run command the build target's options become.
pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cli = parseArgs(init.minimal.args);
    if (cli.methods.len == 0) failFlag("--methods names the methods this run must prove", .{});
    if (cli.sdk_root.len == 0) failFlag("--sdk names the Android SDK root", .{});
    if (cli.app_apk.len == 0) failFlag("--app-apk names the built app APK", .{});
    if (cli.out_dir.len == 0) failFlag("--out names the test run's scratch directory", .{});
    if (cli.manifest.len == 0) failFlag("--manifest names the test APK manifest", .{});
    if (cli.java_source.len == 0) failFlag("--java names the test source", .{});
    if (cli.api_level == 0) failFlag("--api names the API level the APK targets", .{});

    const required = try collectRequired(a, cli.methods, cli.why);
    if (required.len == 0) failFlag("--methods names no method", .{});

    // A record is only evidence where a reader looks for it, so its directory is made first.
    if (std.fs.path.dirname(cli.evidence_out)) |dir| {
        std.Io.Dir.cwd().createDirPath(init.io, dir) catch |err| {
            report("the record's directory {s} could not be created: {s}", .{ dir, @errorName(err) });
            std.process.exit(1);
        };
    }

    runGate(init.io, a, .{
        .required = required,
        .evidence_path = cli.evidence_out,
        .sdk_root = cli.sdk_root,
        .api_level = cli.api_level,
        .app_apk = cli.app_apk,
        .out_dir = cli.out_dir,
        .manifest = cli.manifest,
        .java_source = cli.java_source,
        .issue = cli.issue,
        // `adb` itself honours ANDROID_SERIAL, so the serial the run proves is also the one the
        // test script targets when several devices are attached.
        .device = init.environ_map.get("ANDROID_SERIAL"),
    }, system_deps) catch std.process.exit(1);
}
/// The script that starts the agent's own emulator, which is what a missing device is told to run.
const START_SCRIPT = "scripts/android-emulator-start.sh";
/// The device suite's runner: it builds the test APK and instruments one run on one device.
const TEST_SCRIPT = "scripts/android-test.sh";
/// The `adb devices` state that means a device is usable.
const DEVICE_STATE = "device";
/// Where the record goes when the caller names no path.
const DEFAULT_EVIDENCE = "zig-out/android-evidence.json";
/// The reason a required method carries when the caller gives none.
const DEFAULT_WHY = "named for this device run";

/// The option values the build hands the gate.
const Cli = struct {
    /// Comma-separated method names the run must prove.
    methods: []const u8 = "",
    /// Why those methods are required, recorded with each of them.
    why: []const u8 = DEFAULT_WHY,
    /// Where the evidence JSON goes.
    evidence_out: []const u8 = DEFAULT_EVIDENCE,
    /// The issue whose branch required the run.
    issue: ?u32 = null,
    /// Android SDK root.
    sdk_root: []const u8 = "",
    /// API level the app APK targets.
    api_level: u32 = 0,
    /// The built app APK the run installs.
    app_apk: []const u8 = "",
    /// The test run's scratch directory.
    out_dir: []const u8 = "",
    /// The test APK's manifest.
    manifest: []const u8 = "",
    /// The test source the scenarios live in.
    java_source: []const u8 = "",
};

/// Read the gate's flags. A value the run cannot do without prints the usage and exits, because a
/// run that cannot say what to prove must not start.
fn parseArgs(args: std.process.Args) Cli {
    var cli: Cli = .{};
    var it = std.process.Args.iterate(args);
    _ = it.next(); // process name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--methods")) {
            cli.methods = valueOf(&it, "--methods");
        } else if (std.mem.eql(u8, arg, "--why")) {
            cli.why = valueOf(&it, "--why");
        } else if (std.mem.eql(u8, arg, "--evidence-out")) {
            cli.evidence_out = valueOf(&it, "--evidence-out");
        } else if (std.mem.eql(u8, arg, "--issue")) {
            cli.issue = std.fmt.parseInt(u32, valueOf(&it, "--issue"), 10) catch failFlag("--issue takes an issue number", .{});
        } else if (std.mem.eql(u8, arg, "--sdk")) {
            cli.sdk_root = valueOf(&it, "--sdk");
        } else if (std.mem.eql(u8, arg, "--api")) {
            cli.api_level = std.fmt.parseInt(u32, valueOf(&it, "--api"), 10) catch failFlag("--api takes an API level", .{});
        } else if (std.mem.eql(u8, arg, "--app-apk")) {
            cli.app_apk = valueOf(&it, "--app-apk");
        } else if (std.mem.eql(u8, arg, "--out")) {
            cli.out_dir = valueOf(&it, "--out");
        } else if (std.mem.eql(u8, arg, "--manifest")) {
            cli.manifest = valueOf(&it, "--manifest");
        } else if (std.mem.eql(u8, arg, "--java")) {
            cli.java_source = valueOf(&it, "--java");
        } else {
            failFlag("unknown flag: {s}", .{arg});
        }
    }
    return cli;
}

/// One flag's value, or the usage: a flag left dangling names no method and no path.
fn valueOf(it: *std.process.Args.Iterator, flag: []const u8) []const u8 {
    return it.next() orelse failFlag("{s} requires a value", .{flag});
}

/// The methods named on the command line, each carrying the reason the caller gave for requiring it.
fn collectRequired(a: std.mem.Allocator, csv: []const u8, why: []const u8) ![]const Method {
    var list: std.ArrayList(Method) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const method = std.mem.trim(u8, raw, " \t");
        if (method.len == 0) continue;
        try list.append(a, .{ .method = method, .why = why });
    }
    return list.items;
}

/// Exit status for a bad flag: the caller's typo, not a crash.
const FLAG_ERROR_EXIT = 2;

/// A bad flag prints the usage and exits without a stack trace.
fn failFlag(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt ++ "\n\n{s}", args ++ .{USAGE});
    std.process.exit(FLAG_ERROR_EXIT);
}

/// What the gate is and how to run it, printed with a bad flag.
const USAGE =
    \\usage: android-gate --methods <m1[,m2…]> --sdk <root> --api <level> --app-apk <path>
    \\                    --out <dir> --manifest <path> --java <path>
    \\                    [--evidence-out <path>] [--issue <n>] [--why <text>]
    \\
    \\Runs exactly the named FileBridgeTest methods on exactly one connected device and writes
    \\the evidence record. `zig build android-gate -Dandroid-methods=…` passes these; start a
    \\device with scripts/android-emulator-start.sh.
    \\
;

/// The record as a reader parses it: the shape another tool depends on, field for field.
const Written = struct {
    issue: ?u32 = null,
    required: []const WrittenMethod,
    methods: []const []const u8,
    command: []const u8,
    result: []const u8,
    device: []const u8,
    duration_s: u64,
    commit: []const u8,
    clean_tree: bool,
    at: []const u8,
};

/// One required method in the written record.
const WrittenMethod = struct {
    method: []const u8,
    why: []const u8,
};

/// Stands in for the machine: a table of command answers and a frozen clock.
const Fake = struct {
    status: []const u8 = "",
    commit: []const u8 = "9f2c1a0e5b\n",
    devices: []const u8 = "List of devices attached\nemulator-5554\tdevice\n",
    run_ok: bool = true,
    runs: usize = 0,
    started: u64 = 1_700_000_000,
    finished: u64 = 1_700_000_042,
    now_calls: usize = 0,
};

/// Answer a capture with a copy of `text`. The copy comes from the stand-in's own allocator, so a
/// test that refuses the run's allocations reaches the run rather than the double.
fn fakeAnswer(text: []const u8) Outcome {
    const copy = std.heap.page_allocator.dupe(u8, text) catch |err| {
        std.debug.print("android-gate test: the fake's answer could not be allocated: {s}\n", .{@errorName(err)});
        return .{ .ok = false, .stdout = &.{} };
    };
    return .{ .ok = true, .stdout = copy };
}

/// Answer `git` and `adb` from the fake's table, and count the instrumented run.
fn fakeRun(ctx: ?*anyopaque, io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8, capture: bool) Outcome {
    _ = io;
    _ = gpa;
    _ = capture;
    const fake: *Fake = @ptrCast(@alignCast(ctx.?));
    if (std.mem.eql(u8, argv[0], "git")) {
        if (argv.len > 1 and std.mem.eql(u8, argv[1], "status")) return fakeAnswer(fake.status);
        return fakeAnswer(fake.commit);
    }
    if (std.mem.eql(u8, argv[0], "adb")) return fakeAnswer(fake.devices);
    fake.runs += 1;
    return .{ .ok = fake.run_ok, .stdout = &.{} };
}

/// The frozen clock: the run starts at `started` and finishes at `finished`.
fn fakeNow(ctx: ?*anyopaque, io: std.Io) u64 {
    _ = io;
    const fake: *Fake = @ptrCast(@alignCast(ctx.?));
    fake.now_calls += 1;
    return if (fake.now_calls <= 1) fake.started else fake.finished;
}

/// A request for a two-method run whose tooling paths are plausible but never touched.
fn testRequest(required: []const Method, evidence_path: []const u8) Request {
    return .{
        .required = required,
        .evidence_path = evidence_path,
        .sdk_root = "/sdk",
        .api_level = 30,
        .app_apk = "zig-out/android/sudoku.apk",
        .out_dir = "zig-out/android-test",
        .manifest = "src/android/test/AndroidManifest.xml",
        .java_source = "src/android/test/FileBridgeTest.java",
        .issue = 7,
    };
}

/// The evidence file, parsed; `name` is relative to the test's temporary directory.
fn readWritten(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) !std.json.Parsed(Written) {
    const bytes = try dir.readFileAlloc(io, name, gpa, std.Io.Limit.unlimited);
    defer gpa.free(bytes);
    // The parsed slices outlive the bytes, so the parser copies every string into its own arena.
    return std.json.parseFromSlice(Written, gpa, bytes, .{ .allocate = .alloc_always });
}

/// The two methods the smoke and a changed scenario would name.
const two_methods = [_]Method{
    .{ .method = "coreAndJsLogLinesReachLogcat", .why = "the pinned smoke" },
    .{ .method = "backLeavesTheApp", .why = "changed by this branch" },
};
/// The evidence path for a test's temporary directory, absolute so the gate writes where it says.
fn tempEvidencePath(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, buf: *[std.Io.Dir.max_path_bytes]u8) ![]u8 {
    const written = try dir.realPath(io, buf);
    return std.fs.path.join(gpa, &[_][]const u8{ buf[0..written], "android-evidence.json" });
}

test "gate: the record names the commit, the clean tree, the device and the methods it ran" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{};
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    try runGate(io, gpa, testRequest(&two_methods, path), .{ .ctx = &fake, .run = fakeRun, .now = fakeNow });

    const parsed = try readWritten(io, gpa, tmp.dir, "android-evidence.json");
    defer parsed.deinit();
    const evidence = parsed.value;

    try std.testing.expectEqual(@as(?u32, 7), evidence.issue);
    try std.testing.expectEqualStrings("9f2c1a0e5b", evidence.commit);
    try std.testing.expectEqual(true, evidence.clean_tree);
    try std.testing.expectEqualStrings("emulator-5554", evidence.device);
    try std.testing.expectEqual(@as(u64, 42), evidence.duration_s);
    try std.testing.expectEqualStrings("passed", evidence.result);
    // The record is stamped when it is written, so `at` is the run's finish.
    try std.testing.expectEqualStrings("2023-11-14T22:14:02Z", evidence.at);
    try std.testing.expectEqual(@as(usize, 2), evidence.methods.len);
    try std.testing.expectEqualStrings("coreAndJsLogLinesReachLogcat", evidence.methods[0]);
    try std.testing.expectEqualStrings("backLeavesTheApp", evidence.methods[1]);
    try std.testing.expectEqual(@as(usize, 2), evidence.required.len);
    try std.testing.expectEqualStrings("backLeavesTheApp", evidence.required[1].method);
    try std.testing.expectEqualStrings("changed by this branch", evidence.required[1].why);
    // One instrumented run, naming both methods in the comma list the test script splits.
    try std.testing.expectEqual(@as(usize, 1), fake.runs);
    try std.testing.expect(std.mem.indexOf(u8, evidence.command, "scripts/android-test.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, evidence.command, "coreAndJsLogLinesReachLogcat,backLeavesTheApp") != null);
}

test "gate: a dirty worktree is refused before the device run starts" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{ .status = " M src/android/test/FileBridgeTest.java\n" };
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    try std.testing.expectError(error.DirtyWorktree, runGate(io, gpa, testRequest(&two_methods, path), .{ .ctx = &fake, .run = fakeRun, .now = fakeNow }));
    try std.testing.expectEqual(@as(usize, 0), fake.runs);
    // Nothing was proved, so there is no record to read as proof.
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "android-evidence.json", gpa, std.Io.Limit.unlimited));
}

test "gate: no device stops the run with the start script, never a skip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{ .devices = "List of devices attached\n\n" };
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    try std.testing.expectError(error.NoDevice, runGate(io, gpa, testRequest(&two_methods, path), .{ .ctx = &fake, .run = fakeRun, .now = fakeNow }));
    try std.testing.expectEqual(@as(usize, 0), fake.runs);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "android-evidence.json", gpa, std.Io.Limit.unlimited));
}

test "gate: two devices are refused, because the record could not say which one was proved" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{ .devices = "List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n" };
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    try std.testing.expectError(error.ManyDevices, runGate(io, gpa, testRequest(&two_methods, path), .{ .ctx = &fake, .run = fakeRun, .now = fakeNow }));
    try std.testing.expectEqual(@as(usize, 0), fake.runs);
}

test "gate: ANDROID_SERIAL picks the device that proves the run when several are attached" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{ .devices = "List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n" };
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    var request = testRequest(&two_methods, path);
    request.device = "emulator-5556";
    try runGate(io, gpa, request, .{ .ctx = &fake, .run = fakeRun, .now = fakeNow });

    const parsed = try readWritten(io, gpa, tmp.dir, "android-evidence.json");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("emulator-5556", parsed.value.device);
    try std.testing.expectEqual(@as(usize, 1), fake.runs);
}

test "gate: a named device that is not attached is refused, never silently swapped" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{ .devices = "List of devices attached\nemulator-5554\tdevice\n" };
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    var request = testRequest(&two_methods, path);
    request.device = "emulator-9999";
    try std.testing.expectError(error.NoDevice, runGate(io, gpa, request, .{ .ctx = &fake, .run = fakeRun, .now = fakeNow }));
    try std.testing.expectEqual(@as(usize, 0), fake.runs);
}

test "gate: a failed run still writes its record, marked failed" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{ .run_ok = false };
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, gpa, tmp.dir, &path_buf);
    defer gpa.free(path);

    try std.testing.expectError(error.TestsFailed, runGate(io, gpa, testRequest(&two_methods, path), .{ .ctx = &fake, .run = fakeRun, .now = fakeNow }));

    const parsed = try readWritten(io, gpa, tmp.dir, "android-evidence.json");
    defer parsed.deinit();
    try std.testing.expectEqualStrings("failed", parsed.value.result);
    try std.testing.expectEqualStrings("9f2c1a0e5b", parsed.value.commit);
}

test "gate: adb devices keeps only the devices that are connected" {
    // `adb` separates a serial from its state with a tab; an offline or unauthorized device is not one.
    const listed = "List of devices attached\nemulator-5554\tdevice\nemulator-5556\toffline\nZY223x\tunauthorized\n";
    const found = parseDevices(listed);
    try std.testing.expectEqual(@as(usize, 1), found.count);
    try std.testing.expectEqualStrings("emulator-5554", found.first);

    const several = parseDevices("List of devices attached\nemulator-5554\tdevice\nZY223x\tdevice\n");
    try std.testing.expectEqual(@as(usize, 2), several.count);
    try std.testing.expectEqualStrings("emulator-5554", several.first);

    const none = parseDevices("List of devices attached\n\n");
    try std.testing.expectEqual(@as(usize, 0), none.count);
}

test "gate: the record's timestamp is UTC ISO 8601" {
    const gpa = std.testing.allocator;
    const epoch = try isoUtc(gpa, 0);
    defer gpa.free(epoch);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", epoch);

    const leap_day = try isoUtc(gpa, 951_782_400);
    defer gpa.free(leap_day);
    try std.testing.expectEqualStrings("2000-02-29T00:00:00Z", leap_day);
}

test "gate: an allocation failure is named, so the entry never exits silently" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fake = Fake{};
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tempEvidencePath(io, std.testing.allocator, tmp.dir, &path_buf);
    defer std.testing.allocator.free(path);

    // The run's own allocator refuses its first request, so the run stops before the record. What
    // it must not do is leave the reader with a bare non-zero status and no line.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var logged: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&logged);
    report_sink = &sink;
    defer report_sink = null;

    try std.testing.expectError(error.OutOfMemory, runGate(io, failing.allocator(), testRequest(&two_methods, path), .{ .ctx = &fake, .run = fakeRun, .now = fakeNow }));
    try std.testing.expectEqualStrings("android-gate: the run stopped, out of memory: OutOfMemory\n", sink.buffered());
}
