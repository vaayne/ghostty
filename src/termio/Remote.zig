//! Remote implements a termio backend that reads/writes over a pair of file
//! descriptors (pipes or sockets) instead of a pty. This is used for the
//! Mori Remote iOS app where terminal bytes come from a network relay rather
//! than a local shell process.
const Remote = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const xev = @import("../global.zig").xev;
const crash = @import("../crash/main.zig");
const fastmem = @import("../fastmem.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const SegmentedPool = @import("../datastruct/main.zig").SegmentedPool;

const log = std.log.scoped(.io_remote);

/// The file descriptors for reading and writing terminal data.
read_fd: posix.fd_t,
write_fd: posix.fd_t,

pub fn init(
    alloc: Allocator,
    cfg: Config,
) !Remote {
    _ = alloc;
    return .{
        .read_fd = cfg.read_fd,
        .write_fd = cfg.write_fd,
    };
}

pub fn deinit(self: *Remote) void {
    _ = self;
    // Caller owns the fds — do not close them here.
}

pub fn initTerminal(self: *Remote, term: *terminal.Terminal) void {
    _ = self;
    _ = term;
    // No shell integration or initial sizing for remote backend.
}

pub fn threadEnter(
    self: *Remote,
    alloc: Allocator,
    io: *termio.Termio,
    td: *termio.Termio.ThreadData,
) !void {
    _ = alloc;

    // Create quit pipe for signaling read thread shutdown.
    const pipe = try internal_os.pipe();
    errdefer posix.close(pipe[0]);
    errdefer posix.close(pipe[1]);

    // Setup xev write stream on the write fd.
    var stream = xev.Stream.initFd(self.write_fd);
    errdefer stream.deinit();

    // Spawn read thread that polls read_fd and forwards to termio.
    const read_thread = try std.Thread.spawn(
        .{},
        ReadThread.threadMain,
        .{ self.read_fd, io, pipe[0] },
    );
    read_thread.setName("io-remote-reader") catch {};

    // Store thread data.
    td.backend = .{ .remote = .{
        .write_stream = stream,
        .read_thread = read_thread,
        .read_thread_pipe = pipe[1],
    } };
}

pub fn threadExit(self: *Remote, td: *termio.Termio.ThreadData) void {
    _ = self;

    const remote = &td.backend.remote;

    // Signal read thread to quit.
    _ = posix.write(remote.read_thread_pipe, "x") catch |err| switch (err) {
        error.BrokenPipe => {},
        else => log.warn("error writing to read thread quit pipe err={}", .{err}),
    };

    remote.read_thread.join();
}

pub fn focusGained(
    self: *Remote,
    td: *termio.Termio.ThreadData,
    focused: bool,
) !void {
    _ = self;
    _ = td;
    _ = focused;
    // No-op for remote backend.
}

pub fn resize(
    self: *Remote,
    grid_size: renderer.GridSize,
    screen_size: renderer.ScreenSize,
) !void {
    _ = self;
    _ = grid_size;
    _ = screen_size;
    // Resize is handled at the protocol level by the Swift caller,
    // which sends a Resize control message over WebSocket.
}

pub fn queueWrite(
    self: *Remote,
    alloc: Allocator,
    td: *termio.Termio.ThreadData,
    data: []const u8,
    linefeed: bool,
) !void {
    _ = self;
    const remote = &td.backend.remote;

    // Chunk data into pooled buffers and queue writes via xev.
    var i: usize = 0;
    while (i < data.len) {
        const req = try remote.write_req_pool.getGrow(alloc);
        const buf = try remote.write_buf_pool.getGrow(alloc);
        const slice = slice: {
            const max = @min(data.len, i + buf.len);

            if (!linefeed) {
                fastmem.copy(u8, buf, data[i..max]);
                const len = max - i;
                i = max;
                break :slice buf[0..len];
            }

            // Slow path: replace \r with \r\n
            var buf_i: usize = 0;
            while (i < data.len and buf_i < buf.len - 1) {
                const ch = data[i];
                i += 1;
                if (ch != '\r') {
                    buf[buf_i] = ch;
                    buf_i += 1;
                    continue;
                }
                buf[buf_i] = '\r';
                buf[buf_i + 1] = '\n';
                buf_i += 2;
            }
            break :slice buf[0..buf_i];
        };

        remote.write_stream.queueWrite(
            td.loop,
            &remote.write_queue,
            req,
            .{ .slice = slice },
            ThreadData,
            remote,
            fdWrite,
        );
    }
}

fn fdWrite(
    td_: ?*ThreadData,
    _: *xev.Loop,
    _: *xev.Completion,
    _: xev.Stream,
    _: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const td = td_.?;
    td.write_req_pool.put();
    td.write_buf_pool.put();

    _ = r catch |err| {
        log.err("write error: {}", .{err});
        return .disarm;
    };

    return .disarm;
}

pub fn childExitedAbnormally(
    self: *Remote,
    gpa: Allocator,
    t: *terminal.Terminal,
    exit_code: u32,
    runtime_ms: u64,
) !void {
    _ = self;
    _ = gpa;
    _ = t;
    _ = exit_code;
    _ = runtime_ms;
    // No child process in remote backend.
}

// MARK: - ThreadData

pub const ThreadData = struct {
    const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

    write_stream: xev.Stream,
    write_req_pool: SegmentedPool(xev.WriteRequest, WRITE_REQ_PREALLOC) = .{},
    write_buf_pool: SegmentedPool([64]u8, WRITE_REQ_PREALLOC) = .{},
    write_queue: xev.WriteQueue = .{},

    read_thread: std.Thread,
    read_thread_pipe: posix.fd_t,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        posix.close(self.read_thread_pipe);
        self.write_req_pool.deinit(alloc);
        self.write_buf_pool.deinit(alloc);
        self.write_stream.deinit();
    }
};

// MARK: - Config

pub const Config = struct {
    /// File descriptor to read terminal output from (pipe read end).
    read_fd: posix.fd_t,
    /// File descriptor to write terminal input to (pipe write end).
    write_fd: posix.fd_t,
};

// MARK: - ReadThread

pub const ReadThread = struct {
    fn threadMain(fd: posix.fd_t, io: *termio.Termio, quit: posix.fd_t) void {
        defer posix.close(quit);

        if (builtin.os.tag.isDarwin()) {
            internal_os.macos.pthread_setname_np(&"io-remote-reader".*);
        }

        crash.sentry.thread_state = .{
            .type = .io,
            .surface = io.surface_mailbox.surface,
        };
        defer crash.sentry.thread_state = null;

        // Set read fd to non-blocking for tight read loop.
        if (posix.fcntl(fd, posix.F.GETFL, 0)) |flags| {
            _ = posix.fcntl(
                fd,
                posix.F.SETFL,
                flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })),
            ) catch |err| {
                log.warn("remote read thread failed to set flags err={}", .{err});
            };
        } else |err| {
            log.warn("remote read thread failed to get flags err={}", .{err});
        }

        var pollfds: [2]posix.pollfd = .{
            .{ .fd = fd, .events = posix.POLL.IN, .revents = undefined },
            .{ .fd = quit, .events = posix.POLL.IN, .revents = undefined },
        };

        var buf: [4096]u8 = undefined;
        while (true) {
            while (true) {
                const n = posix.read(fd, &buf) catch |err| {
                    switch (err) {
                        error.NotOpenForReading,
                        error.InputOutput,
                        => {
                            log.info("remote reader exiting (fd closed)", .{});
                            return;
                        },
                        error.WouldBlock => break,
                        else => {
                            log.err("remote reader error err={}", .{err});
                            return;
                        },
                    }
                };

                if (n == 0) break;

                @call(.always_inline, termio.Termio.processOutput, .{ io, buf[0..n] });
            }

            _ = posix.poll(&pollfds, -1) catch |err| {
                log.warn("poll failed on remote read thread err={}", .{err});
                return;
            };

            if (pollfds[1].revents & posix.POLL.IN != 0) {
                log.info("remote read thread got quit signal", .{});
                return;
            }

            if (pollfds[0].revents & posix.POLL.HUP != 0) {
                log.info("remote read fd closed, exiting", .{});
                return;
            }
        }
    }
};
