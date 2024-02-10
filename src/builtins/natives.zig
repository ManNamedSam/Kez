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

pub fn readFileNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        vm.runtimeError("Filepath must be a string.", .{});
        return Value.makeError();
    }
    const path: []const u8 = args[0].asString().chars;
    var file: std.fs.File = undefined;

    file = std.fs.cwd().openFile(path[0 .. path.len - 1], .{}) catch {
        _ = std.fs.cwd().createFile(path[0 .. path.len - 1], .{}) catch {
            vm.runtimeError("Unable to open file '{s}'.", .{args[0].asString().chars});
            return Value.makeError();
        };
        const string = obj.ObjString.allocate("", 0) catch {
            return Value.makeError();
        };
        return Value.makeObj(@ptrCast(string));
    };
    // if (file.)
    defer file.close();
    const file_contents = file.readToEndAlloc(mem.allocator, 100_000_000) catch {
        vm.runtimeError("Unable to read file '{s}'.", .{args[0].asString().chars});
        return Value.makeError();
    };
    const res_string = obj.ObjString.allocate(file_contents, file_contents.len) catch {
        return Value.makeError();
    };
    return Value.makeObj(@ptrCast(res_string));
}

pub fn writeFileNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        vm.runtimeError("Filepath must be a string.", .{});
        return Value.makeError();
    }
    const path: []const u8 = args[0].asString().chars;
    // var file: std.fs.File = undefined;

    var file = std.fs.cwd().createFile(path[0 .. path.len - 1], .{}) catch {
        return Value.makeError();
    };
    // if (file.)
    _ = file.write(args[1].asString().chars) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        vm.runtimeError("Unable to write to file '{s}'.", .{args[0].asString().chars});
        return Value.makeError();
    };
    defer file.close();
    return Value.makeNull();
}

pub fn appendFileNative(arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    if (!args[0].isString()) {
        vm.runtimeError("Filepath must be a string.", .{});
        return Value.makeError();
    }
    const path: []const u8 = args[0].asString().chars;
    // var file: std.fs.File = undefined;

    var file = std.fs.cwd().openFile(path[0 .. path.len - 1], .{ .mode = .read_write }) catch {
        return Value.makeError();
    };

    const contents = file.readToEndAlloc(mem.allocator, 100000000) catch {
        return Value.makeError();
    };
    _ = file.seekTo(contents.len) catch {
        return Value.makeError();
    };
    // if (file.)
    _ = file.write(args[1].asString().chars) catch |err| {
        std.debug.print("error: {any}\n", .{err});
        vm.runtimeError("Unable to write to file '{s}'.", .{args[0].asString().chars});
        return Value.makeError();
    };
    defer file.close();
    return Value.makeNull();
}
