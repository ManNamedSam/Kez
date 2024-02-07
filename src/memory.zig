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

const GC_HEAP_GROW_FACTOR = 2;

const VM = @import("vm.zig");

pub fn growCapacity(capacity: usize) usize {
    return if (capacity < 8) 8 else capacity * 2;
}

pub fn growArray(comptime value_type: type, array: *std.ArrayList(value_type), old_count: usize, new_count: usize) void {
    VM.vm.bytes_allocated += @sizeOf(value_type) * (new_count - old_count);
    if (new_count == 0) {
        array.clearAndFree();
    } else {
        if (debug_stress_gc) {
            collectGarbage();
        }
        if (VM.vm.bytes_allocated > VM.vm.next_gc) {
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
    VM.vm.bytes_allocated += @sizeOf(T);
    if (debug_stress_gc) {
        collectGarbage();
    }
    if (VM.vm.bytes_allocated > VM.vm.next_gc) {
        collectGarbage();
    }
    var object: *Obj = @alignCast(@ptrCast(try allocator.create(T)));
    object.type = object_type;

    object.next = VM.vm.objects;
    object.is_marked = false;
    VM.vm.objects = object;
    if (debug_log_gc) {
        std.debug.print("{*} allocate {d} for {any}\n", .{ object, @sizeOf(T), object_type });
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
    VM.vm.gray_stack.clearAndFree();
}

fn freeObject(object: *Obj) void {
    if (debug_log_gc) {
        std.debug.print("{*} free type {any}\n", .{ object, object.type });
    }
    switch (object.type) {
        ObjType.String => {
            const string: *obj.ObjString = @alignCast(@ptrCast(object));
            const string_chars_size = @sizeOf(u8) * string.length;
            const string_size = @sizeOf(obj.ObjString);
            allocator.free(string.chars);
            allocator.destroy(string);
            VM.vm.bytes_allocated -= string_chars_size + string_size;
        },
        ObjType.Function => {
            const function: *obj.ObjFunction = @alignCast(@ptrCast(object));
            const chunk_size = (@sizeOf(u8) + @sizeOf(u32)) * function.chunk.code.items.len;
            const func_size = @sizeOf(obj.ObjFunction);
            chunks.freeChunk(&function.chunk);
            allocator.destroy(function);
            VM.vm.bytes_allocated -= chunk_size + func_size;
        },
        ObjType.Closure => {
            const closure: *obj.ObjClosure = @alignCast(@ptrCast(object));
            // allocator.free(closure.upvalues);
            allocator.destroy(closure);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjClosure);
        },
        ObjType.Upvalue => {
            const upvalue: *obj.ObjUpvalue = @alignCast(@ptrCast(object));
            allocator.destroy(upvalue);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjClosure);
        },
        ObjType.Native => {
            const native: *obj.ObjNative = @alignCast(@ptrCast(object));
            allocator.destroy(native);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjNative);
        },
        ObjType.BoundMethod => {
            const bound: *obj.ObjBoundMethod = @alignCast(@ptrCast(object));
            allocator.destroy(bound);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjBoundMethod);
        },
        ObjType.Class => {
            const class: *obj.ObjClass = @alignCast(@ptrCast(object));
            class.methods.clearAndFree();
            class.fields.clearAndFree();
            allocator.destroy(class.methods);
            allocator.destroy(class.fields);
            allocator.destroy(class);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjClass);
        },
        ObjType.Instance => {
            const instance: *obj.ObjInstance = @alignCast(@ptrCast(object));
            instance.fields.clearAndFree();
            allocator.destroy(instance);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjInstance);
        },
        ObjType.List => {
            const list: *obj.ObjList = @ptrCast(object);
            const list_size = @sizeOf(Value) * list.items.items.len;
            list.items.clearAndFree();
            allocator.destroy(list);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjList) + list_size;
        },
        ObjType.ObjectMethod => {
            const method: *obj.ObjObjectMethod = @ptrCast(object);
            allocator.destroy(method);
            VM.vm.bytes_allocated -= @sizeOf(obj.ObjObjectMethod);
        },
    }
}

fn collectGarbage() void {
    if (debug_log_gc) {
        std.debug.print("--gc begin\n", .{});
    }
    const before = VM.vm.bytes_allocated;

    markRoots();
    traceReferences();
    tableRemoveWhite();
    sweep();

    VM.vm.next_gc = VM.vm.bytes_allocated * GC_HEAP_GROW_FACTOR;

    if (debug_log_gc) {
        std.debug.print("-- gc end\n", .{});
        std.debug.print("   collected {d} bytes (from {d} to {d}) next at {d}\n", .{
            before - VM.vm.bytes_allocated,
            before,
            VM.vm.bytes_allocated,
            VM.vm.next_gc,
        });
    }
}

fn markRoots() void {
    var slot: [*]Value = &VM.vm.stack;

    while (@intFromPtr(slot) < @intFromPtr(VM.vm.stack_top)) : (slot += 1) {
        markValue(slot[0]);
    }

    var i: usize = 0;
    while (i < VM.vm.frame_count) : (i += 1) {
        markObject(@alignCast(@ptrCast(VM.vm.frames[i].closure)));
    }

    var upvalue = VM.vm.open_upvalues;
    while (upvalue) |up_val| : (upvalue = up_val.next) {
        markObject(@alignCast(@ptrCast(up_val)));
    }

    markTable(&VM.vm.globals);
    compiler.markCompilerRoots();
    if (VM.vm.init_string) |string| {
        markObject(@ptrCast(string));
    }
}

fn markValue(value: Value) void {
    if (value.isObj()) markObject(value.as.obj);
}

pub fn markObject(ob: ?*Obj) void {
    if (ob == null) return;
    if (ob) |object| {
        if (object.is_marked) return;
        if (debug_log_gc) {
            std.debug.print("{*} mark ", .{object});
            values.printValue(Value.makeObj(object));
            std.debug.print("\n", .{});
        }
        object.is_marked = true;
        if (VM.vm.gray_capacity < VM.vm.gray_count + 1) {
            VM.vm.gray_capacity = growCapacity(VM.vm.gray_capacity);
            VM.vm.gray_stack.resize(VM.vm.gray_capacity) catch {};
        }
        VM.vm.gray_stack.items[VM.vm.gray_count] = object;
        VM.vm.gray_count += 1;
    }
}

fn markTable(table: *std.hash_map.AutoHashMap(*obj.ObjString, Value)) void {
    var key_iter = table.keyIterator();
    while (key_iter.next()) |key| {
        markObject(@alignCast(@ptrCast(key.*)));
        markValue(table.get(key.*).?);
    }
}

fn markArray(array: *values.ValueArray) void {
    for (array.values.items) |val| {
        markValue(val);
    }
}

fn traceReferences() void {
    while (VM.vm.gray_count > 0) {
        VM.vm.gray_count -= 1;
        const object = VM.vm.gray_stack.items[VM.vm.gray_count];
        blackenObject(object);
    }
}

fn blackenObject(object: *obj.Obj) void {
    if (debug_log_gc) {
        std.debug.print("{*} blacken ", .{object});
        values.printValue(Value.makeObj(object));
        std.debug.print("\n", .{});
    }
    switch (object.type) {
        ObjType.Closure => {
            const closure: *obj.ObjClosure = @ptrCast(object);
            markObject(@alignCast(@ptrCast(closure.function)));
            var i: usize = 0;

            while (i < closure.upvalue_count) : (i += 1) {
                markObject(@alignCast(@ptrCast(closure.upvalues[i])));
            }
        },
        ObjType.Function => {
            const function: *obj.ObjFunction = @ptrCast(object);
            markObject(@alignCast(@ptrCast(function.name)));
            markArray(&function.chunk.constants);
        },
        ObjType.Upvalue => {
            const upvalue: *obj.ObjUpvalue = @ptrCast(object);
            markValue(upvalue.closed);
        },
        ObjType.BoundMethod => {
            const bound: *obj.ObjBoundMethod = @ptrCast(object);
            markValue(bound.reciever);
            markObject(@ptrCast(bound.method));
        },
        ObjType.Class => {
            const class: *obj.ObjClass = @ptrCast(object);
            markObject(@alignCast(@ptrCast(class.name)));
            markTable(class.methods);
        },
        ObjType.Instance => {
            const instance: *obj.ObjInstance = @ptrCast(object);
            markObject(@ptrCast(instance.class));
            markTable(instance.fields);
        },
        ObjType.List => {
            const list: *obj.ObjList = @ptrCast(object);
            var i: usize = 0;
            while (i < list.items.items.len) : (i += 1) {
                markValue(list.items.items[i]);
            }
        },
        ObjType.String, ObjType.Native, ObjType.ObjectMethod => {},
    }
}

fn sweep() void {
    var previous: ?*obj.Obj = null;
    var object = VM.vm.objects;
    while (object) |o| {
        if (o.is_marked) {
            o.is_marked = false;
            previous = o;
            object = o.next;
        } else {
            const unreached = o;
            object = o.next;
            if (previous) |p| {
                p.next = object;
            } else {
                VM.vm.objects = object;
            }
            freeObject(unreached);
        }
    }
}

fn tableRemoveWhite() void {
    var table = &VM.vm.strings;
    var entries = table.*.keyIterator();
    var keys_list = std.ArrayList(*[]const u8).init(allocator);
    defer keys_list.deinit();
    while (entries.next()) |key| {
        if (table.get(key.*)) |value| {
            if (!value.obj.is_marked) {
                keys_list.append(key) catch {};
            }
        }
    }
    for (keys_list.items) |key| {
        const res = VM.vm.globals.get(VM.vm.strings.get(key.*).?);
        if (res == null) {
            _ = VM.vm.strings.removeByPtr(key);
        }
    }
}
