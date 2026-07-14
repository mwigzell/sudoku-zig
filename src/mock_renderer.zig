const renderer = @import("renderer.zig");

/// Test helper: records every snapshot passed to render() so tests can assert on board state after commands.
pub const MockRenderer = struct {
    call_count: usize,
    last_snapshot: ?renderer.RenderSnapshot,

    pub fn init() MockRenderer {
        return .{
            .call_count = 0,
            .last_snapshot = null,
        };
    }

    /// Satisfies the Renderer contract. Stores snapshot for inspection.
    pub fn render(self: *MockRenderer, snap: renderer.RenderSnapshot) anyerror!void {
        self.call_count += 1;
        self.last_snapshot = snap;
    }
};
