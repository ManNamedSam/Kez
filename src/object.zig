const std = @import("std");
const values = @import("value.zig");
const VM = @import("vm.zig");
const mem = @import("memory.zig");
const chunks = @import("chunk.zig");

const stdout = std.io.getStdOut().writer();
const allocator = @import("memory.zig").allocator;
// var vm = VM.vm;

pub const Obj = struct {
    type: ObjType,
    next: ?*Obj,
    is_marked: bool,
};

pub const ObjString = struct {
    obj: Obj,
    length: usize,
    chars: []u8,
};

pub const ObjUpvalue = struct {
    obj: Obj,
    closed: values.Value,
    location: *values.Value,
    next: ?*ObjUpvalue,
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u32,
    upvalue_count: u8,
    chunk: chunks.Chunk,
    name: ?*ObjString,
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *ObjFunction,
    upvalues: [*]*ObjUpvalue,
    upvalue_count: u8,
};

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,
};

pub const NativeFn = *const fn (arg_count: u8, args: [*]values.Value) values.Value;

pub const ObjType = enum {
    String,
    Function,
    Native,
    Closure,
    Upvalue,
};

pub fn allocateString(chars: []u8, length: usize) !*ObjString {
    const result = try VM.vm.strings.getOrPut(chars);
    if (result.found_existing) {
        // std.debug.print("found interned: {s}\n", .{result.value_ptr.*.chars});
        return result.value_ptr.*;
    }
    var string = try mem.allocateObject(ObjString, ObjType.String);
    string.obj.type = ObjType.String;
    string.length = length;
    string.chars = chars;
    result.value_ptr.* = string;
    // std.debug.print("interned string: {s}, {*}\n", .{ chars, string });
    return string;
}

pub fn newUpvalue(slot: *values.Value) !*ObjUpvalue {
    const upvalue = try mem.allocateObject(ObjUpvalue, ObjType.Upvalue);
    upvalue.closed = values.Value.makeNull();
    upvalue.location = slot;
    upvalue.next = null;
    return upvalue;
}

pub fn newFunction() !*ObjFunction {
    var function: *ObjFunction = try mem.allocateObject(ObjFunction, ObjType.Function);
    function.arity = 0;
    function.name = null;
    function.upvalue_count = 0;
    chunks.initChunk(&function.chunk) catch {};
    return function;
}

pub fn newClosure(function: *ObjFunction) !*ObjClosure {
    // const upvalues: [*]*ObjUpvalue = undefined;
    const vals = try mem.allocator.alloc(*ObjUpvalue, function.upvalue_count);
    const upvalues = vals.ptr;
    const closure: *ObjClosure = try mem.allocateObject(ObjClosure, ObjType.Closure);
    closure.function = function;
    closure.upvalues = upvalues;
    closure.upvalue_count = function.upvalue_count;
    return closure;
}

pub fn newNative(function: NativeFn) !*ObjNative {
    const native: *ObjNative = try mem.allocateObject(ObjNative, ObjType.Native);
    native.function = function;
    return native;
}

pub inline fn isObjType(value: values.Value, object_type: ObjType) bool {
    return value.isObj() and value.as.obj.type == object_type;
}

pub fn copyString(chars: [*]const u8, length: usize) !*ObjString {
    // const key: [length + 1]u8 = undefined;
    // key[length] = 0;
    // std.mem.copyForwards(u8, key, chars[0..length]);

    var heapChars = try allocator.alloc(u8, length + 1);
    heapChars[length] = 0;
    std.mem.copyForwards(u8, heapChars, chars[0..length]);
    const interned = getString(heapChars);
    // std.debug.print("copy string attempted to retrieve: {s}, found: {any}\n", .{ chars[0..length], interned });
    if (interned) |string| {
        // std.debug.print("copy string successfully retrieved: {s}\n", .{string.chars});
        defer allocator.free(heapChars);
        return string;
    }
    return (try allocateString(heapChars, length));
}

pub fn takeString(chars: []u8, length: usize) !*ObjString {
    var heapChars = try allocator.alloc(u8, length + 1);
    heapChars[length] = 0;
    std.mem.copyForwards(u8, heapChars, chars[0..length]);
    const interned = getString(heapChars);
    // std.debug.print("take string attempted to retrieve: {s}, found: {any}\n", .{ chars[0..length], interned });
    if (interned) |string| {
        // std.debug.print("take string successfully retrieved: {s}\n", .{string.chars});
        defer allocator.free(heapChars);
        return string;
    }
    return (try allocateString(chars, length));
}

fn getString(chars: []u8) ?*ObjString {
    const result = VM.vm.strings.get(chars);
    if (result != null) {
        return result.?;
    } else {
        return null;
    }
}

pub fn printObject(value: values.Value) void {
    switch (value.as.obj.type) {
        ObjType.String => {
            const string: *ObjString = @alignCast(@ptrCast(value.as.obj));
            stdout.print("{s}", .{string.chars}) catch {};
        },
        ObjType.Upvalue => {
            stdout.print("upvalue", .{}) catch {};
        },
        ObjType.Function => {
            const function: *ObjFunction = @alignCast(@ptrCast(value.as.obj));
            printFunction(function);
        },
        ObjType.Closure => {
            printFunction(value.asClosure().function);
        },
        ObjType.Native => stdout.print("<native fn>", .{}) catch {},
    }
}

fn printFunction(function: *ObjFunction) void {
    if (function.name) |name| {
        stdout.print("<fn {s}>", .{name.chars}) catch {};
    } else {
        stdout.print("<script>", .{}) catch {};
    }
}

pub fn objectsEqual(a: values.Value, b: values.Value) bool {
    if (a.as.obj.type != b.as.obj.type) return false;
    switch (a.as.obj.type) {
        ObjType.String => {
            const obj_string_a: *ObjString = @alignCast(@ptrCast(a.as.obj));
            const obj_string_b: *ObjString = @alignCast(@ptrCast(b.as.obj));
            return std.mem.eql(u8, obj_string_a.chars, obj_string_b.chars);
        },
        else => return false,
    }
}
