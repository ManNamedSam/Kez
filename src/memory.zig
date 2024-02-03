const std = @import("std");
const obj = @import("object.zig");
const chunks = @import("chunk.zig");
const values = @import("value.zig");
const compiler = @import("compiler.zig");
const Obj = @import("object.zig").Obj;
const ObjType = @import("object.zig").ObjType;
const Value = @import("value.zig").Value;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const allocator = gpa.allocator();

const debug_stress_gc = @import("debug.zig").debug_stress_gc;
const debug_log_gc = @import("debug.zig").debug_log_gc;

const VM = @import("vm.zig");

pub fn growCapacity(capacity: usize) usize {
    return if (capacity < 8) 8 else capacity * 2;
}

pub fn growArray(comptime value_type: type, array: *std.ArrayList(value_type), old_count: usize, new_count: usize) void {
    _ = old_count; // autofix
    if (new_count == 0) {
        array.clearAndFree();
    } else {
        if (debug_stress_gc) {
            collectGarbage();
        }
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
    if (debug_stress_gc) {
        collectGarbage();
    }
    var object: *Obj = @alignCast(@ptrCast(try allocator.create(T)));
    object.type = object_type;

    object.next = VM.vm.objects;
    object.is_marked = false;
    VM.vm.objects = object;
    if (debug_log_gc) {
        std.debug.print("{*} allocate {d} for {any}", .{ object, @sizeOf(T), object_type });
    }
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
    if (debug_log_gc) {
        std.debug.print("{*} free type {any}", .{ object, object.type });
    }
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
            // allocator.free(closure.upvalues);
            allocator.destroy(closure);
        },
        ObjType.Upvalue => {
            const upvalue: *obj.ObjUpvalue = @alignCast(@ptrCast(object));
            allocator.destroy(upvalue);
        },
        ObjType.Native => {
            const native: *obj.ObjNative = @alignCast(@ptrCast(object));
            allocator.destroy(native);
        },
    }
}

fn collectGarbage() void {
    if (debug_log_gc) {
        std.debug.print("--gc begin\n", .{});
    }

    markRoots();

    if (debug_log_gc) {
        std.debug.print("-- gc end\n", .{});
    }
}

fn markRoots() void {
    var slot: [*]Value = &VM.vm.stack;
    while (@intFromPtr(slot) < @intFromPtr(VM.vm.stack_top)) : (slot += 1) {
        markValue(slot[0]);
    }

    for (VM.vm.frames) |frame| {
        markObject(@ptrCast(frame.closure));
    }

    var upvalue = VM.vm.open_upvalues;
    while (upvalue) |up_val| : (upvalue = up_val.next) {
        markObject(@alignCast(@ptrCast(up_val)));
    }

    markTable(&VM.vm.globals);
    compiler.markCompilerRoots();
}

fn markValue(value: Value) void {
    if (value.isObj()) markObject(value.as.obj);
}

pub fn markObject(ob: ?*Obj) void {
    if (ob == null) return;
    if (ob) |object| {
        if (debug_log_gc) {
            std.debug.print("{*} mark ", .{object});
            values.printValue(Value.makeObj(object));
            std.debug.print("\n", .{});
        }
        object.is_marked = true;
    }
}

fn markTable(table: *std.hash_map.AutoHashMap(*obj.ObjString, Value)) void {
    var key_iter = table.keyIterator();
    while (key_iter.next()) |key| {
        markObject(@alignCast(@ptrCast(key.*)));
    }

    var val_iter = table.valueIterator();
    while (val_iter.next()) |value| {
        markValue(value.*);
    }
}
