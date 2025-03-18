const std = @import("std");
const testing = std.testing;

/// A structure to manage pools of byte buffers efficiently
pub const BufferPool = struct {
    /// Each pool contains buffers of a specific power-of-2 size
    pools: [32]std.ArrayList([]u8),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},

    /// Initialize a new buffer pool
    pub fn init(allocator: std.mem.Allocator) BufferPool {
        var pool = BufferPool{
            .allocator = allocator,
            .pools = undefined,
        };

        for (&pool.pools) |*p| {
            p.* = std.ArrayList([]u8).init(allocator);
        }

        return pool;
    }

    /// Free all resources used by the buffer pool
    pub fn deinit(self: *BufferPool) void {
        for (&self.pools) |*pool| {
            for (pool.items) |buf| {
                self.allocator.free(buf);
            }
            pool.deinit();
        }
    }

    /// Calculate the index for a given size in the pool array
    fn poolIndex(size: usize) usize {
        if (size <= 1) return 0;
        return @as(usize, @intCast(std.math.log2_int_ceil(usize, size)));
    }

    /// Calculate the actual allocation size for a given requested size
    fn calcAllocSize(size: usize) usize {
        if (size <= 1) return 1;
        const idx = poolIndex(size);
        return @as(usize, 1) << @as(u5, @intCast(idx));
    }

    pub fn get(self: *BufferPool, length: usize) []u8 {
        if (length == 0) return &[_]u8{};

        // Calculate the appropriate pool index and allocation size
        const idx = poolIndex(length);
        const alloc_size = calcAllocSize(length);

        self.mutex.lock();
        defer self.mutex.unlock();

        // Check if we have a buffer of appropriate size in the pool
        if (self.pools[idx].items.len > 0) {
            const buf = self.pools[idx].pop().?;
            return buf[0..length];
        }

        var buf = self.allocator.alloc(u8, alloc_size) catch unreachable;
        return buf[0..length];
    }

    /// Return a buffer to the pool for reuse
    pub fn put(self: *BufferPool, buf: []u8) void {
        if (buf.len == 0) return;

        // We need the original allocation size to properly manage the buffer
        const alloc_size = calcAllocSize(buf.len);

        // We need to get the original allocation
        // (a slice that matches what was originally allocated)
        const ptr = buf.ptr;
        const full_buf = ptr[0..alloc_size];

        self.mutex.lock();
        defer self.mutex.unlock();

        const idx = poolIndex(buf.len);
        self.pools[idx].append(full_buf) catch {
            self.allocator.free(full_buf);
        };
    }
};

test "BufferPool get and put with exact power-of-2 sizes" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    // Test with power-of-2 sizes
    const sizes = [_]usize{ 2, 4, 8, 16, 32, 64, 128, 256 };

    for (sizes) |size| {
        const buf = pool.get(size);
        try testing.expectEqual(size, buf.len);

        if (buf.len > 0) {
            buf[0] = 0xAA;
        }

        pool.put(buf);

        const buf2 = pool.get(size);
        try testing.expectEqual(size, buf2.len);

        // Check our marker is present (buffer was reused)
        if (buf2.len > 0) {
            try testing.expectEqual(@as(u8, 0xAA), buf2[0]);
        }

        pool.put(buf2);
    }
}

test "BufferPool get and put with non-power-of-2 sizes" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    // Test with non-power-of-2 sizes
    const sizes = [_]usize{ 1, 3, 7, 10, 15, 33, 63, 100, 129, 255, 1000 };

    for (sizes) |size| {
        const buf = pool.get(size);
        try testing.expectEqual(size, buf.len);

        for (0..buf.len) |i| {
            buf[i] = @truncate(i);
        }

        pool.put(buf);

        const buf2 = pool.get(size);
        try testing.expectEqual(size, buf2.len);

        // Check buffer contents to confirm proper reuse
        for (0..buf2.len) |i| {
            try testing.expectEqual(@as(u8, @truncate(i)), buf2[i]);
        }

        pool.put(buf2);
    }
}

test "BufferPool get with mixed sizes" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    var buf1 = pool.get(10);
    try testing.expectEqual(@as(usize, 10), buf1.len);
    buf1[0] = 10;

    var buf2 = pool.get(100);
    try testing.expectEqual(@as(usize, 100), buf2.len);
    buf2[0] = 100;

    // Return the buffers in reverse order
    pool.put(buf2);
    pool.put(buf1);

    // Get them back in the same order
    const buf1_new = pool.get(10);
    const buf2_new = pool.get(100);

    try testing.expectEqual(@as(usize, 10), buf1_new.len);
    try testing.expectEqual(@as(usize, 100), buf2_new.len);
    try testing.expectEqual(@as(u8, 10), buf1_new[0]);
    try testing.expectEqual(@as(u8, 100), buf2_new[0]);

    pool.put(buf1_new);
    pool.put(buf2_new);
}

test "BufferPool write to full capacity" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    // Get a buffer and write to every position
    const size = 100;
    var buf = pool.get(size);

    for (0..size) |i| {
        buf[i] = @truncate(i);
    }

    pool.put(buf);

    // Get a new buffer and verify all positions
    const buf2 = pool.get(size);
    for (0..size) |i| {
        try testing.expectEqual(@as(u8, @truncate(i)), buf2[i]);
    }

    pool.put(buf2);
}

/// Helper function for benchmarking
fn benchmarkGet(pool: *BufferPool, iterations: usize, size: usize) !u64 {
    var timer = try std.time.Timer.start();
    const start = timer.lap();

    for (0..iterations) |_| {
        const buf = pool.get(size);
        pool.put(buf);
    }

    const end = timer.read();
    return end - start;
}

test "BufferPool benchmark get/put operations" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    const iterations = 10_000;

    const sizes = [_]usize{ 8, 64, 512, 4096, 32768 };

    std.debug.print("\n", .{});
    for (sizes) |size| {
        // Warm up the pool with some buffers
        for (0..100) |_| {
            const buf = pool.get(size);
            pool.put(buf);
        }

        // Run benchmark
        const duration_ns = try benchmarkGet(&pool, iterations, size);
        const ns_per_op = @as(f64, @floatFromInt(duration_ns)) / @as(f64, @floatFromInt(iterations));

        std.debug.print("BufferPool get/put size={d}: {d:.2} ns/op\n", .{ size, ns_per_op });
    }
}

test "BufferPool benchmark sequential operations" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    const iterations = 1000;
    const size = 4096;
    var timer = try std.time.Timer.start();

    // Preallocate array to hold buffers
    var buffers: [1000][]u8 = undefined;

    // Benchmark get operations in sequence
    const start_get = timer.lap();
    for (0..iterations) |i| {
        buffers[i] = pool.get(size);
    }
    const duration_get = timer.lap() - start_get;

    // Benchmark put operations in sequence
    const start_put = timer.lap();
    for (0..iterations) |i| {
        pool.put(buffers[i]);
    }
    const duration_put = timer.lap() - start_put;

    const ns_per_get = @as(f64, @floatFromInt(duration_get)) / @as(f64, @floatFromInt(iterations));
    const ns_per_put = @as(f64, @floatFromInt(duration_put)) / @as(f64, @floatFromInt(iterations));

    std.debug.print("\n", .{});
    std.debug.print("Sequential get size={d}: {d:.2} ns/op\n", .{ size, ns_per_get });
    std.debug.print("Sequential put size={d}: {d:.2} ns/op\n", .{ size, ns_per_put });
}

test "BufferPool benchmark reuse efficiency" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    const base_size = 1024;
    const iterations = 1000;
    var timer = try std.time.Timer.start();

    // Store allocated buffers so we can free them properly
    var cold_buffers: [1000][]u8 = undefined;

    // First, measure time with no reuse (cold pool)
    const cold_start = timer.lap();

    for (0..iterations) |i| {
        const size = base_size + (i % 200);
        const buf = pool.get(size);
        if (buf.len > 0) buf[0] = @truncate(i);
        // Store the buffer for cleanup
        cold_buffers[i] = buf;
    }

    const cold_end = timer.lap();
    const cold_duration = cold_end - cold_start;
    const cold_ns_per_op = @as(f64, @floatFromInt(cold_duration)) / @as(f64, @floatFromInt(iterations));

    // Return all buffers to the pool
    for (cold_buffers[0..iterations]) |buf| {
        pool.put(buf);
    }

    // Clear the pool to start fresh
    pool.deinit();
    pool = BufferPool.init(allocator);

    // Now warm up the pool
    for (0..iterations) |i| {
        const size = base_size + (i % 200);
        const buf = pool.get(size);
        pool.put(buf);
    }

    // Reset timer to avoid overflow
    timer = try std.time.Timer.start();
    const warm_start = timer.lap();

    for (0..iterations) |i| {
        const size = base_size + (i % 200);
        const buf = pool.get(size);
        if (buf.len > 0) buf[0] = @truncate(i);
        pool.put(buf);
    }

    const warm_end = timer.lap();
    const warm_duration = warm_end - warm_start;
    const warm_ns_per_op = @as(f64, @floatFromInt(warm_duration)) / @as(f64, @floatFromInt(iterations));

    // Calculate improvement from reuse
    const improvement = (cold_ns_per_op - warm_ns_per_op) / cold_ns_per_op * 100.0;

    std.debug.print("\n", .{});
    std.debug.print("Buffer pool performance:\n", .{});
    std.debug.print("Cold pool (no reuse): {d:.2} ns/op\n", .{cold_ns_per_op});
    std.debug.print("Warm pool (with reuse): {d:.2} ns/op\n", .{warm_ns_per_op});
    std.debug.print("Performance improvement: {d:.2}%\n", .{improvement});
}

test "BufferPool benchmark compare with direct allocation" {
    const allocator = std.testing.allocator;
    var pool = BufferPool.init(allocator);
    defer pool.deinit();

    const iterations = 1000;
    const size = 4096;
    var timer = try std.time.Timer.start();

    // Preallocate arrays to hold buffers
    var pool_buffers: [1000][]u8 = undefined;
    var direct_buffers: [1000][]u8 = undefined;

    // Benchmark direct allocations
    const start_direct = timer.lap();
    for (0..iterations) |i| {
        direct_buffers[i] = allocator.alloc(u8, size) catch unreachable;
    }
    const duration_direct = timer.lap() - start_direct;

    // Benchmark pool get operations
    const start_pool = timer.lap();
    for (0..iterations) |i| {
        pool_buffers[i] = pool.get(size);
    }
    const duration_pool = timer.lap() - start_pool;

    // Free directly allocated buffers
    for (0..iterations) |i| {
        allocator.free(direct_buffers[i]);
    }

    // Return pool buffers
    for (0..iterations) |i| {
        pool.put(pool_buffers[i]);
    }

    const ns_per_direct = @as(f64, @floatFromInt(duration_direct)) / @as(f64, @floatFromInt(iterations));
    const ns_per_pool = @as(f64, @floatFromInt(duration_pool)) / @as(f64, @floatFromInt(iterations));
    const overhead = (ns_per_pool / ns_per_direct - 1.0) * 100.0;

    std.debug.print("\n", .{});
    std.debug.print("Allocation comparison for size={d}:\n", .{size});
    std.debug.print("Direct allocation: {d:.2} ns/op\n", .{ns_per_direct});
    std.debug.print("Pool get (sequential): {d:.2} ns/op\n", .{ns_per_pool});

    if (ns_per_pool > ns_per_direct) {
        std.debug.print("Pool overhead: +{d:.2}%\n", .{overhead});
    } else {
        std.debug.print("Pool advantage: {d:.2}%\n", .{-overhead});
    }

    // Now measure full cycle (get+put vs alloc+free)
    timer = try std.time.Timer.start();

    const start_direct_cycle = timer.lap();
    for (0..iterations) |i| {
        const buf = allocator.alloc(u8, size) catch unreachable;
        if (buf.len > 0) buf[0] = @truncate(i);
        allocator.free(buf);
    }
    const duration_direct_cycle = timer.lap() - start_direct_cycle;

    const start_pool_cycle = timer.lap();
    for (0..iterations) |i| {
        const buf = pool.get(size);
        if (buf.len > 0) buf[0] = @truncate(i);
        pool.put(buf);
    }
    const duration_pool_cycle = timer.lap() - start_pool_cycle;

    const ns_per_direct_cycle = @as(f64, @floatFromInt(duration_direct_cycle)) / @as(f64, @floatFromInt(iterations));
    const ns_per_pool_cycle = @as(f64, @floatFromInt(duration_pool_cycle)) / @as(f64, @floatFromInt(iterations));
    const cycle_improvement = (ns_per_direct_cycle - ns_per_pool_cycle) / ns_per_direct_cycle * 100.0;

    std.debug.print("\n", .{});
    std.debug.print("Full cycle comparison for size={d}:\n", .{size});
    std.debug.print("Direct alloc+free: {d:.2} ns/op\n", .{ns_per_direct_cycle});
    std.debug.print("Pool get+put: {d:.2} ns/op\n", .{ns_per_pool_cycle});
    std.debug.print("Performance improvement with pool: {d:.2}%\n", .{cycle_improvement});
}
