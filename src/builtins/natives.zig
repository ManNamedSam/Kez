const std = @import("std");
const obj = @import("../object.zig");
const value = @import("../value.zig");
const Value = @import("../value.zig").Value;
const VM = @import("../vm.zig");
const mem = @import("../memory.zig");

pub var vm: *VM.VM = undefined;
pub fn init(_vm: *VM.VM) void {
    vm = _vm;
    defineNatives();
}

fn defineNative(name: []const u8, function: obj.NativeFn) !void {
    vm.push(Value.makeObj(@ptrCast(obj.ObjString.copy(name.ptr, name.len))));
    vm.push(Value.makeObj(@ptrCast(obj.ObjNative.init(function))));
    vm.globals.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = vm.pop();
    _ = vm.pop();
}

fn defineNatives() void {
    defineNative("number", numberNative) catch {};
    defineNative("input", inputNative) catch {};
    defineNative("clock", clockNative) catch {};
    defineNative("clock_milli", clockMilliNative) catch {};
    defineNative("Table", tableCreate) catch {};
    defineNative("assert", assert) catch {};

    defineNative("File", @import("file.zig").fileNative) catch {};
}

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
    const table = obj.ObjTable.init();
    return Value.makeObj(@ptrCast(table));
}

pub fn assert(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!value.valuesEqual(args[0], args[1])) {
        return Value.makeError("Assertion failure: '{s}'' not equal to '{s}'.", .{ args[0].toString(), args[1].toString() });
    }
    return Value.makeNull();
}

pub fn inputNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        return Value.makeError("Message must be string.", .{});
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
        return Value.makeObj(@ptrCast(obj.ObjString.take(chars, input.len)));
    }
    return Value.makeNull();
}

pub fn numberNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        return Value.makeError("Input must be a string.", .{});
    }
    const input = args[0].asString();
    const number = std.fmt.parseFloat(f64, input.chars) catch {
        return Value.makeError("Unable to parse number from input.", .{});
    };
    return Value.makeNumber(number);
}
