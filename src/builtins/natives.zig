const std = @import("std");
const obj = @import("../object.zig");
const value = @import("../value.zig");
const Value = @import("../value.zig").Value;
const vm = @import("../vm.zig");
const mem = @import("../memory.zig");

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

pub fn inputNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        vm.runtimeError("Message must be string.", .{});
        return Value.makeError();
    }
    const stdout = std.io.getStdOut().writer();
    const stdin = std.io.getStdIn().reader();
    stdout.print("{s}", .{args[0].asString().chars}) catch {
        return Value.makeNull();
    };
    // defer stdout.print("\n", .{}) catch {};
    var buf = mem.allocator.alloc(u8, 1024) catch {
        return Value.makeNull();
    };
    defer mem.allocator.free(buf);
    if (stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch null) |input| {
        const chars: []u8 = mem.allocator.alloc(u8, input.len) catch {
            return Value.makeNull();
        };
        // defer mem.allocator.free(chars);
        // vm.vm.bytes_allocated += @sizeOf(u8) * chars.len;
        for (0..input.len) |i| {
            chars[i] = input[i];
        }
        return Value.makeObj(@ptrCast(obj.ObjString.take(chars, input.len) catch {
            return Value.makeNull();
        }));
    }
    return Value.makeNull();
}

pub fn numberNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        vm.runtimeError("Input must be a string.", .{});
        return Value.makeError();
    }
    const input = args[0].asString();
    const number = std.fmt.parseFloat(f64, input.chars) catch {
        vm.runtimeError("Unable to parse number from input.", .{});
        return Value.makeError();
    };
    return Value.makeNumber(number);
}
