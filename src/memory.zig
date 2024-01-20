const std = @import("std");
const obj = @import("object.zig");
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

const VM = @import("vm.zig");

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
            const obj_string: *obj.ObjString = @alignCast(@ptrCast(object));
            allocator.free(obj_string.chars);
            allocator.destroy(obj_string);
        },
    }
}
