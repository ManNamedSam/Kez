const std = @import("std");
const values = @import("value.zig");
const VM = @import("vm.zig");

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

pub const ObjType = enum {
    String,
};

pub inline fn isObjType(value: values.Value, object_type: ObjType) bool {
    return value.isObj() and value.as.obj.type == object_type;
}

pub fn copyString(chars: [*]const u8, length: usize) !*ObjString {
    var heapChars = try allocator.alloc(u8, length + 1);
    heapChars[length] = 0;
    std.mem.copyForwards(u8, heapChars, chars[0..length]);
    return (try allocateString(heapChars, length));
}

fn allocateString(chars: []u8, length: usize) !*ObjString {
    var string = try allocator.create(ObjString);
    string.obj.type = ObjType.String;
    string.length = length;
    string.chars = chars;
    return string;
}

pub fn takeString(chars: []u8, length: usize) !*ObjString {
    return (try allocateString(chars, length));
}

fn allocateObject(size: usize, object_type: ObjType) *Obj {
    _ = size; // autofix
    var object = allocator.create(Obj) catch {};
    object.type = object_type;

    object.next = vm.objects;
    vm.objects = object;
    return object;
}

pub fn printObject(value: values.Value) void {
    switch (value.as.obj.type) {
        ObjType.String => {
            const obj_string: *ObjString = @alignCast(@ptrCast(value.as.obj));
            std.io.getStdOut().writer().print("{s}", .{obj_string.chars}) catch {};
        },
        // else => stdout.print("{any}", .{value.as.obj}) catch {},
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
    }
}
