const std = @import("std");
const ThreadPool = std.Thread.Pool;

pub fn Future(comptime T: type) type {
    return struct {
        err: ?anyerror = null,
        result: ?T = null,
        mutex: std.Thread.Mutex = .{},
        event: std.Thread.ResetEvent = .{},

        pub fn wait(self: *@This()) !?T {
            self.event.wait();

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.err) |err| {
                return err;
            } else {
                return self.result;
            }
        }

        pub fn timedWait(self: *@This(), timeout_ns: u64) !?T {
            try self.event.timedWait(timeout_ns);

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.err) |err| {
                return err;
            } else {
                return self.result;
            }
        }

        pub fn setError(self: *@This(), error_value: ?anyerror) void {
            self.mutex.lock();
            self.err = error_value;
            self.mutex.unlock();

            self.event.set();
        }

        pub fn setResult(self: *@This(), result_value: ?T) void {
            self.mutex.lock();
            self.result = result_value;
            self.mutex.unlock();

            self.event.set();
        }

        pub fn set(self: *@This(), error_value: ?anyerror, result_value: ?T) void {
            self.mutex.lock();
            self.err = error_value;
            self.result = result_value;
            self.mutex.unlock();

            self.event.set();
        }

        pub fn isDone(self: *@This()) bool {
            return self.event.isSet();
        }
    };
}

test "Future - basic result" {
    const allocator = std.testing.allocator;
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var future = Future(i32){};

    // Set result asynchronously
    try pool.spawn(struct {
        fn task(f: *Future(i32)) void {
            std.time.sleep(5 * std.time.ns_per_ms);
            f.setResult(42);
        }
    }.task, .{&future});

    // Wait for result
    const result = try future.wait();
    try std.testing.expectEqual(@as(i32, 42), result.?);
}

test "Future - error handling" {
    const allocator = std.testing.allocator;
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var future = Future(i32){};

    // Set error asynchronously
    try pool.spawn(struct {
        fn task(f: *Future(i32)) void {
            std.time.sleep(5 * std.time.ns_per_ms);
            f.setError(error.TestError);
        }
    }.task, .{&future});

    // Wait for result
    const result = future.wait();
    try std.testing.expectError(error.TestError, result);
}

test "Future - timed wait success" {
    const allocator = std.testing.allocator;
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var future = Future(i32){};

    // Set result asynchronously
    try pool.spawn(struct {
        fn task(f: *Future(i32)) void {
            std.time.sleep(5 * std.time.ns_per_ms);
            f.setResult(42);
        }
    }.task, .{&future});

    // Wait with sufficient timeout
    const result = try future.timedWait(100 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i32, 42), result.?);
}

test "Future - timed wait timeout" {
    var future = Future(i32){};

    // Try to wait with a short timeout, should time out
    const result = future.timedWait(5 * std.time.ns_per_ms);
    try std.testing.expectError(error.Timeout, result);
}

test "Future - isDone" {
    const allocator = std.testing.allocator;
    var pool: ThreadPool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    // Test with result
    {
        var future = Future(i32){};

        // Initially not done
        try std.testing.expect(!future.isDone());

        // Set result asynchronously
        try pool.spawn(struct {
            fn task(f: *Future(i32)) void {
                std.time.sleep(5 * std.time.ns_per_ms);
                f.setResult(42);
            }
        }.task, .{&future});

        // Wait until done
        while (!future.isDone()) {
            std.time.sleep(1 * std.time.ns_per_ms);
        }

        // Verify done status and result
        try std.testing.expect(future.isDone());
        const result = try future.wait();
        try std.testing.expectEqual(@as(i32, 42), result.?);
    }

    // Test with error
    {
        var future = Future(i32){};

        // Initially not done
        try std.testing.expect(!future.isDone());

        // Set error asynchronously
        try pool.spawn(struct {
            fn task(f: *Future(i32)) void {
                std.time.sleep(5 * std.time.ns_per_ms);
                f.setError(error.TestError);
            }
        }.task, .{&future});

        // Wait until done
        while (!future.isDone()) {
            std.time.sleep(1 * std.time.ns_per_ms);
        }

        // Verify done status and error
        try std.testing.expect(future.isDone());
        const result = future.wait();
        try std.testing.expectError(error.TestError, result);
    }
}
