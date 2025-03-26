const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;
const Conn = @import("conn.zig").AnyConn;
const Config = @import("Config.zig");
const Future = @import("future.zig").Future;
const Intrusive = @import("mpsc.zig").Intrusive;

pub const Error = error{SessionShutdown} || error{Timeout};

const Elem = struct {
    const Self = @This();
    next: ?*Self = null,
};

pub const SendQueue = Intrusive(SendReady);

pub const SendReady = struct {
    hdr: []u8,
    body: ?[]u8,
    notification: Future(void),
    next: ?*Self = null,

    const Self = @This();

    pub fn init(hdr: []u8, body: ?[]u8) SendReady {
        return .{
            .hdr = hdr,
            .body = body,
            .notification = .{},
        };
    }
};

pub const Session = struct {
    // remoteGoAway indicates the remote side does not want further connections.
    // Must be first for alignment.
    remote_go_away: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    // localGoAway indicates that we should stop accepting further connections.
    // Must be first for alignment.
    local_go_away: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),

    // nextStreamID is the next stream we should send.
    // This depends if we are a client/server.
    next_stream_id: std.atomic.Value(u32),

    // config holds our configuration
    config: *Config,

    // conn is the underlying connection
    conn: Conn,

    // bufRead is a buffered reader
    buf_read: std.io.AnyReader,

    // pings is used to track inflight pings
    pings: std.AutoHashMap(u32, *PingNotification),
    ping_id: u32 = 0,
    ping_mutex: std.Thread.Mutex = .{},

    // streams maps a stream id to a stream, and inflight has an entry
    // for any outgoing stream that has not yet been established.
    // Both are protected by stream_mutex.
    streams: std.AutoHashMap(u32, *Stream),
    inflight: std.AutoHashMap(u32, void),
    stream_mutex: std.Thread.Mutex = .{},

    // syn_semaphore acts like a semaphore. It is sized to the AcceptBacklog
    // which is assumed to be symmetric between the client and server.
    // This allows the client to avoid exceeding the backlog and instead
    // blocks the open.
    syn_semaphore: std.Thread.Semaphore,

    // accept_queue is used to pass ready streams to the client
    accept_queue: std.fifo.LinearFifo(*Stream, .Dynamic),

    // send_queue is used to mark a stream as ready to send,
    // or to send a header out directly.
    send_queue: SendQueue,

    // recv_done and send_done are used to coordinate shutdown
    recv_done: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    } = .{},

    send_done: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    } = .{},

    shutdown_notification: Future(bool),

    allocator: Allocator,

    pub fn waitForSend(self: *Session, hdr: []u8, body: ?[]u8) !void {
        var send_ready = try self.allocator.create(SendReady);
        send_ready.* = SendReady.init(hdr, body);
        self.send_queue.push(send_ready);

        while (!send_ready.notification.isDone() and !self.shutdown_notification.isDone()) {
            std.time.sleep(10 * std.time.ms_per_s);
        }

        if (self.shutdown_notification.isDone()) {
            return Error.SessionShutdown;
        }

        self.allocator.destroy(send_ready);
    }
};

const PingNotification = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
};
