const std = @import("std");
const Allocator = std.mem.Allocator;
const LinearFifo = std.fifo.LinearFifo;
const frame = @import("frame.zig");
const session = @import("session.zig");
const Config = @import("Config.zig");

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
    SessionShutdown,
};

pub const Stream = struct {
    recv_window: u32,
    send_window: std.atomic.Value(u32),

    id: u32,
    session: *session.Session,

    state: StreamState,
    state_mutex: std.Thread.Mutex,

    recv_buf: ?*LinearFifo(u8, .Dynamic),
    recv_mutex: std.Thread.Mutex,

    control_hdr: []u8,
    control_err: ?Error,
    control_mutex: std.Thread.Mutex,

    send_hdr: []u8,
    send_err: ?Error,
    send_mutex: std.Thread.Mutex,

    // Notification channels implemented with condition variables
    recv_notify: struct {
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
        signaled: bool,
    },

    send_notify: struct {
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
        signaled: bool,
    },

    read_deadline: std.atomic.Value(i64),
    write_deadline: std.atomic.Value(i64),

    // For establishment notification
    establish_notify: struct {
        mutex: std.Thread.Mutex,
        cond: std.Thread.Condition,
        signaled: bool,
    },

    // Set with state_mutex held to honor the StreamCloseTimeout
    close_timer: ?std.time.Timer = null,

    allocator: std.mem.Allocator,

    pub fn init(s: *session.Session, id: u32, state: StreamState, stream: *Stream, alloc: std.mem.Allocator) void {
        const control_hdr = [_]u8{0} ** frame.Header.SIZE;
        var send_hdr = [_]u8{0} ** frame.Header.SIZE;
        stream.* = .{
            .id = id,
            .session = s,
            .state = state,
            .state_mutex = .{},
            .recv_buf = null,
            .recv_mutex = .{},
            .control_hdr = &control_hdr,
            .control_err = null,
            .control_mutex = .{},
            .send_hdr = &send_hdr,
            .send_err = null,
            .send_mutex = .{},
            .recv_window = Config.initial_stream_window,
            .send_window = std.atomic.Value(u32).init(Config.initial_stream_window),
            .recv_notify = .{
                .mutex = .{},
                .cond = .{},
                .signaled = false,
            },
            .send_notify = .{
                .mutex = .{},
                .cond = .{},
                .signaled = false,
            },
            .establish = .{
                .mutex = .{},
                .cond = .{},
                .signaled = false,
            },
            .read_deadline = std.atomic.Value(i64).init(0),
            .write_deadline = std.atomic.Value(i64).init(0),
            .allocator = alloc,
        };
    }

    /// Reads data from the stream into the provided buffer
    /// Returns the number of bytes read or an error
    pub fn read(self: *Stream, buf: []u8) !usize {
        // Notify receivers when done
        defer {
            self.recv_notify.mutex.lock();
            defer self.recv_notify.mutex.unlock();
            self.recv_notify.signaled = true;
            self.recv_notify.cond.broadcast();
        }

        while (true) {
            // Check if the stream is closed and there's no data buffered
            self.state_mutex.lock();
            switch (self.state) {
                .local_close => {
                    // LocalClose only prohibits further local writes
                    self.state_mutex.unlock();
                },
                .remote_close, .closed => {
                    self.recv_mutex.lock();
                    const is_empty = (self.recv_buf == null or
                        self.recv_buf.?.readableLength() == 0);
                    self.recv_mutex.unlock();

                    if (is_empty) {
                        self.state_mutex.unlock();
                        return error.EndOfStream;
                    }
                    self.state_mutex.unlock();
                },
                .reset => {
                    self.state_mutex.unlock();
                    return Error.StreamReset;
                },
                else => self.state_mutex.unlock(),
            }

            // Check if there is data available
            self.recv_mutex.lock();
            if (self.recv_buf == null or self.recv_buf.?.readableLength() == 0) {
                self.recv_mutex.unlock();

                const deadline = self.read_deadline.load(.acquire);
                const has_deadline = deadline != 0;

                if (has_deadline) {
                    const now = std.time.timestamp();
                    if (now >= deadline) {
                        return Error.ReadTimeout;
                    }

                    // Calculate timeout in seconds
                    const timeout_ns = deadline - now;

                    // Wait with timeout
                    self.recv_notify.mutex.lock();
                    if (!self.recv_notify.signaled) {
                        self.recv_notify.cond.timedWait(&self.recv_notify.mutex, @intCast(timeout_ns)) catch {
                            self.recv_notify.mutex.unlock();
                            return Error.ReadTimeout;
                        };
                    }
                    self.recv_notify.signaled = false;
                    self.recv_notify.mutex.unlock();
                } else {
                    // Wait without timeout
                    self.recv_notify.mutex.lock();
                    if (!self.recv_notify.signaled) {
                        self.recv_notify.cond.wait(&self.recv_notify.mutex);
                    }
                    self.recv_notify.signaled = false;
                    self.recv_notify.mutex.unlock();
                }

                // Continue to start of loop
                continue;
            }

            // Read any bytes
            const n = self.recv_buf.?.read(buf);
            self.recv_mutex.unlock();

            // Send a window update potentially
            self.sendWindowUpdate() catch |err| {
                // Ignore SessionShutdown errors
                if (err != Error.SessionShutdown) {
                    return err;
                }
            };

            return n;
        }
    }

    /// sendWindowUpdate potentially sends a window update enabling
    /// further writes to take place. Must be invoked with the lock.
    pub fn sendWindowUpdate(self: *Stream) !void {
        self.control_mutex.lock();
        defer self.control_mutex.unlock();

        // Determine the delta update
        const max = self.session.config.max_stream_window_size;
        var buf_len: u32 = 0;

        self.recv_mutex.lock();
        if (self.recv_buf) |buf| {
            buf_len = @intCast(buf.readableLength());
        }
        const delta = (max - buf_len) - self.recv_window;

        // Determine the flags if any
        const flags = self.sendFlags();

        // Check if we can omit the update
        if (delta < (max / 2) and flags == 0) {
            self.recv_mutex.unlock();
            return;
        }

        // Update our window
        self.recv_window += delta;
        self.recv_mutex.unlock();

        // Send the header
        const header = frame.Header.init(.WINDOW_UPDATE, flags, self.id, delta);
        try header.encode(self.control_hdr);

        if (self.session.waitForSendErr(self.control_hdr, null)) |err| {
            if (err == Error.SessionShutdown or err == Error.WriteTimeout) {
                // Message left in ready queue, header re-use is unsafe.
                // Need to allocate a new header
                var new_hdr = [_]u8{0} ** frame.Header.SIZE;

                const old_hdr = self.control_hdr;
                self.control_hdr = &new_hdr;
                self.session.allocator.free(old_hdr);
            }
            return err;
        }

        return;
    }

    /// Determines any flags that are appropriate based on the current stream state.
    /// Must be called with state_mutex held.
    fn sendFlags(self: *Stream) u16 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        var flags: u16 = 0;

        switch (self.state) {
            .init => {
                flags |= frame.FrameFlags.SYN;
                self.state = .syn_sent;
            },
            .syn_received => {
                flags |= frame.FrameFlags.ACK;
                self.state = .established;
            },
            else => {},
        }

        return flags;
    }
};
