const std = @import("std");
const Allocator = std.mem.Allocator;
const Stream = @import("stream.zig").Stream;

pub const SendReady = struct {
    hdr: []u8,
    body: ?[]u8 = null,
    err: std.atomic.Value(?anyerror) = std.atomic.Value(?anyerror).init(null),

    notify: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    } = .{},

    body_mutex: std.Thread.Mutex = .{}, // Protects body from unsafe reads

    pub fn init(hdr: []u8, body: ?[]u8) SendReady {
        return .{
            .hdr = hdr,
            .body = body,
        };
    }

    pub fn waitForResult(self: *SendReady) ?anyerror {
        self.notify.mutex.lock();
        defer self.notify.mutex.unlock();

        while (!self.notify.done) {
            self.notify.cond.wait(&self.notify.mutex);
        }

        return self.err.load(.Acquire);
    }

    pub fn setError(self: *SendReady, error_value: ?anyerror) void {
        self.err.store(error_value, .Release);

        self.notify.mutex.lock();
        defer self.notify.mutex.unlock();

        self.notify.done = true;
        self.notify.cond.signal();
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
    next_stream_id: std.atomic.Atomic(u32),

    // config holds our configuration
    // config: *Config,

    // conn is the underlying connection
    conn: std.io.Reader,

    // bufRead is a buffered reader
    buf_read: std.io.BufferedReader(4096, std.io.Reader),

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
    send_queue: std.fifo.LinearFifo(*SendReady, .Dynamic),

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

    // shutdown is used to safely close a session
    shutdown: bool = false,
    shutdown_err: ?anyerror = null,
    shutdown_notify: struct {
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},
        done: bool = false,
    } = .{},
    shutdown_lock: std.Thread.Mutex = .{},
    shutdown_err_lock: std.Thread.Mutex = .{},

    allocator: Allocator,

    pub fn init(allocator: Allocator, config: *Config, conn: std.io.Reader, is_client: bool) !*Session {
        var session = try allocator.create(Session);

        session.* = .{
            .next_stream_id = std.atomic.Atomic(u32).init(if (is_client) 1 else 2),
            .config = config,
            .logger = config.logger orelse Logger.init(config.log_output),
            .conn = conn,
            .buf_read = std.io.bufferedReader(conn),
            .pings = std.AutoHashMap(u32, *PingNotification).init(allocator),
            .streams = std.AutoHashMap(u32, *Stream).init(allocator),
            .inflight = std.AutoHashMap(u32, void).init(allocator),
            .syn_semaphore = Semaphore.init(config.accept_backlog),
            .accept_queue = std.fifo.LinearFifo(*Stream, .Dynamic).init(allocator),
            .send_queue = std.fifo.LinearFifo(*SendReady, .Dynamic).init(allocator),
            .allocator = allocator,
        };

        try session.accept_queue.ensureTotalCapacity(config.accept_backlog);
        try session.send_queue.ensureTotalCapacity(64);

        // Start background processing
        try std.Thread.spawn(.{}, recv, .{session});
        try std.Thread.spawn(.{}, send, .{session});

        if (config.enable_keep_alive) {
            try std.Thread.spawn(.{}, keepalive, .{session});
        }

        return session;
    }

    // Additional methods would follow...
};

const PingNotification = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    done: bool = false,
};

const Semaphore = struct {
    count: std.atomic.Atomic(usize),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn init(initial: usize) Semaphore {
        return .{
            .count = std.atomic.Atomic(usize).init(initial),
        };
    }

    pub fn acquire(self: *Semaphore) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count.load(.Acquire) == 0) {
            self.cond.wait(&self.mutex);
        }

        _ = self.count.fetchSub(1, .Release);
    }

    pub fn release(self: *Semaphore) void {
        _ = self.count.fetchAdd(1, .Release);
        self.cond.signal();
    }
};

fn recv(session: *Session) !void {
    // Implementation would go here...
}

fn send(session: *Session) !void {
    // Implementation would go here...
}

fn keepalive(session: *Session) !void {
    // Implementation would go here...
}