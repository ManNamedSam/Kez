const std = @import("std");
const mem = @import("memory.zig");

pub const Value = struct {
    value: f64,
};

pub const ValueArray = struct {
    values: std.ArrayList(Value) = std.ArrayList(Value).init(mem.allocator),
};

pub fn initValueArray(array: *ValueArray) void {
    array.values.clearAndFree();
}

pub fn writeValueArray(array: *ValueArray, value: Value) !void {
    try array.values.append(value);
}

pub fn freeValueArray(array: *ValueArray) void {
    initValueArray(array);
}

pub fn printValue(value: Value) void {
    std.debug.print("{any}", .{value.value});
}
