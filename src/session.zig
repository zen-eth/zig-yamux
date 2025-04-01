const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;
const conn = @import("conn.zig");
const AnyConn = conn.AnyConn;
const Config = @import("Config.zig");
const testing = std.testing;
const ThreadPool = std.Thread.Pool;
const aio = @import("aio");

pub const Error = error{ SessionShutdown, ConnectionWriteTimeout, OutOfMemory };
const SendQueue = std.SinglyLinkedList(*SendReady);

pub const SendReady = struct {
    hdr: []u8,
    body: ?[]u8,
    sent_completion: std.Thread.ResetEvent,
    free_completion: std.Thread.ResetEvent,
    err_rwlock: std.Thread.RwLock,
    err: ?anyerror,
    allocator: Allocator,

    const Self = @This();

    pub fn init(hdr: []u8, body: ?[]u8, allocator: Allocator) !SendReady {
        // Since the body will be reused by the caller, we need to copy it.
        // This is possibly not the best way to do this, but it is the simplest.
        // We could also use a pool of buffers to avoid copying the body later.
        const hdr_copy = try allocator.dupe(u8, hdr);
        var body_copy: ?[]u8 = null;
        if (body) |b| {
            body_copy = try allocator.dupe(u8, b);
        }

        return .{
            .hdr = hdr_copy,
            .body = body_copy,
            .sent_completion = .{},
            .free_completion = .{},
            .err_rwlock = .{},
            .err = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.hdr);

        if (self.body) |body| {
            self.allocator.free(body);
        }
    }

    pub fn setError(self: *Self, err: anyerror) void {
        self.err_rwlock.lock();
        defer self.err_rwlock.unlock();

        if (self.err == null) {
            self.err = err;
        }
    }

    pub fn getErr(self: *Self) ?anyerror {
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
    conn: AnyConn,

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
    syn_semaphore: std.Thread.Semaphore = .{},

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

    scheduler: *ThreadPool,

    pub fn init(allocator: Allocator, config: *Config, any_conn: AnyConn, s: *Session, scheduler: *ThreadPool) !void {
        s.* = Session{
            .config = config,
            .conn = any_conn,
            .buf_read = any_conn.reader(),
            .allocator = allocator,
            .accept_queue = std.fifo.LinearFifo(*Stream, .Dynamic).init(allocator),
            .send_queue = .{},
            .pings = std.AutoHashMap(u32, std.Thread.ResetEvent).init(allocator),
            .streams = std.AutoHashMap(u32, *Stream).init(allocator),
            .inflight = std.AutoHashMap(u32, void).init(allocator),
            .scheduler = scheduler,
        };

        try s.scheduler.spawn(sendLoopInThread, .{s});
    }

    pub fn deinit(self: *Session) void {
        self.streams.deinit();
        self.inflight.deinit();
        self.pings.deinit();
        self.accept_queue.deinit();
        self.send_queue_sync.mutex.lock();
        while (self.send_queue.popFirst()) |node| {
            const send_ready = node.data;
            self.allocator.destroy(send_ready);
            self.allocator.destroy(node);
        }
    }

    pub fn sendAndWait(self: *Session, hdr: []u8, body: ?[]u8) !void {
        const start_time = std.time.nanoTimestamp();
        const send_ready = try self.allocator.create(SendReady);
        send_ready.* = try SendReady.init(hdr, body, self.allocator);

        try self.waitEnqueue(send_ready, self.config.connection_write_timeout);

        const elapsed_time: i128 = std.time.nanoTimestamp() - start_time;
        try self.waitSent(send_ready, self.config.connection_write_timeout - @as(u64, @intCast(elapsed_time)));
    }

    pub fn send(self: *Session, hdr: []u8, body: ?[]u8) Error!void {
        const send_ready = try self.allocator.create(SendReady);
        send_ready.* = try SendReady.init(hdr, body, self.allocator);

        try self.waitEnqueue(send_ready, self.config.connection_write_timeout);
    }

    pub fn sendLoopInThread(self: *Session) void {
        self.sendLoop() catch |err| {
            std.debug.print("sendLoopInThread error: {}\n", .{err});
        };
    }

    pub fn sendLoop(self: *Session) !void {
        while (!self.shutdown_notification.isSet()) {
            self.send_queue_sync.mutex.lock();
            while (self.send_queue_size == 0) {
                // Wait for a notification that the queue is not empty
                self.send_queue_sync.not_empty_cond.wait(&self.send_queue_sync.mutex);
                if (self.shutdown_notification.isSet()) {
                    self.send_queue_sync.mutex.unlock();
                    return;
                }
            }
            const node = self.send_queue.popFirst().?;
            defer self.allocator.destroy(node);
            const send_ready = node.data;
            self.send_queue_size -= 1;
            self.send_queue_sync.not_full_cond.broadcast();
            self.send_queue_sync.mutex.unlock();

            // Check if the session is shutting down
            if (self.shutdown_notification.isSet()) {
                send_ready.sent_completion.set();
                send_ready.free_completion.wait();
                send_ready.deinit();
                self.allocator.destroy(send_ready);
                return;
            }

            _ = self.conn.write(send_ready.hdr) catch |err| {
                std.debug.print("sendLoop: write error: {}\n", .{err});
                send_ready.setError(err);
                send_ready.sent_completion.set();
                send_ready.free_completion.wait();
                send_ready.deinit();
                self.allocator.destroy(send_ready);
                return err;
            };

            if (send_ready.body) |body| {
                _ = self.conn.write(body) catch |err| {
                    std.debug.print("sendLoop: write error: {}\n", .{err});
                    send_ready.setError(err);
                    send_ready.sent_completion.set();
                    send_ready.free_completion.wait();
                    send_ready.deinit();
                    self.allocator.destroy(send_ready);
                    return err;
                };
            }

            send_ready.sent_completion.set();
            send_ready.free_completion.wait();
            send_ready.deinit();
            self.allocator.destroy(send_ready);
        }
    }

    pub fn close(self: *Session) void {
        self.shutdown_notification.set();
        self.send_queue_sync.mutex.lock();
        self.send_queue_sync.not_empty_cond.broadcast();
        self.send_queue_sync.not_full_cond.broadcast();
        self.send_queue_sync.mutex.unlock();
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

    fn waitSent(self: *Session, send_ready: *SendReady, timeout_ns: u64) !void {
        send_ready.sent_completion.timedWait(timeout_ns) catch {
            send_ready.free_completion.set();
            if (self.shutdown_notification.isSet()) {
                return Error.SessionShutdown;
            }
            return Error.ConnectionWriteTimeout;
        };

        if (self.shutdown_notification.isSet()) {
            send_ready.free_completion.set();
            return Error.SessionShutdown;
        }

        if (send_ready.getErr()) |err| {
            send_ready.free_completion.set();
            return err;
        }

        send_ready.free_completion.set();
    }
};

test "Session.send using PipeConn" {
    var pipes = try conn.createPipeConnPair();
    defer {
        pipes.client.deinit();
        pipes.server.deinit();
    }

    const client_conn = pipes.client.conn().any();

    // Create a basic config for testing
    var config = Config.defaultConfig();

    // Create a session using the client connection
    var session: Session = undefined;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = testing.allocator });
    defer pool.deinit();

    try Session.init(testing.allocator, &config, client_conn, &session, &pool);
    defer session.deinit();

    // Prepare test data
    const header = try testing.allocator.dupe(u8, "test header");
    defer testing.allocator.free(header);

    const body = try testing.allocator.dupe(u8, "test body content");
    defer testing.allocator.free(body);

    // Send the data
    try session.sendAndWait(header, body);

    // Give time for sending to complete
    std.time.sleep(10 * std.time.ns_per_ms);

    // Read from the server side of the pipe
    var buffer: [256]u8 = undefined;
    const bytes_read = try pipes.server.read(&buffer);

    // In a real test, you'd verify the protocol format here
    // For now, just check that we received some data
    try testing.expect(bytes_read > 0);

    // Check the received data
    const received_data = buffer[0..bytes_read];
    try testing.expectEqualSlices(u8, header, received_data[0..header.len]);
    try testing.expectEqualSlices(u8, body, received_data[header.len..bytes_read]);

    std.time.sleep(1000 * std.time.ms_per_s);
    // Signal shutdown to stop the send thread
    session.close();
    // try pool.run(.cancel);
}
