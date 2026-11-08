// Config table: one row per saved Config field — its label and the values every Settings menu offers.
// Core owns the words; front ends draw their menus from these rows and change Config through `apply`.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const logger = @import("logger.zig");

const Config = config.Config;

/// One value a choice field can take.
pub const Choice = struct {
    /// The value's name in `config.json` (the enum tag).
    name: []const u8,
    /// What the player sees for it.
    label: []const u8,
};

/// What a field accepts: on/off, or one of a fixed list of choices.
pub const Kind = union(enum) {
    on_off,
    choices: []const Choice,
};

/// One saved Config field as the Settings menus show it.
pub const Row = struct {
    /// The Config field's name, as saved.
    field: []const u8,
    /// The field's label on every front end.
    label: []const u8,
    /// The values the field accepts.
    kind: Kind,

    /// Label of the choice named `name`; null when the row has no such choice.
    pub fn choiceLabel(self: Row, name: []const u8) ?[]const u8 {
        const choices = switch (self.kind) {
            .on_off => return null,
            .choices => |c| c,
        };
        for (choices) |choice| {
            if (std.mem.eql(u8, choice.name, name)) return choice.label;
        }
        return null;
    }

    /// What the player sees for `value` in this row.
    pub fn valueLabel(self: Row, value: Value) []const u8 {
        return switch (value) {
            .on => |on| if (on) ON_LABEL else OFF_LABEL,
            .choice => |name| self.choiceLabel(name) orelse name,
        };
    }
};

/// A value for one field: on/off for an on/off field, a choice's name for a choice field.
pub const Value = union(enum) {
    on: bool,
    choice: []const u8,
};

/// One requested Config change: the field's name and its new value, both checked by `apply`.
pub const Change = struct {
    field: []const u8,
    value: Value,
};

/// Shown for an on/off field that is on.
pub const ON_LABEL = "On";
/// Shown for an on/off field that is off.
pub const OFF_LABEL = "Off";
/// Shown when a change names no setting.
pub const UNKNOWN_FIELD_MSG = "There is no setting by that name.";
/// Shown when a change gives a setting a value it cannot take.
pub const BAD_VALUE_MSG = "That value is not one this setting can take.";

/// Why `apply` refused a change.
pub const Error = error{ UnknownField, BadValue };

/// Every saved Config field, in the order the Settings menus list them.
pub const rows = app_rows ++ test_rows;

/// The test build's extra row, for `Config.test_probe`.
const test_rows = if (builtin.is_test) [_]Row{
    .{ .field = "test_probe", .label = "Test Probe", .kind = .on_off },
} else [_]Row{};

const app_rows = [_]Row{
    .{ .field = "warn_solvability", .label = "Solvability Warnings", .kind = .on_off },
    .{ .field = "difficulty", .label = "Default Difficulty", .kind = .{ .choices = &.{
        .{ .name = "easy", .label = "Easy" },
        .{ .name = "medium", .label = "Medium" },
        .{ .name = "hard", .label = "Hard" },
    } } },
    .{ .field = "log_level", .label = "Log Level", .kind = .{ .choices = &.{
        .{ .name = "debug", .label = "Debug" },
        .{ .name = "info", .label = "Info" },
        .{ .name = "warn", .label = "Warn" },
        .{ .name = "err", .label = "Error" },
        .{ .name = "fatal", .label = "Fatal" },
    } } },
    .{ .field = "theme", .label = "Theme", .kind = .{ .choices = &.{
        .{ .name = "system", .label = "System" },
        .{ .name = "light", .label = "Light" },
        .{ .name = "dark", .label = "Dark" },
    } } },
    .{ .field = "auto_restore", .label = "Auto Restore", .kind = .on_off },
    .{ .field = "auto_new", .label = "Auto New", .kind = .on_off },
    .{ .field = "auto_save", .label = "Auto Save", .kind = .on_off },
    .{ .field = "show_region", .label = "Show Region", .kind = .on_off },
    .{ .field = "show_marks", .label = "Show Pencil Marks", .kind = .on_off },
};

/// Comptime string comparisons over the rows and Config's fields need more than the default branch budget.
const COMPTIME_BRANCH_QUOTA = 10_000;

// The rows and Config's saved fields must match one to one, with kinds that fit the field types.
comptime {
    @setEvalBranchQuota(COMPTIME_BRANCH_QUOTA);
    var saved = 0;
    for (@typeInfo(Config).@"struct".field_names) |name| {
        if (!Config.isSaved(name)) continue;
        saved += 1;
        checkRow(@FieldType(Config, name), row(name));
    }
    if (saved != rows.len) @compileError("config table has a row that is not a saved Config field");
}

fn checkRow(comptime T: type, comptime r: Row) void {
    switch (r.kind) {
        .on_off => if (T != bool) @compileError("on/off row for a field that is not a bool: " ++ r.field),
        .choices => |choices| for (choices) |choice| {
            if (std.meta.stringToEnum(T, choice.name) == null) @compileError("choice is not a value of " ++ r.field ++ ": " ++ choice.name);
        },
    }
}

/// The row for `field`; a name with no row fails to compile.
pub fn row(comptime field: []const u8) Row {
    return rows[comptime rowIndex(field)];
}

fn rowIndex(comptime field: []const u8) usize {
    @setEvalBranchQuota(COMPTIME_BRANCH_QUOTA);
    for (rows, 0..) |r, i| {
        if (std.mem.eql(u8, r.field, field)) return i;
    }
    @compileError("no config table row for " ++ field);
}

/// Set `change.field` in `cfg` to `change.value`; `cfg` is unchanged when either is refused.
pub fn apply(cfg: *Config, change: Change) Error!void {
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        if (comptime !Config.isSaved(name)) continue;
        if (std.mem.eql(u8, change.field, name)) {
            @field(cfg, name) = try parse(@FieldType(Config, name), comptime row(name), change.value);
            return;
        }
    }
    return Error.UnknownField;
}

fn parse(comptime T: type, comptime r: Row, value: Value) Error!T {
    if (T == bool) return switch (value) {
        .on => |on| on,
        .choice => Error.BadValue,
    };
    const name = switch (value) {
        .choice => |n| n,
        .on => return Error.BadValue,
    };
    // Only the row's choices are accepted, so enum values not offered (difficulty's `default`) are refused.
    if (r.choiceLabel(name) == null) return Error.BadValue;
    return std.meta.stringToEnum(T, name) orelse Error.BadValue;
}

/// The choice `name` of the field `field`, read as that field's type; only the row's choices are accepted.
pub fn parseChoice(comptime T: type, comptime field: []const u8, name: []const u8) Error!T {
    return parse(T, comptime row(field), .{ .choice = name });
}

/// A JSON value as a table value: a bool is on/off, a string names a choice; anything else is no value.
pub fn valueFromJson(json: std.json.Value) ?Value {
    return switch (json) {
        .bool => |on| .{ .on = on },
        .string => |name| .{ .choice = name },
        else => null,
    };
}

/// The current value of the field `r` describes.
pub fn get(cfg: Config, r: Row) Value {
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        if (comptime !Config.isSaved(name)) continue;
        if (std.mem.eql(u8, r.field, name)) {
            const v = @field(cfg, name);
            return if (@TypeOf(v) == bool) .{ .on = v } else .{ .choice = @tagName(v) };
        }
    }
    // Every row names a saved field (checked at compile time above).
    unreachable;
}

/// The change that flips the on/off field `r` (an `.on_off` row) from its value in `cfg`.
pub fn toggle(cfg: Config, r: Row) Change {
    return .{ .field = r.field, .value = .{ .on = !get(cfg, r).on } };
}

const testing = std.testing;

test "parseChoice reads a row's choice and refuses a value the row does not offer" {
    try testing.expectEqual(config.Difficulty.hard, try parseChoice(config.Difficulty, "difficulty", "hard"));
    try testing.expectError(Error.BadValue, parseChoice(config.Difficulty, "difficulty", "default"));
}

test "valueFromJson takes a bool or a string and nothing else" {
    try testing.expect(valueFromJson(.{ .bool = true }).?.on);
    try testing.expectEqualStrings("dark", valueFromJson(.{ .string = "dark" }).?.choice);
    try testing.expect(valueFromJson(.{ .integer = 2 }) == null);
}

test "apply sets an on/off field and a choice field by name" {
    var cfg = Config.default();
    try apply(&cfg, .{ .field = "show_region", .value = .{ .on = true } });
    try apply(&cfg, .{ .field = "log_level", .value = .{ .choice = "warn" } });
    try testing.expect(cfg.show_region);
    try testing.expectEqual(logger.Severity.warn, cfg.log_level);
}

test "apply refuses an unknown field, a value of the wrong kind and a choice not offered" {
    const before = Config.default();
    var cfg = before;
    try testing.expectError(Error.UnknownField, apply(&cfg, .{ .field = "renderers", .value = .{ .on = true } }));
    try testing.expectError(Error.UnknownField, apply(&cfg, .{ .field = "nope", .value = .{ .on = true } }));
    try testing.expectError(Error.BadValue, apply(&cfg, .{ .field = "show_region", .value = .{ .choice = "yes" } }));
    try testing.expectError(Error.BadValue, apply(&cfg, .{ .field = "theme", .value = .{ .on = true } }));
    try testing.expectError(Error.BadValue, apply(&cfg, .{ .field = "difficulty", .value = .{ .choice = "default" } }));
    try testing.expectEqual(before, cfg);
}

test "get reads every row's value back, and the labels show it" {
    var cfg = Config.default();
    cfg.theme = .dark;
    for (rows) |r| _ = get(cfg, r);
    try testing.expectEqualStrings("Dark", row("theme").valueLabel(get(cfg, row("theme"))));
    try testing.expectEqualStrings(ON_LABEL, row("show_marks").valueLabel(get(cfg, row("show_marks"))));
    try testing.expect(toggle(cfg, row("show_marks")).value.on == false);
}

test "refusals read as sentences" {
    const sentence = @import("../test/sentence.zig");
    try sentence.expectSentence(UNKNOWN_FIELD_MSG);
    try sentence.expectSentence(BAD_VALUE_MSG);
}
