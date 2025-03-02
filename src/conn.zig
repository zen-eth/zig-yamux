const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;

/// GenericConn provides a generic connection interface that implements read, write, and close methods
/// It follows the pattern of GenericReader and GenericWriter in the standard library
pub fn GenericConn(
    comptime Context: type,
    comptime ReadE: type,
    comptime WriteE: type,
    comptime readFn: fn (context: Context, buffer: []u8) ReadE!usize,
    comptime writeFn: fn (context: Context, buffer: []const u8) WriteE!usize,
    comptime closeFn: fn (context: Context) void,
) type {
    return struct {
        context: Context,

        pub const ReadError = ReadE;
        pub const WriteError = WriteE;

        const Self = @This();

        pub inline fn read(self: Self, buffer: []u8) ReadError!usize {
            return readFn(self.context, buffer);
        }

        pub inline fn write(self: Self, buffer: []const u8) WriteError!usize {
            return writeFn(self.context, buffer);
        }

        pub inline fn close(self: Self) void {
            return closeFn(self.context);
        }

        pub inline fn reader(self: Self) std.io.GenericReader(
            Context,
            ReadError,
            readFn,
        ) {
            return .{ .context = self.context };
        }

        pub inline fn writer(self: Self) std.io.GenericWriter(
            Context,
            WriteError,
            writeFn,
        ) {
            return .{ .context = self.context };
        }

        pub inline fn any(self: *const Self) AnyConn {
            return .{
                .context = @ptrCast(&self.context),
                .readFn = typeErasedReadFn,
                .writeFn = typeErasedWriteFn,
                .closeFn = typeErasedCloseFn,
            };
        }

        fn typeErasedReadFn(context: *const anyopaque, buffer: []u8) anyerror!usize {
            const ptr: *const Context = @alignCast(@ptrCast(context));
            return readFn(ptr.*, buffer);
        }

        fn typeErasedWriteFn(context: *const anyopaque, buffer: []const u8) anyerror!usize {
            const ptr: *const Context = @alignCast(@ptrCast(context));
            return writeFn(ptr.*, buffer);
        }

        fn typeErasedCloseFn(context: *const anyopaque) void {
            const ptr: *const Context = @alignCast(@ptrCast(context));
            return closeFn(ptr.*);
        }
    };
}

/// AnyConn provides a type-erased interface for any connection that can read, write, and close
pub const AnyConn = struct {
    context: *const anyopaque,
    readFn: *const fn (context: *const anyopaque, buffer: []u8) anyerror!usize,
    writeFn: *const fn (context: *const anyopaque, buffer: []const u8) anyerror!usize,
    closeFn: *const fn (context: *const anyopaque) void,

    const Self = @This();
    pub const Error = anyerror;

    pub fn read(self: Self, buffer: []u8) Error!usize {
        return self.readFn(self.context, buffer);
    }

    pub fn write(self: Self, buffer: []const u8) Error!usize {
        return self.writeFn(self.context, buffer);
    }

    pub fn close(self: Self) Error!void {
        return self.closeFn(self.context);
    }

    pub fn reader(self: Self) std.io.AnyReader {
        return .{
            .context = self.context,
            .readFn = self.readFn,
        };
    }

    pub fn writer(self: Self) std.io.AnyWriter {
        return .{
            .context = self.context,
            .writeFn = self.writeFn,
        };
    }
};

/// Adapter for std.net.Stream
pub fn netStreamToConn(stream: std.net.Stream) GenericConn(
    std.net.Stream,
    std.net.Stream.ReadError,
    std.net.Stream.WriteError,
    netStreamRead,
    netStreamWrite,
    netStreamClose,
) {
    return .{ .context = stream };
}

fn netStreamRead(stream: std.net.Stream, buffer: []u8) std.net.Stream.ReadError!usize {
    return stream.read(buffer);
}

fn netStreamWrite(stream: std.net.Stream, buffer: []const u8) std.net.Stream.WriteError!usize {
    return stream.write(buffer);
}

fn netStreamClose(stream: std.net.Stream) void {
    stream.close();
}

// /// Shared structure for thread communication
// const ServerContext = struct {
//     address: net.Address,
//     socket: posix.socket_t,
//     should_exit: std.atomic.Value(bool),
// };
//
// /// Echo server that uses an existing bound server
// fn runEchoServer(context: *ServerContext) !void {
//     while (!context.should_exit.load(.acquire)) {
//         var client_addr: net.Address = undefined;
//         var addr_len: posix.socklen_t = @sizeOf(net.Address);
//
//         const client_socket = posix.accept(
//             context.socket,
//             &client_addr.any,
//             &addr_len,
//             0,
//         ) catch |err| {
//             if (err == error.WouldBlock) {
//                 std.time.sleep(10 * std.time.ns_per_ms);
//                 continue;
//             }
//             return err;
//         };
//
//         var client_stream = net.Stream{ .handle = client_socket };
//         defer client_stream.close();
//
//         var buffer: [1024]u8 = undefined;
//         while (true) {
//             const bytes_read = client_stream.read(&buffer) catch break;
//             if (bytes_read == 0) break; // Client closed connection
//
//             _ = client_stream.write(buffer[0..bytes_read]) catch break;
//         }
//     }
// }
//
// test "GenericConn with std.net.Stream" {
//     // Set up a TCP server on localhost with random port
//     const localhost = try net.Address.parseIp("127.0.0.1", 0);
//
//     // Create a socket using posix API
//     const sock = try posix.socket(
//         localhost.any.family,
//         posix.SOCK.STREAM,
//         posix.IPPROTO.TCP
//     );
//
//     // Enable address reuse
//     try posix.setsockopt(
//         sock,
//         posix.SOL.SOCKET,
//         posix.SO.REUSEADDR,
//         &std.mem.toBytes(@as(c_int, 1))
//     );
//
//     // Bind and listen
//     try posix.bind(sock, &localhost.any, localhost.getOsSockLen());
//     try posix.listen(sock, 128);
//
//     // Get the assigned local address
//     var actual_addr: net.Address = undefined;
//     var addr_len: posix.socklen_t = @sizeOf(net.Address);
//     try posix.getsockname(sock, &actual_addr.any, &addr_len);
//
//     var server_context = ServerContext{
//         .address = actual_addr,
//         .socket = sock,
//         .should_exit = std.atomic.Value(bool).init(false),
//     };
//
//     // Start server in separate thread
//     const server_thread = try Thread.spawn(.{}, runEchoServer, .{&server_context});
//     defer {
//         server_context.should_exit.store(true, .release);
//         server_thread.join();
//         posix.close(sock);
//     }
//
//     // Client connection
//     var client_stream = try net.tcpConnectToAddress(actual_addr);
//     defer client_stream.close();
//
//     // Create GenericConn from std.net.Stream
//     var generic_client = netStreamToConn(client_stream);
//
//     // Basic write/read test
//     const test_message = "Hello, network stream!";
//     const bytes_written = try generic_client.write(test_message);
//     try testing.expectEqual(test_message.len, bytes_written);
//
//     // Read response
//     var read_buffer: [128]u8 = undefined;
//     const bytes_read = try generic_client.read(&read_buffer);
//
//     try testing.expectEqual(test_message.len, bytes_read);
//     try testing.expectEqualStrings(test_message, read_buffer[0..bytes_read]);
//
//     // Test AnyConn conversion
//     var any_client = generic_client.any();
//     const any_message = "AnyConn test";
//     _ = try any_client.write(any_message);
//
//     const any_read = try any_client.read(&read_buffer);
//     try testing.expectEqual(any_message.len, any_read);
//     try testing.expectEqualStrings(any_message, read_buffer[0..any_read]);
//
//     // Test reader/writer interface
//     var reader = generic_client.reader();
//     var writer = generic_client.writer();
//
//     try writer.writeAll("Line test\n");
//
//     var line_buffer: [20]u8 = undefined;
//     const line = try reader.readUntilDelimiter(&line_buffer, '\n');
//     try testing.expectEqualStrings("Line test", line);
//
//     // Clean up
//     generic_client.close();
// }

/// Shared structure for thread communication
const ServerContext = struct {
    socket: posix.socket_t,
    should_exit: std.atomic.Value(bool),
};

/// Echo server that uses an existing bound server socket
fn runEchoServer(context: *ServerContext) !void {
    while (!context.should_exit.load(.acquire)) {
        var client_addr: net.Address = undefined;
        var addr_len: posix.socklen_t = @sizeOf(net.Address);

        const client_socket = posix.accept(
            context.socket,
            &client_addr.any,
            &addr_len,
            0,
        ) catch |err| {
            if (err == error.WouldBlock) {
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }
            if (context.should_exit.load(.acquire)) return;
            return err;
        };

        // Handle client in same thread for simplicity
        handleClient(client_socket);
    }
}

fn handleClient(client_socket: posix.socket_t) void {
    var client_stream = net.Stream{ .handle = client_socket };
    defer client_stream.close(); // This will close the socket safely

    var buffer: [1024]u8 = undefined;
    while (true) {
        const bytes_read = client_stream.read(&buffer) catch break;
        if (bytes_read == 0) break; // Client closed connection

        _ = client_stream.write(buffer[0..bytes_read]) catch break;
    }
}

test "GenericConn with std.net.Stream" {
    // Set up a TCP server on localhost with random port
    const localhost = try net.Address.parseIp("127.0.0.1", 0);

    // Create a socket using posix API
    const server_socket = try posix.socket(localhost.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);

    // Ensure socket is closed at the end
    defer posix.close(server_socket);

    // Enable address reuse to avoid "address already in use" errors in tests
    try posix.setsockopt(server_socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    // Bind and listen
    try posix.bind(server_socket, &localhost.any, localhost.getOsSockLen());
    try posix.listen(server_socket, 128);

    // Get the assigned local address
    var actual_addr: net.Address = undefined;
    var addr_len: posix.socklen_t = @sizeOf(net.Address);
    try posix.getsockname(server_socket, &actual_addr.any, &addr_len);

    var server_context = ServerContext{
        .socket = server_socket,
        .should_exit = std.atomic.Value(bool).init(false),
    };

    // Start server in separate thread
    const server_thread = try Thread.spawn(.{}, runEchoServer, .{&server_context});

    // Ensure server thread is stopped and joined at the end
    defer {
        // Signal thread to exit
        server_context.should_exit.store(true, .release);
        // Allow time for the thread to notice
        std.time.sleep(10 * std.time.ns_per_ms);
        // Join thread
        server_thread.join();
    }

    // Create client connection - don't use defer close immediately
    var client_stream = try net.tcpConnectToAddress(actual_addr);

    // Block to contain the test operations
    {
        // Create GenericConn from std.net.Stream
        var generic_client = netStreamToConn(client_stream);

        // Basic write/read test
        const test_message = "Hello, network stream!";
        const bytes_written = try generic_client.write(test_message);
        try testing.expectEqual(test_message.len, bytes_written);

        // Read response
        var read_buffer: [128]u8 = undefined;
        const bytes_read = try generic_client.read(&read_buffer);

        try testing.expectEqual(test_message.len, bytes_read);
        try testing.expectEqualStrings(test_message, read_buffer[0..bytes_read]);

        // Test AnyConn conversion
        var any_client = generic_client.any();
        const any_message = "AnyConn test";
        _ = try any_client.write(any_message);

        const any_read = try any_client.read(&read_buffer);
        try testing.expectEqual(any_message.len, any_read);
        try testing.expectEqualStrings(any_message, read_buffer[0..any_read]);

        // Test reader/writer interface
        var reader = generic_client.reader();
        var writer = generic_client.writer();

        try writer.writeAll("Line test\n");

        var line_buffer: [20]u8 = undefined;
        const line = try reader.readUntilDelimiter(&line_buffer, '\n');
        try testing.expectEqualStrings("Line test", line);
    }

    // Close client stream after all tests
    client_stream.close();
}
