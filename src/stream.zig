const std = @import("std");
const frame = @import("frame.zig");
const conn = @import("conn.zig");

/// StreamError represents errors that can occur with streams
pub const StreamError = error{
    StreamClosed,
    StreamReset,
    Timeout,
    ReceiveWindowExceeded,
    InvalidState,
    BufferFull,
};

/// Stream represents a logical bi-directional stream within a Session
pub const Stream = struct {
    /// Stream identifier
    id: u32,

    /// Parent session (opaque pointer)
    session: *const anyopaque,

    /// Window sizes
    send_window: u32,
    recv_window: u32,
    max_recv_window: u32,
    max_send_queue_size: u32,

    /// State flags
    is_closed_locally: bool,
    is_closed_remotely: bool,
    is_reset: bool,
    remote_reset: bool,
    opened: bool,
    is_sending: bool,

    /// Buffers for data
    recv_queue: std.ArrayList(u8),
    send_queue: std.ArrayList(SendQueueItem),

    /// Synchronization
    state_mutex: std.Thread.Mutex,
    send_mutex: std.Thread.Mutex,

    /// Notification events
    recv_notify: std.Thread.ResetEvent,
    send_notify: std.Thread.ResetEvent,

    /// Time tracking for dynamic window sizing
    epoch_start: i64,

    /// Deadlines
    read_deadline: i64,
    write_deadline: i64,

    /// Allocator
    allocator: std.mem.Allocator,

    /// Session callbacks
    callbacks: SessionCallbacks,

    const SendQueueItem = struct {
        data: []const u8,
        sent: usize,
        completion: *std.Thread.ResetEvent,
    };

    /// Session callback interface
    pub const SessionCallbacks = struct {
        sendMsg: *const fn (
            session: *const anyopaque,
            header: frame.Header,
            data: []const u8,
            deadline: ?i64,
        ) anyerror!void,
        closeStream: *const fn (session: *const anyopaque, id: u32) void,
        getRTT: *const fn (session: *const anyopaque) i64,
    };

    /// Create a new stream
    pub fn init(
        id: u32,
        session: *const anyopaque,
        allocator: std.mem.Allocator,
        initial_window: u32,
        max_window: u32,
        max_send_queue_size: u32,
        callbacks: SessionCallbacks,
    ) !*Stream {
        const self = try allocator.create(Stream);
        errdefer allocator.destroy(self);

        self.* = .{
            .id = id,
            .session = session,
            .send_window = initial_window,
            .recv_window = initial_window,
            .max_recv_window = max_window,
            .max_send_queue_size = max_send_queue_size,
            .is_closed_locally = false,
            .is_closed_remotely = false,
            .is_reset = false,
            .remote_reset = false,
            .opened = false,
            .is_sending = false,
            .recv_queue = std.ArrayList(u8).init(allocator),
            .send_queue = std.ArrayList(SendQueueItem).init(allocator),
            .state_mutex = std.Thread.Mutex{},
            .send_mutex = std.Thread.Mutex{},
            .recv_notify = std.Thread.ResetEvent{},
            .send_notify = std.Thread.ResetEvent{},
            .epoch_start = std.time.milliTimestamp(),
            .read_deadline = 0,
            .write_deadline = 0,
            .allocator = allocator,
            .callbacks = callbacks,
        };

        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Stream) void {
        self.recv_queue.deinit();

        // Free any queued send data
        for (self.send_queue.items) |item| {
            self.allocator.destroy(item.completion);
        }
        self.send_queue.deinit();

        self.allocator.destroy(self);
    }

    /// Get stream ID
    pub fn getID(self: *Stream) u32 {
        return self.id;
    }

    /// Read data from the stream
    pub fn read(self: *Stream, buffer: []u8) !usize {
        if (self.is_reset) {
            if (self.remote_reset) {
                return error.StreamReset;
            } else {
                return error.StreamClosed;
            }
        }

        if (self.is_closed_remotely and self.recv_queue.items.len == 0) {
            return 0; // EOF
        }

        if (self.recv_queue.items.len == 0) {
            // Wait for data or connection close
            self.recv_notify.reset();

            const deadline = self.read_deadline;
            const has_timeout = deadline > 0;

            if (has_timeout) {
                const now = std.time.milliTimestamp();
                if (now >= deadline) return error.Timeout;

                const timeout_ms = @as(u64, @intCast(deadline - now));
                self.recv_notify.timedWait(timeout_ms) catch |err| {
                    if (err == error.Timeout) {
                        return error.Timeout;
                    }
                    return err;
                };
            } else {
                self.recv_notify.wait();
            }

            // Check again after waiting
            if (self.is_reset) {
                if (self.remote_reset) {
                    return error.StreamReset;
                } else {
                    return error.StreamClosed;
                }
            }

            if (self.is_closed_remotely and self.recv_queue.items.len == 0) {
                return 0; // EOF
            }
        }

        // Read available data
        const to_read = @min(self.recv_queue.items.len, buffer.len);
        @memcpy(buffer[0..to_read], self.recv_queue.items[0..to_read]);

        // Remove read data from queue
        if (to_read == self.recv_queue.items.len) {
            self.recv_queue.clearRetainingCapacity();
        } else {
            const items_left = self.recv_queue.items.len - to_read;
            @memcpy(self.recv_queue.items[0..items_left], self.recv_queue.items[to_read..][0..items_left]);
            self.recv_queue.shrinkRetainingCapacity(items_left);
        }

        // Update window if needed
        try self.updateRecvWindow();

        return to_read;
    }

    /// Write data to the stream
    pub fn write(self: *Stream, buffer: []const u8) !usize {
        self.state_mutex.lock();
        const is_reset_local = self.is_reset;
        const is_closed_local = self.is_closed_locally;
        self.state_mutex.unlock();

        if (is_reset_local) return error.StreamReset;
        if (is_closed_local) return error.StreamClosed;
        if (buffer.len == 0) return 0;

        // Create a completion event
        var completion = try self.allocator.create(std.Thread.ResetEvent);
        errdefer self.allocator.destroy(completion);
        completion.* = .{};

        // Queue the data for sending
        self.send_mutex.lock();
        try self.send_queue.append(.{
            .data = buffer,
            .sent = 0,
            .completion = completion,
        });
        self.send_mutex.unlock();

        // Trigger send operation
        try self.trySend();

        // Wait for completion with timeout if applicable
        const deadline = self.write_deadline;
        if (deadline > 0) {
            const now = std.time.milliTimestamp();
            if (now >= deadline) {
                return error.Timeout;
            }

            const timeout_ms = @as(u64, @intCast(deadline - now));
            self.recv_notify.timedWait(timeout_ms) catch |err| {
                if (err == error.Timeout) {
                    return error.Timeout;
                }
                return err;
            };
        } else {
            completion.wait();
        }

        self.allocator.destroy(completion);

        return buffer.len;
    }

    /// Attempt to send queued data
    fn trySend(self: *Stream) !void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();

        if (self.is_sending) return;
        self.is_sending = true;
        defer self.is_sending = false;

        while (self.send_queue.items.len > 0) {
            if (self.send_window == 0) {
                // Wait for window update
                return;
            }

            // Get flags if any
            const flags = self.sendFlags();

            // Calculate how much we can send
            var item = &self.send_queue.items[0];
            const remaining = item.data.len - item.sent;
            const to_send = @min(remaining, self.send_window);
            const chunk = item.data[item.sent..][0..to_send];

            // Create header and send data
            const hdr = frame.Header.init(.DATA, flags, self.id, @intCast(to_send));
            try self.callbacks.sendMsg(self.session, hdr, chunk, if (self.write_deadline > 0) self.write_deadline else null);

            // Update window and sent counter
            self.send_window -= to_send;
            item.sent += to_send;

            // If we've sent everything, complete and remove from queue
            if (item.sent >= item.data.len) {
                const completion = item.completion;
                completion.set();
                _ = self.send_queue.orderedRemove(0);
            }

            // If window is exhausted, stop sending
            if (self.send_window == 0) {
                return;
            }
        }

        // If all data is sent and we're closed locally, send FIN if not already
        if (self.is_closed_locally and !self.is_reset) {
            const hdr = frame.Header.init(.DATA, frame.FrameFlags.FIN, self.id, 0);
            try self.callbacks.sendMsg(self.session, hdr, &[_]u8{}, if (self.write_deadline > 0) self.write_deadline else null);
        }
    }

    /// Get flags based on current stream state
    fn sendFlags(self: *Stream) u16 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        var flags: u16 = 0;

        if (self.is_closed_locally and self.send_queue.items.len == 0) {
            flags |= frame.FrameFlags.FIN;
        }

        if (self.is_reset) {
            flags |= frame.FrameFlags.RST;
        }

        return flags;
    }

    /// Update receive window
    fn updateRecvWindow(self: *Stream) !void {
        self.state_mutex.lock();
        const current_used = self.recv_queue.items.len;
        const delta = self.max_recv_window - self.recv_window - current_used;
        const flags = self.sendFlags();
        self.state_mutex.unlock();

        // Only send window update if significant space is now available
        if (delta < self.max_recv_window / 2 and flags == 0) {
            return;
        }

        self.recv_window += @as(u32, @intCast(delta));
        // Send window update frame
        const hdr = frame.Header.init(.WINDOW_UPDATE, flags, self.id, @intCast(delta));
        try self.callbacks.sendMsg(self.session, hdr, &[_]u8{}, if (self.write_deadline > 0) self.write_deadline else null);
    }

    /// Receive data from remote
    pub fn receiveData(self: *Stream, data: []const u8) !void {
        if (self.is_reset) {
            return error.StreamReset;
        }

        // Check if data would exceed window
        if (self.recv_queue.items.len + data.len > self.max_recv_window) {
            return error.ReceiveWindowExceeded;
        }

        // Add data to queue
        try self.recv_queue.appendSlice(data);

        // Reduce receive window
        self.recv_window -= @intCast(data.len);

        // Notify waiting readers
        self.recv_notify.set();
    }

    /// Handle window update from remote
    pub fn windowUpdate(self: *Stream, delta: u32) void {
        self.send_window += delta;
        self.send_notify.set();

        // Try to send pending data
        self.trySend() catch {};
    }

    /// Close the stream
    pub fn close(self: *Stream) !void {
        self.state_mutex.lock();
        if (self.is_closed_locally) {
            self.state_mutex.unlock();
            return;
        }
        self.is_closed_locally = true;
        self.state_mutex.unlock();

        // If send queue is empty, send FIN immediately
        self.send_mutex.lock();
        const queue_empty = self.send_queue.items.len == 0;
        self.send_mutex.unlock();

        if (queue_empty and !self.is_reset) {
            const hdr = frame.Header.init(.DATA, frame.FrameFlags.FIN, self.id, 0);
            try self.callbacks.sendMsg(self.session, hdr, &[_]u8{}, if (self.write_deadline > 0) self.write_deadline else null);
        }

        // Notify session the stream is closing
        self.callbacks.closeStream(self.session, self.id);
    }

    /// Reset the stream
    pub fn reset(self: *Stream) !void {
        self.state_mutex.lock();
        if (self.is_reset) {
            self.state_mutex.unlock();
            return;
        }
        self.is_reset = true;
        self.is_closed_locally = true;
        self.state_mutex.unlock();

        // Send RST frame
        const hdr = frame.Header.init(.DATA, frame.FrameFlags.RST, self.id, 0);
        try self.callbacks.sendMsg(self.session, hdr, &[_]u8{}, if (self.write_deadline > 0) self.write_deadline else null);

        // Notify waiting operations
        self.recv_notify.set();
        self.send_notify.set();

        // Clear send queue and cancel pending operations
        self.send_mutex.lock();
        for (self.send_queue.items) |item| {
            item.completion.set();
        }
        self.send_queue.clearAndFree();
        self.send_mutex.unlock();

        // Notify session
        self.callbacks.closeStream(self.session, self.id);
    }

    /// Process received frame flags
    pub fn processFlags(self: *Stream, flags: u16) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        if ((flags & frame.FrameFlags.RST) != 0) {
            self.remote_reset = true;
            self.is_reset = true;
            self.recv_notify.set();
            self.send_notify.set();
        }

        if ((flags & frame.FrameFlags.FIN) != 0) {
            self.is_closed_remotely = true;
            self.recv_notify.set();
        }

        if ((flags & frame.FrameFlags.SYN) != 0) {
            // Handle SYN flag
        }

        if ((flags & frame.FrameFlags.ACK) != 0) {
            // Handle ACK flag
        }
    }

    /// Set read deadline
    pub fn setReadDeadline(self: *Stream, deadline: i64) void {
        self.read_deadline = deadline;
    }

    /// Set write deadline
    pub fn setWriteDeadline(self: *Stream, deadline: i64) void {
        self.write_deadline = deadline;
    }

    /// Set deadline for both read and write
    pub fn setDeadline(self: *Stream, deadline: i64) void {
        self.read_deadline = deadline;
        self.write_deadline = deadline;
    }

    /// Open the stream by sending a window update with SYN or ACK flag
    pub fn open(self: *Stream) !void {
        if (self.opened) return;
        self.opened = true;

        const flags: u16 = if (self.id % 2 == 1) frame.FrameFlags.SYN else frame.FrameFlags.ACK;
        const delta = @max(self.max_recv_window - self.recv_window, 0);

        const hdr = frame.Header.init(.WINDOW_UPDATE, flags, self.id, @intCast(delta));
        try self.callbacks.sendMsg(self.session, hdr, &[_]u8{}, if (self.write_deadline > 0) self.write_deadline else null);
    }
};
