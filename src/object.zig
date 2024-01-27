const std = @import("std");
const values = @import("value.zig");
const VM = @import("vm.zig");
const mem = @import("memory.zig");
const chunks = @import("chunk.zig");

const stdout = std.io.getStdOut().writer();
const allocator = @import("memory.zig").allocator;
var vm = VM.vm;

pub const Obj = struct {
    type: ObjType,
    next: ?*Obj,
};

pub const ObjString = struct {
    obj: Obj,
    length: usize,
    chars: []u8,
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u32,
    chunk: chunks.Chunk,
    name: ?*ObjString,
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *ObjFunction,
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
};

pub fn allocateString(chars: []u8, length: usize) !*ObjString {
    var string = try mem.allocateObject(ObjString, ObjType.String);
    string.obj.type = ObjType.String;
    string.length = length;
    string.chars = chars;
    return string;
}

pub fn newFunction() !*ObjFunction {
    var function: *ObjFunction = try mem.allocateObject(ObjFunction, ObjType.Function);
    function.arity = 0;
    function.name = null;
    chunks.initChunk(&function.chunk) catch {};
    return function;
}

pub fn newClosure(function: *ObjFunction) !*ObjClosure {
    const closure: *ObjClosure = try mem.allocateObject(ObjClosure, ObjType.Closure);
    closure.function = function;
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
    var heapChars = try allocator.alloc(u8, length + 1);
    heapChars[length] = 0;
    std.mem.copyForwards(u8, heapChars, chars[0..length]);
    return (try allocateString(heapChars, length));
}

pub fn takeString(chars: []u8, length: usize) !*ObjString {
    return (try allocateString(chars, length));
}

pub fn printObject(value: values.Value) void {
    switch (value.as.obj.type) {
        ObjType.String => {
            const string: *ObjString = @alignCast(@ptrCast(value.as.obj));
            stdout.print("{s}", .{string.chars}) catch {};
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
