const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;
const conn = @import("conn.zig");
const AnyConn = conn.AnyConn;
const Config = @import("Config.zig");
const testing = std.testing;
const ThreadPool = std.Thread.Pool;

pub const Error = error{ SessionShutdown, ConnectionWriteTimeout, OutOfMemory };
pub const SendQueue = std.SinglyLinkedList(*SendReady);

pub const SendReady = struct {
    hdr: []u8,
    body: ?[]u8,
    timeout_ns: u64,
    sent_completion: ?std.Thread.ResetEvent,
    free_completion: ?std.Thread.ResetEvent,
    err_rwlock: std.Thread.RwLock,
    err: ?anyerror,
    allocator: Allocator,

    const Self = @This();

    pub fn init(hdr: []u8, body: ?[]u8, wait_sent: bool, timeout_ns: u64, allocator: Allocator) !SendReady {
        // Since the body will be reused by the caller, we need to copy it.
        // This is possibly not the best way to do this, but it is the simplest.
        // We could also use a pool of buffers to avoid copying the body later.
        const hdr_copy = try allocator.dupe(u8, hdr);
        var body_copy: ?[]u8 = null;
        if (body) |b| {
            body_copy = try allocator.dupe(u8, b);
        }

        const sent_completion = if (wait_sent) std.Thread.ResetEvent{} else null;
        const free_completion = if (wait_sent) std.Thread.ResetEvent{} else null;
        return .{
            .hdr = hdr_copy,
            .body = body_copy,
            .sent_completion = sent_completion,
            .free_completion = free_completion,
            .err_rwlock = .{},
            .err = null,
            .timeout_ns = timeout_ns,
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
    }

    pub fn initAndStart(allocator: Allocator, config: *Config, any_conn: AnyConn, s: *Session, scheduler: *ThreadPool) !void {
        try init(allocator, config, any_conn, s, scheduler);

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
            send_ready.deinit();
            self.allocator.destroy(send_ready);
            self.allocator.destroy(node);
        }
        self.send_queue_sync.mutex.unlock();
    }

    pub fn sendAndWait(self: *Session, hdr: []u8, body: ?[]u8) !void {
        const start_time = std.time.nanoTimestamp();
        const send_ready = try self.allocator.create(SendReady);
        send_ready.* = try SendReady.init(hdr, body, true, self.config.connection_write_timeout, self.allocator);

        try self.waitEnqueue(send_ready, self.config.connection_write_timeout);

        const elapsed_time: i128 = std.time.nanoTimestamp() - start_time;
        if (self.config.connection_write_timeout <= elapsed_time) {
            return error.ConnectionWriteTimeout;
        }
        try self.waitSent(send_ready, self.config.connection_write_timeout - @as(u64, @intCast(elapsed_time)));
    }

    pub fn send(self: *Session, hdr: []u8, body: ?[]u8) Error!void {
        const send_ready = try self.allocator.create(SendReady);
        send_ready.* = try SendReady.init(hdr, body, false, self.config.connection_write_timeout, self.allocator);

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
            defer {
                send_ready.deinit();
                self.allocator.destroy(send_ready);
            }
            self.send_queue_size -= 1;
            self.send_queue_sync.not_full_cond.broadcast();
            self.send_queue_sync.mutex.unlock();

            // Check if the session is shutting down
            if (self.shutdown_notification.isSet()) {
                send_ready.setError(Error.SessionShutdown);
                if (send_ready.sent_completion) |*sent_completion| {
                    sent_completion.set();
                }
                if (send_ready.free_completion) |*free_completion| {
                    free_completion.timedWait(send_ready.timeout_ns) catch {};
                }
                return;
            }

            _ = self.conn.write(send_ready.hdr) catch |err| {
                std.debug.print("sendLoop: write error: {}\n", .{err});
                send_ready.setError(err);
                if (send_ready.sent_completion) |*sent_completion| {
                    sent_completion.set();
                }
                if (send_ready.free_completion) |*free_completion| {
                    free_completion.timedWait(send_ready.timeout_ns) catch {};
                }
                return err;
            };

            if (send_ready.body) |body| {
                _ = self.conn.write(body) catch |err| {
                    std.debug.print("sendLoop: write error: {}\n", .{err});
                    send_ready.setError(err);
                    if (send_ready.sent_completion) |*sent_completion| {
                        sent_completion.set();
                    }
                    if (send_ready.free_completion) |*free_completion| {
                        free_completion.timedWait(send_ready.timeout_ns) catch {};
                    }
                    return err;
                };
            }

            if (send_ready.sent_completion) |*sent_completion| {
                sent_completion.set();
            }
            if (send_ready.free_completion) |*free_completion| {
                free_completion.timedWait(send_ready.timeout_ns) catch {};
            }
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
                send_ready.deinit();
                self.allocator.destroy(send_ready);
                if (self.shutdown_notification.isSet()) {
                    return Error.SessionShutdown;
                }
                return Error.ConnectionWriteTimeout;
            };
            if (self.shutdown_notification.isSet()) {
                self.send_queue_sync.mutex.unlock();
                send_ready.deinit();
                self.allocator.destroy(send_ready);
                return Error.SessionShutdown;
            }
        }
        if (self.shutdown_notification.isSet()) {
            self.send_queue_sync.mutex.unlock();
            send_ready.deinit();
            self.allocator.destroy(send_ready);
            return Error.SessionShutdown;
        }

        const node = try self.allocator.create(SendQueue.Node);
        node.* = .{ .data = send_ready };
        self.send_queue.prepend(node);
        self.send_queue_size += 1;
        self.send_queue_sync.not_empty_cond.signal();
        self.send_queue_sync.mutex.unlock();
    }

    fn waitSent(self: *Session, send_ready: *SendReady, timeout_ns: u64) !void {
        send_ready.sent_completion.?.timedWait(timeout_ns) catch {
            send_ready.free_completion.?.set();
            if (self.shutdown_notification.isSet()) {
                return Error.SessionShutdown;
            }
            return Error.ConnectionWriteTimeout;
        };

        if (self.shutdown_notification.isSet()) {
            send_ready.free_completion.?.set();
            return Error.SessionShutdown;
        }

        if (send_ready.getErr()) |err| {
            send_ready.free_completion.?.set();
            return err;
        }

        send_ready.free_completion.?.set();
    }
};

test "Session.send using PipeConn" {
    var pipes = try conn.createPipeConnPair();
    defer {
        pipes.client.deinit();
        pipes.server.deinit();
    }

    const client_conn = pipes.client.conn().any();

    var config = Config.defaultConfig();

    var session: Session = undefined;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = testing.allocator });
    defer pool.deinit();

    try Session.initAndStart(testing.allocator, &config, client_conn, &session, &pool);
    defer session.deinit();

    const hdr = "test header";
    const bd = "test body content";
    for (0..3) |_| {
        const header = try testing.allocator.dupe(u8, hdr);
        defer testing.allocator.free(header);

        const body = try testing.allocator.dupe(u8, bd);
        defer testing.allocator.free(body);

        // Send the data
        try session.sendAndWait(header, body);

        // Give time for sending to complete
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    var buffer: [256]u8 = undefined;
    const bytes_read = try pipes.server.read(&buffer);

    try testing.expect(bytes_read == 84);

    const received_data = buffer[0..bytes_read];
    try testing.expectEqualSlices(u8, hdr, received_data[0..hdr.len]);
    try testing.expectEqualSlices(u8, bd, received_data[hdr.len .. hdr.len + 17]);

    session.close();
}

test "Session.send using PipeConn timeout" {
    var pipes = try conn.createPipeConnPair();
    defer {
        pipes.client.deinit();
        pipes.server.deinit();
    }

    const client_conn = pipes.client.conn().any();

    var config = Config.defaultConfig();
    config.connection_write_timeout = 1000 * std.time.ns_per_ms; // 1 second

    var session: Session = undefined;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = testing.allocator });
    defer pool.deinit();

    try Session.init(testing.allocator, &config, client_conn, &session, &pool);
    defer session.deinit();

    // Set the send queue capacity to 1 and make sendAndWait and send both timeout
    session.send_queue_sync.mutex.lock();
    session.send_queue_capacity = 1;
    session.send_queue_sync.mutex.unlock();

    const header = try testing.allocator.dupe(u8, "test header");
    defer testing.allocator.free(header);

    const body = try testing.allocator.dupe(u8, "test body content");
    defer testing.allocator.free(body);

    const res = session.sendAndWait(header, body);
    try testing.expectError(error.ConnectionWriteTimeout, res);

    const res1 = session.send(header, body);
    try testing.expectError(error.ConnectionWriteTimeout, res1);

    session.close();
}

test "Session.send after shutdown" {
    var pipes = try conn.createPipeConnPair();
    defer {
        pipes.client.deinit();
        pipes.server.deinit();
    }

    const client_conn = pipes.client.conn().any();

    var config = Config.defaultConfig();

    var session: Session = undefined;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = testing.allocator });
    defer pool.deinit();

    try Session.initAndStart(testing.allocator, &config, client_conn, &session, &pool);
    defer session.deinit();

    const header = try testing.allocator.dupe(u8, "test header");
    defer testing.allocator.free(header);

    const body = try testing.allocator.dupe(u8, "test body content");
    defer testing.allocator.free(body);

    session.close();

    // Give some time for shutdown to propagate
    std.time.sleep(10 * std.time.ns_per_ms);

    const send_result = session.sendAndWait(header, body);
    try testing.expectError(error.SessionShutdown, send_result);

    const send_result2 = session.send(header, body);
    try testing.expectError(error.SessionShutdown, send_result2);
}

test "Session shutdown during active sendAndWait operations" {
    var pipes = try conn.createPipeConnPair();
    defer {
        pipes.client.deinit();
        pipes.server.deinit();
    }

    const client_conn = pipes.client.conn().any();
    var config = Config.defaultConfig();

    var session: Session = undefined;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = testing.allocator });
    defer pool.deinit();

    try Session.initAndStart(testing.allocator, &config, client_conn, &session, &pool);
    defer session.deinit();

    var shutdown_error_detected = std.atomic.Value(bool).init(false);
    var should_exit = std.atomic.Value(bool).init(false);
    var sender_thread: std.Thread = undefined;

    // Start the sender thread that continuously calls sendAndWait
    sender_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Session, detected: *std.atomic.Value(bool), exit: *std.atomic.Value(bool)) !void {
            var i: usize = 0;
            while (!exit.load(.acquire)) {
                const header = try testing.allocator.alloc(u8, 32);
                defer testing.allocator.free(header);
                @memset(header, 'h');

                const body = try testing.allocator.alloc(u8, 64);
                defer testing.allocator.free(body);
                @memset(body, 'b');

                s.sendAndWait(header, body) catch |err| {
                    if (err == error.SessionShutdown) {
                        detected.store(true, .release);
                        return;
                    }
                    // Ignore timeout errors that might occur from pipe filling up
                    if (err != error.ConnectionWriteTimeout) {
                        std.debug.print("Unexpected error: {}\n", .{err});
                    }
                };

                i += 1;
                if (i % 10 == 0) {
                    // Give other threads a chance to run
                    std.time.sleep(1 * std.time.ns_per_ms);
                }
            }
        }
    }.run, .{ &session, &shutdown_error_detected, &should_exit });

    // Wait a bit to allow the sender to get into a rhythm
    std.time.sleep(50 * std.time.ns_per_ms);

    session.close();

    // Give the sender thread time to detect the shutdown and exit
    var timeout: usize = 0;
    while (!shutdown_error_detected.load(.acquire) and timeout < 100) {
        std.time.sleep(10 * std.time.ns_per_ms);
        timeout += 1;
    }

    should_exit.store(true, .release);
    sender_thread.join();

    try testing.expect(shutdown_error_detected.load(.acquire));
}

test "Session shutdown during active send operations" {
    var pipes = try conn.createPipeConnPair();
    defer {
        pipes.client.deinit();
        pipes.server.deinit();
    }

    const client_conn = pipes.client.conn().any();
    var config = Config.defaultConfig();

    var session: Session = undefined;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = testing.allocator });
    defer pool.deinit();

    try Session.initAndStart(testing.allocator, &config, client_conn, &session, &pool);
    defer session.deinit();

    // Create shared state between threads
    var shutdown_error_detected = std.atomic.Value(bool).init(false);
    var should_exit = std.atomic.Value(bool).init(false);
    var sender_thread: std.Thread = undefined;

    // Start the sender thread that continuously calls sendAndWait
    sender_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *Session, detected: *std.atomic.Value(bool), exit: *std.atomic.Value(bool)) !void {
            var i: usize = 0;
            while (!exit.load(.acquire)) {
                const header = try testing.allocator.alloc(u8, 32);
                defer testing.allocator.free(header);
                @memset(header, 'h');

                const body = try testing.allocator.alloc(u8, 64);
                defer testing.allocator.free(body);
                @memset(body, 'b');

                s.send(header, body) catch |err| {
                    if (err == error.SessionShutdown) {
                        detected.store(true, .release);
                        return;
                    }
                    // Ignore timeout errors that might occur from pipe filling up
                    if (err != error.ConnectionWriteTimeout) {
                        std.debug.print("Unexpected error: {}\n", .{err});
                    }
                };

                i += 1;
                if (i % 10 == 0) {
                    // Give other threads a chance to run
                    std.time.sleep(1 * std.time.ns_per_ms);
                }
            }
        }
    }.run, .{ &session, &shutdown_error_detected, &should_exit });

    // Wait a bit to allow the sender to get into a rhythm
    std.time.sleep(50 * std.time.ns_per_ms);

    session.close();

    // Give the sender thread time to detect the shutdown and exit
    var timeout: usize = 0;
    while (!shutdown_error_detected.load(.acquire) and timeout < 100) {
        std.time.sleep(10 * std.time.ns_per_ms);
        timeout += 1;
    }

    should_exit.store(true, .release);
    sender_thread.join();

    try testing.expect(shutdown_error_detected.load(.acquire));
}
