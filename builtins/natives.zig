const std = @import("std");
const obj = @import("../object.zig");
const value = @import("../value.zig");
const Value = @import("../value.zig").Value;
const vm = @import("../vm.zig");

pub fn clockNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count; // autofix
    _ = args; // autofix
    return Value.makeNumber(@as(f64, @floatFromInt(std.time.timestamp())));
}

pub fn clockMilliNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count; // autofix
    _ = args; // autofix
    return Value.makeNumber(@as(f64, @floatFromInt(std.time.milliTimestamp())));
}

pub fn tableCreate(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    _ = args;
    const table = obj.ObjTable.init() catch {
        return Value.makeNull();
    };
    return Value.makeObj(@ptrCast(table));
}

pub fn assert(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!value.valuesEqual(args[0], args[1])) {
        vm.runtimeError("Assertion failure.", .{});
        return Value.makeError();
    }
    return Value.makeNull();
}
