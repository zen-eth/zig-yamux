const std = @import("std");
const Allocator = std.mem.Allocator;
const LinearFifo = std.fifo.LinearFifo;
const frame = @import("frame.zig");
const session = @import("session.zig");

pub const StreamState = enum {
    init,
    syn_sent,
    syn_received,
    established,
    local_close,
    remote_close,
    closed,
    reset,
};

pub const Error = error{
    StreamClosed,
    StreamReset,
    StreamFlag,
    WriteTimeout,
    ReadTimeout,
};

pub const Stream = struct {
    recv_window: u32,
    send_window: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    id: u32,
    session: *session.Session,

    state: StreamState,
    state_mutex: std.Thread.Mutex = .{},

    recv_buf: ?*LinearFifo(u8, .Dynamic),
    recv_mutex: std.Thread.Mutex = .{},

    control_hdr: []u8,
    control_err: ?Error = null,
    control_mutex: std.Thread.Mutex = .{},

    send_hdr: []u8,
    send_err: ?Error = null,
    send_mutex: std.Thread.Mutex = .{},

    // Notification channels implemented with condition variables
    recv_notify: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        signaled: bool = false,
    } = .{},

    send_notify: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        signaled: bool = false,
    } = .{},

    read_deadline: std.atomic.Value(?*std.time.Instant) = std.atomic.Value(?*std.time.Instant).init(null),
    write_deadline: std.atomic.Value(?*std.time.Instant) = std.atomic.Value(?*std.time.Instant).init(null),

    // For establishment notification
    establish: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        signaled: bool = false,
    } = .{},

    // Set with state_mutex held to honor the StreamCloseTimeout
    close_timer: ?std.time.Timer = null,
};
