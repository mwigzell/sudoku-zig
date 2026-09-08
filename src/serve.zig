/// Routes request paths to the served asset. Pure: no sockets, no std.Io —
/// the socket layer lives elsewhere and drives this through Router.route().
const std = @import("std");

pub const RouteResult = enum { page, glue, artifact };

/// The three known routes and the delivered-once set.
pub const Router = struct {
    /// Three known routes: page, glue, artifact — one bool each.
    delivered: [3]bool,

    pub const Error = error{NotFound};

    pub fn init() Router {
        return .{ .delivered = [_]bool{ false, false, false } };
    }

    /// Maps a request path to its asset; anything else is a router-level 404.
    pub fn route(path: []const u8) Error!RouteResult {
        if (std.mem.eql(u8, path, "/")) return .page;
        if (std.mem.eql(u8, path, "/glue.js")) return .glue;
        if (std.mem.eql(u8, path, "/artifact.wasm")) return .artifact;
        return Error.NotFound;
    }

    /// Records that an asset has been served at least once.
    pub fn markDelivered(self: *Router, result: RouteResult) void {
        self.delivered[@intFromEnum(result)] = true;
    }

    /// The exit condition: every known route has been served at least once.
    pub fn allDelivered(self: *const Router) bool {
        for (self.delivered) |d| {
            if (!d) return false;
        }
        return true;
    }
};

test "serve: route \"/\" to the page" {
    try std.testing.expectEqual(RouteResult.page, Router.route("/"));
}

test "serve: route \"/glue.js\" to the glue" {
    try std.testing.expectEqual(RouteResult.glue, Router.route("/glue.js"));
}

test "serve: route \"/artifact.wasm\" to the artifact" {
    try std.testing.expectEqual(RouteResult.artifact, Router.route("/artifact.wasm"));
}

test "serve: unknown path is NotFound" {
    try std.testing.expectError(Router.Error.NotFound, Router.route("/nope.txt"));
}

test "serve: allDelivered false until each route marked, true after; re-marking one does not satisfy the rest" {
    var r = Router.init();
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.page);
    r.markDelivered(.page); // second mark must not advance the set
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.glue);
    try std.testing.expect(!r.allDelivered());

    r.markDelivered(.artifact);
    try std.testing.expect(r.allDelivered());
}
