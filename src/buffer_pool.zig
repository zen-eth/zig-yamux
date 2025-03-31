const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;

/// BufferPool is a pool to handle cases of reusing byte slices of varying sizes.
/// It maintains 32 internal pools, for each power of 2 in 0-31.
pub const BufferPool = struct {
    const Self = @This();
    const MAX_LENGTH = std.math.maxInt(i32);
    const POOL_COUNT = 32;

    // The struct to store in the pool
    const BufPtr = struct {
        buf: ?[]u8 = null,
    };

    allocator: Allocator,
    mutex: [POOL_COUNT]Mutex,
    pools: [POOL_COUNT]std.ArrayList(*BufPtr),
    ptr_pool: std.ArrayList(*BufPtr),
    ptr_mutex: Mutex,

    // Thread-local caches
    threadlocal var local_cache: [POOL_COUNT]?std.ArrayList(*BufPtr) = [_]?std.ArrayList(*BufPtr){null} ** POOL_COUNT;
    threadlocal var local_ptr_cache: ?std.ArrayList(*BufPtr) = null;

    /// Initialize a new BufferPool
    pub fn init(allocator: Allocator) !Self {
        var self = Self{
            .allocator = allocator,
            .mutex = [_]Mutex{.{}} ** POOL_COUNT,
            .pools = undefined,
            .ptr_pool = std.ArrayList(*BufPtr).init(allocator),
            .ptr_mutex = .{},
        };

        // Initialize all pools
        inline for (0..POOL_COUNT) |i| {
            self.pools[i] = std.ArrayList(*BufPtr).init(allocator);
        }

        return self;
    }

    /// Clean up the buffer pool
    pub fn deinit(self: *Self) void {
        // Clean up thread-local caches if they exist
        inline for (0..POOL_COUNT) |i| {
            if (local_cache[i]) |*cache| {
                for (cache.items) |ptr| {
                    if (ptr.buf) |buf| {
                        self.allocator.free(buf);
                    }
                    self.allocator.destroy(ptr);
                }
                cache.deinit();
                local_cache[i] = null;
            }
        }

        if (local_ptr_cache) |*cache| {
            for (cache.items) |ptr| {
                self.allocator.destroy(ptr);
            }
            cache.deinit();
            local_ptr_cache = null;
        }

        // Clean up main pools
        inline for (0..POOL_COUNT) |i| {
            for (self.pools[i].items) |ptr| {
                if (ptr.buf) |buf| {
                    self.allocator.free(buf);
                }
                self.allocator.destroy(ptr);
            }
            self.pools[i].deinit();
        }

        // Clean up ptr pool
        for (self.ptr_pool.items) |ptr| {
            self.allocator.destroy(ptr);
        }
        self.ptr_pool.deinit();
    }

    /// Get a thread-local cache for a specific power-of-2 size
    fn getLocalCache(self: *Self, idx: u5) !*std.ArrayList(*BufPtr) {
        if (local_cache[idx] == null) {
            local_cache[idx] = std.ArrayList(*BufPtr).init(self.allocator);
        }
        return &local_cache[idx].?;
    }

    /// Get a thread-local cache for BufPtr instances
    fn getLocalPtrCache(self: *Self) !*std.ArrayList(*BufPtr) {
        if (local_ptr_cache == null) {
            local_ptr_cache = std.ArrayList(*BufPtr).init(self.allocator);
        }
        return &local_ptr_cache.?;
    }

    /// Get a buffer of specified length from the pool or allocate a new one
    pub fn get(self: *Self, length: usize) ![]u8 {
        if (length == 0) {
            return &[_]u8{};
        }

        if (length > MAX_LENGTH) {
            return self.allocator.alloc(u8, length);
        }

        // Find the correct pool index by rounding up to next power of 2
        const idx = nextLogBase2(length);

        // Try thread-local cache first
        const cache = try self.getLocalCache(idx);
        if (cache.items.len > 0) {
            const ptr = cache.pop();
            // Non-optional pointer here

            // Extract the buffer if it exists
            const buf_opt = ptr.?.buf; // This is an optional slice, ?[]u8
            if (buf_opt != null) {
                const buf = buf_opt.?; // Unwrap the optional

                // Clear the buffer reference
                ptr.?.buf = null;

                // Return the BufPtr to pool
                const ptr_cache = try self.getLocalPtrCache();
                try ptr_cache.append(ptr);

                return buf[0..length];
            } else {
                // No buffer in this BufPtr
                const ptr_cache = try self.getLocalPtrCache();
                try ptr_cache.append(ptr);
                // Fall through to next approach
            }
        }

        // Try the shared pool
        self.mutex[idx].lock();
        defer self.mutex[idx].unlock();

        var got_buf_from_pool = false;
        var result_buf: []u8 = undefined;

        if (self.pools[idx].items.len > 0) {
            const ptr = self.pools[idx].pop();

            // Extract the buffer if it exists
            const buf_opt = ptr.buf;
            if (buf_opt != null) {
                result_buf = buf_opt.?;
                ptr.buf = null;
                got_buf_from_pool = true;

                // Return BufPtr to pool
                self.ptr_mutex.lock();
                self.ptr_pool.append(ptr) catch {
                    self.allocator.destroy(ptr);
                };
                self.ptr_mutex.unlock();
            } else {
                // No buffer in this BufPtr
                self.ptr_mutex.lock();
                self.ptr_pool.append(ptr) catch {
                    self.allocator.destroy(ptr);
                };
                self.ptr_mutex.unlock();
            }
        }

        if (got_buf_from_pool) {
            return result_buf[0..length];
        }

        // Need to allocate a new buffer
        const capacity = @as(usize, 1) << idx;
        var new_buf = try self.allocator.alloc(u8, capacity);
        return new_buf[0..length];
    }

    /// Return a buffer to the pool
    pub fn put(self: *Self, buf: []u8) !void {
        const capacity = buf.len;
        if (capacity == 0 or capacity > MAX_LENGTH) {
            // Drop buffer that's too large
            if (capacity > 0) {
                self.allocator.free(buf);
            }
            return;
        }

        // Find the correct pool index by finding the previous power of 2
        const idx = prevLogBase2(capacity);

        // Get a BufPtr to store the buffer
        var got_ptr = false;
        var ptr: *BufPtr = undefined;

        // Try local ptr cache first
        const ptr_cache = try self.getLocalPtrCache();
        if (ptr_cache.items.len > 0) {
            ptr = ptr_cache.pop();
            got_ptr = true;
        }

        // If no local ptr, try shared ptr pool
        if (!got_ptr) {
            self.ptr_mutex.lock();
            if (self.ptr_pool.items.len > 0) {
                ptr = self.ptr_pool.pop();
                got_ptr = true;
            }
            self.ptr_mutex.unlock();
        }

        // Create a new BufPtr if needed
        if (!got_ptr) {
            ptr = try self.allocator.create(BufPtr);
            ptr.* = BufPtr{};
        }

        // Store the buffer in the BufPtr
        ptr.buf = buf;

        // Add to thread-local cache
        const cache = try self.getLocalCache(idx);
        try cache.append(ptr);

        // If local cache gets too large, move some to shared pool
        if (cache.items.len > 32) { // Arbitrary threshold
            self.mutex[idx].lock();
            defer self.mutex[idx].unlock();

            const move_count = cache.items.len / 2;
            var i: usize = 0;
            while (i < move_count and cache.items.len > 0) : (i += 1) {
                try self.pools[idx].append(cache.pop());
            }
        }
    }
};

// Utility functions for power of 2 calculations

/// Calculate the next power of 2 (ceiling)
fn nextLogBase2(v: usize) u5 {
    if (v <= 1) return 0;
    const bits = @bitSizeOf(usize);
    const leading_zeros = @clz(v - 1);
    return @intCast(bits - leading_zeros);
}

/// Calculate the previous power of 2 (floor)
fn prevLogBase2(v: usize) u5 {
    if (v <= 1) return 0;
    const bits = @bitSizeOf(usize);
    const leading_zeros = @clz(v);
    const result = bits - leading_zeros - 1;
    const is_power_of_two = (v & (v - 1)) == 0;
    return @intCast(if (is_power_of_two) result else result);
}

// Global buffer pool instance
var global_buffer_pool: ?BufferPool = null;
var global_init_mutex = std.Thread.Mutex{};
var global_allocator: ?std.mem.Allocator = null;

/// Initialize the global buffer pool with the given allocator
pub fn initGlobal(allocator: std.mem.Allocator) !void {
    global_init_mutex.lock();
    defer global_init_mutex.unlock();

    if (global_buffer_pool == null) {
        global_buffer_pool = try BufferPool.init(allocator);
        global_allocator = allocator;
    }
}

/// Deinitialize the global buffer pool
pub fn deinitGlobal() void {
    global_init_mutex.lock();
    defer global_init_mutex.unlock();

    if (global_buffer_pool) |*pool| {
        pool.deinit();
        global_buffer_pool = null;
        global_allocator = null;
    }
}

/// Get a buffer from the global pool
pub fn get(length: usize) ![]u8 {
    if (global_buffer_pool) |*pool| {
        return pool.get(length);
    }

    return error.GlobalPoolNotInitialized;
}

/// Return a buffer to the global pool
pub fn put(buf: []u8) !void {
    if (global_buffer_pool) |*pool| {
        return pool.put(buf);
    }

    return error.GlobalPoolNotInitialized;
}
