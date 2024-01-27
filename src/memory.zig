const std = @import("std");
const obj = @import("object.zig");
const chunks = @import("chunk.zig");
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

const VM = @import("vm.zig");

pub fn growCapacity(capacity: usize) usize {
    return if (capacity < 8) 8 else capacity * 2;
}

pub fn growArray(comptime value_type: type, array: *std.ArrayList(value_type), old_count: usize, new_count: usize) void {
    _ = old_count; // autofix
    if (new_count == 0) {
        array.clearAndFree();
    } else {
        array.ensureTotalCapacityPrecise(new_count) catch {
            std.debug.print("Out of memory error!", .{});
            std.os.exit(1);
        };
    }
}

fn reallocate(value_type: type, array: *void, old_size: usize, new_size: usize) ?*void {
    _ = old_size; // autofix
    if (new_size == 0) {
        allocator.destroy(array);
    }
    const result = std.ArrayList(value_type).initCapacity(allocator, new_size);
    return result;
}

pub fn allocateObject(comptime T: type, object_type: ObjType) !*T {
    var object: *Obj = @ptrCast(try allocator.create(T));
    object.type = object_type;

    object.next = VM.vm.objects;
    VM.vm.objects = object;
    return @alignCast(@ptrCast(object));
}

pub fn freeObjects() void {
    var object = VM.vm.objects;
    while (object) |o| {
        const next = o.next;
        freeObject(o);
        object = next;
    }
}

fn freeObject(object: *Obj) void {
    switch (object.type) {
        ObjType.String => {
            const string: *obj.ObjString = @alignCast(@ptrCast(object));
            allocator.free(string.chars);
            allocator.destroy(string);
        },
        ObjType.Function => {
            const function: *obj.ObjFunction = @alignCast(@ptrCast(object));
            chunks.freeChunk(&function.chunk);
            allocator.destroy(function);
        },
        ObjType.Closure => {
            const closure: *obj.ObjClosure = @alignCast(@ptrCast(object));
            allocator.destroy(closure);
        },
        ObjType.Native => {
            const native: *obj.ObjNative = @alignCast(@ptrCast(object));
            allocator.destroy(native);
        },
    }
}
