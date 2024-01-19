const std = @import("std");
const mem = @import("memory.zig");

const stdout = std.io.getStdOut().writer();

pub const Value = struct {
    as: ValueType,

    pub fn isBool(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.bool;
    }

    pub fn isNull(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.null;
    }

    pub fn isNumber(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.number;
    }

    pub fn makeBool(value: bool) Value {
        return Value{ .as = ValueType{ .bool = value } };
    }

    pub fn makeNull() Value {
        return Value{ .as = ValueType{ .null = undefined } };
    }

    pub fn makeNumber(value: f64) Value {
        return Value{ .as = ValueType{ .number = value } };
    }
};

pub const ValueTypeTag = enum {
    bool,
    number,
    null,
};

pub const ValueType = union(ValueTypeTag) {
    bool: bool,
    number: f64,
    null: void,
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
    switch (@as(ValueTypeTag, value.as)) {
        ValueTypeTag.bool => stdout.print("{any}", .{value.as.bool}) catch {},
        ValueTypeTag.null => stdout.print("null", .{}) catch {},
        ValueTypeTag.number => stdout.print("{d}", .{value.as.number}) catch {},
    }
    // std.debug.print("{d}", .{value.as.number});
}
