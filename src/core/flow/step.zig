// Flow protocol: core issues steps, adapters carry each one out on their
// platform and report the result back as the next input.

/// A two-button question; `yes` in the answer means the user picked `ok_label`.
pub const Ask = struct {
    title: []const u8,
    text: []const u8,
    ok_label: []const u8,
    cancel_label: []const u8,
};

/// One thing for the adapter to do. `show_status`, `show_error` and `done` end the flow.
pub const Step = union(enum) {
    /// Report the platform's default save target name.
    resolve_default_target,
    /// Report whether the named target already exists for the user.
    check_target: []const u8,
    ask: Ask,
    /// Write the current game to the named target.
    write: []const u8,
    show_status: []const u8,
    show_error: []const u8,
    done,
};

/// Outcome of a `write` step.
pub const Wrote = union(enum) {
    /// Name of the target actually written (the platform may rename it).
    ok: []const u8,
    /// The user backed out of a platform picker.
    cancelled,
    failed: []const u8,
};

/// Adapter report for the step it just carried out.
pub const Input = union(enum) {
    start,
    default_target: []const u8,
    target_checked: bool,
    answered: bool,
    wrote: Wrote,
};

/// Shown when an adapter answers a step with the wrong kind of input.
pub const UNEXPECTED_INPUT_MSG = "The save could not finish because the app sent an unexpected answer.";
