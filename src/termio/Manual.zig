//! Manual termio backend. This provides a terminal surface that accepts
//! input/output programmatically rather than through a PTY/subprocess.
//! This is used on platforms like iOS where PTYs are not available.
const Manual = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");

const log = std.log.scoped(.io_manual);

pub const Config = struct {
    grid_size: renderer.GridSize = .{},
    screen_size: renderer.ScreenSize = .{ .width = 1, .height = 1 },
};

grid_size: renderer.GridSize,
screen_size: renderer.ScreenSize,
io: ?*termio.Termio = null,

pub fn init(alloc: Allocator, cfg: Config) !Manual {
    _ = alloc;
    return .{
        .grid_size = cfg.grid_size,
        .screen_size = cfg.screen_size,
    };
}

pub fn deinit(self: *Manual) void {
    self.* = undefined;
}

pub fn initTerminal(self: *Manual, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
}

pub fn threadEnter(
    self: *Manual,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;
    self.io = io;
    td.backend = .{ .manual = .{} };
}

pub fn threadExit(self: *Manual, td: *termio.Termio.ThreadData) void {
    _ = td;
    self.io = null;
}

pub fn focusGained(
    self: *Manual,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
}

pub fn resize(
    self: *Manual,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    self.grid_size = grid_size;
    self.screen_size = screen_size;
}

pub fn queueWrite(
    self: *Manual,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    _ = alloc;
    _ = td;
    _ = data;
    _ = linefeed;
    // Input is handled by the host application, not echoed here.
    // Output comes through ghostty_surface_write_output().
}

pub const ThreadData = struct {
    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }
};
