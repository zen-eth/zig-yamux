const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;
const Conn = @import("conn.zig").AnyConn;
const Config = @import("Config.zig");
const Future = @import("future.zig").Future;
const Intrusive = @import("mpsc.zig").Intrusive;
const ThreadPool = std.Thread.Pool;
const Scheduler = @import("coro").Scheduler;

pub const Error = error{ SessionShutdown, ConnectionWriteTimeout };

pub const SendQueue = Intrusive(SendReady);

pub const SendReady = struct {
    hdr: []u8,
    body: ?[]u8,
    enqueued_completion: std.Thread.ResetEvent,
    enqueued_barrier: std.Thread.ResetEvent,
    sent_completion: std.Thread.ResetEvent,
    sent_barrier: std.Thread.ResetEvent,
    err_rwlock: std.Thread.RwLock,
    err: ?Error,
    next: ?*Self,

    const Self = @This();

    pub fn init(hdr: []u8, body: ?[]u8) SendReady {
        return .{
            .hdr = hdr,
            .body = body,
            .enqueued_completion = .{},
            .enqueued_barrier = .{},
            .sent_completion = .{},
            .sent_barrier = .{},
            .err_rwlock = .{},
            .err = null,
            .next = null,
        };
    }

    pub fn setErr(self: *Self, err: Error) void {
        self.err_rwlock.lock();
        defer self.err_rwlock.unlock();
        self.err = err;
    }

    pub fn getErr(self: *Self) ?Error {
        self.err_rwlock.lockShared();
        defer self.err_rwlock.unlockShared();
        return self.err;
    }

    pub fn notifyEnqueuedBarrier(self: *Self) void {
        self.enqueued_barrier.set();
    }

    pub fn waitEnqueuedBarrier(self: *Self) void {
        self.enqueued_barrier.wait();
    }

    pub fn notifySentBarrier(self: *Self) void {
        self.sent_barrier.set();
    }

    pub fn waitSentBarrier(self: *Self) void {
        self.sent_barrier.wait();
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

    shutdown_notification: std.Thread.ResetEvent = .{},

    scheduler: Scheduler,

    allocator: Allocator,

    pub fn waitForSend(self: *Session, hdr: []u8, body: ?[]u8) !void {
        var send_ready = try self.allocator.create(SendReady);
        send_ready.* = SendReady.init(hdr, body);

        self.send_queue.push(send_ready);

        var wait_shutdown_task = try self.scheduler.spawn(waitSessionShutdown, .{ &self.shutdown_notification, send_ready, self.config.connection_write_timeout }, .{});
        var enqueue_task = try self.scheduler.spawn(enqueueSend, .{ self, send_ready }, .{});

        send_ready.waitEnqueuedBarrier();
        if (send_ready.getErr()) |err| {
            if (!wait_shutdown_task.isComplete()) {
                wait_shutdown_task.cancel();
            }
            if (!enqueue_task.isComplete()) {
                enqueue_task.cancel();
            }
            self.allocator.destroy(send_ready);
            return err;
        }

        send_ready.waitSentBarrier();
        if (send_ready.getErr()) |err| {
            if (!wait_shutdown_task.isComplete()) {
                wait_shutdown_task.cancel();
            }
            if (!enqueue_task.isComplete()) {
                enqueue_task.cancel();
            }
            self.allocator.destroy(send_ready);
            return err;
        }

        self.allocator.destroy(send_ready);
    }

    fn waitSessionShutdown(st_completion: *std.Thread.ResetEvent, send_ready: *SendReady, timeout_ns: u64) void {
        st_completion.timedWait(timeout_ns) catch {
            send_ready.setErr(Error.ConnectionWriteTimeout);
            send_ready.notifyEnqueuedBarrier();
            send_ready.notifySentBarrier();
        };

        send_ready.setErr(Error.SessionShutdown);
        send_ready.notifyEnqueuedBarrier();
        send_ready.notifySentBarrier();
    }

    fn enqueueSend(self: *Session, send_ready: *SendReady) void {
        self.send_queue.push(send_ready);
        send_ready.notifyEnqueuedBarrier();
    }
};

const PingNotification = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
};
