const std = @import("std");
const Value = @import("value.zig").Value;

pub fn clockNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count; // autofix
    _ = args; // autofix
    return Value.makeNumber(@as(f64, @floatFromInt(std.time.timestamp())));
}
