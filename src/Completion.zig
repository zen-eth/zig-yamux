const std = @import("std");

mutex: std.Thread.Mutex = .{},
event: std.Thread.ResetEvent = .{},

const Self = @This();

pub fn wait(self: *Self) void {
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
