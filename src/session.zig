const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;
const Conn = @import("conn.zig").AnyConn;
const Config = @import("Config.zig");

pub const Error = error{ SessionShutdown, ConnectionWriteTimeout, OutOfMemory };
pub const SendQueue = std.SinglyLinkedList(*SendReady);

pub const SendReady = struct {
    hdr: []u8,
    body: ?[]u8,
    body_mutex: std.Thread.Mutex,
    sent_completion: std.Thread.ResetEvent,
    free_completion: std.Thread.ResetEvent,
    err_rwlock: std.Thread.RwLock,
    err: ?Error,

    const Self = @This();

    pub fn init(hdr: []u8, body: ?[]u8) SendReady {
        return .{
            .hdr = hdr,
            .body = body,
            .body_mutex = .{},
            .sent_completion = .{},
            .free_completion = .{},
            .err_rwlock = .{},
            .err = null,
        };
    }

    pub fn setError(self: *Self, err: Error) void {
        self.err_rwlock.lock();
        defer self.err_rwlock.unlock();

        if (self.err == null) {
            self.err = err;
        }
    }

    pub fn getErr(self: *Self) ?Error {
        self.err_rwlock.lockShared();
        defer self.err_rwlock.unlockShared();

        return self.err;
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
    next_stream_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    // config holds our configuration
    config: *Config,

    // conn is the underlying connection
    conn: Conn,

    // bufRead is a buffered reader
    buf_read: std.io.AnyReader,

    // pings is used to track inflight pings
    pings: std.AutoHashMap(u32, std.Thread.ResetEvent),
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

    send_queue_sync: struct {
        mutex: std.Thread.Mutex = .{},
        not_empty_cond: std.Thread.Condition = .{},
        not_full_cond: std.Thread.Condition = .{},
    } = .{},

    send_queue_size: usize = 0,

    send_queue_capacity: usize = 64,

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

    allocator: Allocator,

    pub fn sendAndWait(self: *Session, hdr: []u8, body: ?[]u8) Error!void {
        const start_time = std.time.nanoTimestamp();
        const send_ready = try self.allocator.create(SendReady);
        send_ready.* = SendReady.init(hdr, body);

        try self.waitEnqueue(send_ready, self.config.connection_write_timeout);

        const elapsed_time: i128 = std.time.nanoTimestamp() - start_time;
        try self.waitSent(body, send_ready, self.config.connection_write_timeout - @as(u64, @intCast(elapsed_time)));
    }

    pub fn send(self: *Session, hdr: []u8, body: ?[]u8) Error!void {
        const send_ready = try self.allocator.create(SendReady);
        send_ready.* = SendReady.init(hdr, body);

        try self.waitEnqueue(send_ready, self.config.connection_write_timeout);
    }

    pub fn sendLoop(self: *Session) Error!void {
        while (true) {
            self.send_queue_sync.mutex.lock();
            while (self.send_queue_size == 0) {
                // Wait for a notification that the queue is not empty
                self.send_queue_sync.not_empty_cond.wait(&self.send_queue_sync.mutex);
            }
            const send_ready = self.send_queue.popFirst().?.data;
            self.send_queue_size -= 1;
            self.send_queue_sync.not_full_cond.broadcast();
            self.send_queue_sync.mutex.unlock();

            // Check if the session is shutting down
            if (self.shutdown_notification.isSet()) {
                send_ready.sent_completion.set();
                send_ready.free_completion.wait();
                self.allocator.destroy(send_ready);
                return;
            }

            send_ready.body_mutex.lock();
            send_ready.body = null;
            send_ready.body_mutex.unlock();
            send_ready.sent_completion.set();

            send_ready.free_completion.wait();
            self.allocator.destroy(send_ready);
        }
    }

    fn waitEnqueue(self: *Session, send_ready: *SendReady, timeout_ns: u64) Error!void {
        self.send_queue_sync.mutex.lock();
        while (self.send_queue_size >= self.send_queue_capacity) {
            self.send_queue_sync.not_full_cond.timedWait(&self.send_queue_sync.mutex, timeout_ns) catch {
                self.send_queue_sync.mutex.unlock();
                self.allocator.destroy(send_ready);
                if (self.shutdown_notification.isSet()) {
                    return Error.SessionShutdown;
                }
                return Error.ConnectionWriteTimeout;
            };
            if (self.shutdown_notification.isSet()) {
                self.send_queue_sync.mutex.unlock();
                self.allocator.destroy(send_ready);
                return Error.SessionShutdown;
            }
        }
        const node = try self.allocator.create(SendQueue.Node);
        node.* = .{ .data = send_ready };
        self.send_queue.prepend(node);
        self.send_queue_size += 1;
        self.send_queue_sync.not_empty_cond.signal();
        self.send_queue_sync.mutex.unlock();
    }

    fn waitSent(self: *Session, body: ?[]u8, send_ready: *SendReady, timeout_ns: u64) Error!void {
        send_ready.sent_completion.timedWait(timeout_ns) catch {
            copyBody(body, send_ready, self.allocator);
            send_ready.free_completion.set();
            if (self.shutdown_notification.isSet()) {
                return Error.SessionShutdown;
            }
            return Error.ConnectionWriteTimeout;
        };

        if (self.shutdown_notification.isSet()) {
            copyBody(body, send_ready, self.allocator);
            send_ready.free_completion.set();
            return Error.SessionShutdown;
        }

        if (send_ready.getErr()) |err| {
            send_ready.free_completion.set();
            return err;
        }

        send_ready.free_completion.set();
    }

    fn copyBody(body: ?[]u8, send_ready: *SendReady, allocator: Allocator) void {
        if (body == null) {
            return; // A null body is ignored.
        }

        send_ready.body_mutex.lock();
        defer send_ready.body_mutex.unlock();

        if (send_ready.body == null) {
            return; // Body was already copied.
        }

        const body_len = body.?.len;
        const new_body = allocator.alloc(u8, body_len) catch unreachable;
        @memcpy(new_body, body.?);
        send_ready.body = new_body[0..body_len];
    }
};
