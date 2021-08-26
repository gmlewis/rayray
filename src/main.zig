const std = @import("std");

const c = @import("c.zig");
const Window = @import("window.zig").Window;
const Options = @import("options.zig").Options;

pub fn main() anyerror!void {
    var gp_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    // defer std.testing.expect(!gp_alloc.deinit());
    defer std.debug.assert(!gp_alloc.deinit());
    const alloc: *std.mem.Allocator = &gp_alloc.allocator;

    if (c.glfwInit() != c.GLFW_TRUE) {
        std.debug.panic("Could not initialize glfw", .{});
    }

    const options = try Options.parse_args(alloc);

    var window = try Window.init(alloc, options, "rayray");
    defer window.deinit();

    try window.run();
}
