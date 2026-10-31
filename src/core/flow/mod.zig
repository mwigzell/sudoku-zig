// Core-driven flows: each front end runs one `Flow` at a time by feeding
// step results back into `next` until a terminal step.
const std = @import("std");
const save_mod = @import("save.zig");
const autosave_mod = @import("autosave.zig");

pub const step = @import("step.zig");
pub const file_session = @import("file_session.zig");
pub const Step = step.Step;
pub const Input = step.Input;
pub const Ask = step.Ask;
pub const Wrote = step.Wrote;
pub const FileSession = file_session.FileSession;
pub const SaveFlow = save_mod.SaveFlow;
pub const AutosaveFlow = autosave_mod.AutosaveFlow;

pub const Flow = union(enum) {
    save: SaveFlow,
    autosave: AutosaveFlow,

    /// Advance whichever flow is running.
    pub fn next(self: *Flow, input: Input) Step {
        return switch (self.*) {
            .save => |*f| f.next(input),
            .autosave => |*f| f.next(input),
        };
    }
};

/// True once the flow has nothing more for the adapter to do.
pub fn isTerminal(s: Step) bool {
    return switch (s) {
        .show_status, .show_error, .done => true,
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = save_mod;
    _ = autosave_mod;
    _ = file_session;
}
