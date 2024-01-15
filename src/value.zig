const std = @import("std");
const mem = @import("memory.zig");

pub const Value = struct {
    value: f64,
};

pub const ValueArray = struct {
    values: std.ArrayList(Value) = std.ArrayList(Value).init(mem.allocator),
};

pub fn init_value_array(array: *ValueArray) void {
    array.values.clearAndFree();
}

pub fn write_value_array(array: *ValueArray, value: Value) !void {
    try array.values.append(value);
}

pub fn free_value_array(array: *ValueArray) void {
    init_value_array(array);
}

pub fn print_value(value: Value) void {
    std.debug.print("{any}", .{value.value});
}
