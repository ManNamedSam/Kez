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
var vm: *VM.VM = undefined;

pub fn initVM(_vm: *VM.VM) void {
    vm = _vm;
}

pub fn growCapacity(capacity: usize) usize {
    return if (capacity < 8) 8 else capacity * 2;
}

pub fn growArray(comptime value_type: type, array: *std.ArrayList(value_type), old_count: usize, new_count: usize) void {
    vm.bytes_allocated += @sizeOf(value_type) * (new_count - old_count);
    if (new_count == 0) {
        array.clearAndFree();
    } else {
        if (debug_stress_gc) {
            collectGarbage();
        }
        if (vm.bytes_allocated > vm.next_gc) {
            collectGarbage();
        }
        array.ensureTotalCapacityPrecise(new_count) catch {
            std.debug.print("Out of memory error!", .{});
            std.os.exit(1);
        };
    }
}

pub fn growTable(comptime key_type: type, comptime value_type: type, table: *std.AutoHashMap(key_type, value_type), old_count: u32, new_count: u32) void {
    const entry = std.AutoHashMap(key_type, value_type).Entry;
    vm.bytes_allocated += @sizeOf(entry) * (new_count - old_count);
    if (new_count == 0) {
        table.clearAndFree();
    } else {
        if (debug_stress_gc) {
            collectGarbage();
        }
        if (vm.bytes_allocated > vm.next_gc) {
            collectGarbage();
        }
        table.ensureTotalCapacity(new_count) catch {
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
    vm.bytes_allocated += @sizeOf(T);
    if (debug_stress_gc) {
        collectGarbage();
    }
    if (vm.bytes_allocated > vm.next_gc) {
        collectGarbage();
    }
    var object: *Obj = @alignCast(@ptrCast(try allocator.create(T)));
    object.type = object_type;

    object.next = vm.objects;
    object.is_marked = false;
    vm.objects = object;
    if (debug_log_gc) {
        std.debug.print("{*} allocate {d} for {any} (Total allocated: {d}\n", .{ object, @sizeOf(T), object_type, vm.bytes_allocated });
    }
    return @alignCast(@ptrCast(object));
}

pub fn freeObjects() void {
    var object = vm.objects;
    while (object) |o| {
        const next = o.next;
        freeObject(o);
        object = next;
    }
    vm.gray_stack.clearAndFree();
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
            vm.bytes_allocated -= string_chars_size + string_size;
        },
        ObjType.Function => {
            const function: *obj.ObjFunction = @alignCast(@ptrCast(object));
            const chunk_size = (@sizeOf(u8) + @sizeOf(u32)) * function.chunk.code.items.len;
            const func_size = @sizeOf(obj.ObjFunction);
            // chunks.freeChunk(&function.chunk);
            function.chunk.free();
            allocator.destroy(function);
            vm.bytes_allocated -= chunk_size + func_size;
        },
        ObjType.Closure => {
            const closure: *obj.ObjClosure = @alignCast(@ptrCast(object));
            // allocator.free(closure.upvalues);
            allocator.destroy(closure);
            vm.bytes_allocated -= @sizeOf(obj.ObjClosure);
        },
        ObjType.Upvalue => {
            const upvalue: *obj.ObjUpvalue = @alignCast(@ptrCast(object));
            allocator.destroy(upvalue);
            vm.bytes_allocated -= @sizeOf(obj.ObjClosure);
        },
        ObjType.Native => {
            const native: *obj.ObjNative = @alignCast(@ptrCast(object));
            allocator.destroy(native);
            // vm.bytes_allocated -= @sizeOf(obj.ObjNative);
        },
        ObjType.BoundMethod => {
            const bound: *obj.ObjBoundMethod = @alignCast(@ptrCast(object));
            allocator.destroy(bound);
            vm.bytes_allocated -= @sizeOf(obj.ObjBoundMethod);
        },
        ObjType.Class => {
            const class: *obj.ObjClass = @alignCast(@ptrCast(object));
            freeAutoTable(*obj.ObjString, Value, class.fields);
            freeAutoTable(*obj.ObjString, Value, class.methods);
            allocator.destroy(class);
            vm.bytes_allocated -= @sizeOf(obj.ObjClass);
        },
        ObjType.Instance => {
            const instance: *obj.ObjInstance = @alignCast(@ptrCast(object));
            freeAutoTable(*obj.ObjString, Value, instance.fields);
            allocator.destroy(instance);
            vm.bytes_allocated -= @sizeOf(obj.ObjInstance);
        },
        ObjType.List => {
            const list: *obj.ObjList = @ptrCast(object);
            const list_size = @sizeOf(Value) * list.items.items.len;
            list.items.clearAndFree();
            allocator.destroy(list);
            vm.bytes_allocated -= @sizeOf(obj.ObjList) + list_size;
        },
        ObjType.Table => {
            const table: *obj.ObjTable = @ptrCast(object);
            // const table_size = @sizeOf(Value) * table.entries.count() * 2;
            table.entries.clearAndFree();
            freeTable(Value, Value, obj.ObjTable.ObjTableContext, table.entries);
            allocator.destroy(table);
            vm.bytes_allocated -= @sizeOf(obj.ObjTable); // + table_size;
        },
        ObjType.ObjectMethod => {
            const method: *obj.ObjObjectMethod = @ptrCast(object);
            allocator.destroy(method);
            vm.bytes_allocated -= @sizeOf(obj.ObjObjectMethod);
        },
    }
}

fn freeAutoTable(comptime key_type: type, comptime value_type: type, table: *std.AutoHashMap(key_type, value_type)) void {
    const size = @sizeOf(std.AutoHashMap(key_type, value_type).Entry) * table.capacity();
    table.clearAndFree();
    allocator.destroy(table);
    vm.bytes_allocated -= @sizeOf(std.AutoHashMap(key_type, value_type)) + size;
}

fn freeTable(comptime key_type: type, comptime value_type: type, comptime context_type: type, table: *std.HashMap(key_type, value_type, context_type, std.hash_map.default_max_load_percentage)) void {
    const size = @sizeOf(std.HashMap(key_type, value_type, context_type, std.hash_map.default_max_load_percentage).Entry) * table.capacity();
    table.clearAndFree();
    allocator.destroy(table);
    vm.bytes_allocated -= @sizeOf(std.HashMap(key_type, value_type, context_type, std.hash_map.default_max_load_percentage)) + size;
}

fn collectGarbage() void {
    if (debug_log_gc) {
        std.debug.print("--gc begin\n", .{});
    }
    const before = vm.bytes_allocated;

    markRoots();
    traceReferences();
    removeUnmarkedStrings();
    sweep();

    vm.next_gc = vm.bytes_allocated * GC_HEAP_GROW_FACTOR;

    if (debug_log_gc) {
        std.debug.print("-- gc end\n", .{});
        std.debug.print("   collected {d} bytes (from {d} to {d}) next at {d}\n", .{
            before - vm.bytes_allocated,
            before,
            vm.bytes_allocated,
            vm.next_gc,
        });
    }
}

fn markRoots() void {
    var slot: [*]Value = &vm.stack;

    while (@intFromPtr(slot) < @intFromPtr(vm.stack_top)) : (slot += 1) {
        markValue(slot[0]);
    }

    var i: usize = 0;
    while (i < vm.frame_count) : (i += 1) {
        markObject(@alignCast(@ptrCast(vm.frames[i].closure)));
    }

    var upvalue = vm.open_upvalues;
    while (upvalue) |up_val| : (upvalue = up_val.next) {
        markObject(@alignCast(@ptrCast(up_val)));
    }

    markTable(&vm.globals);
    markTable(&vm.string_methods);
    markTable(&vm.list_methods);
    markTable(&vm.table_methods);

    compiler.markCompilerRoots();
    if (vm.init_string) |string| {
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
        if (vm.gray_capacity < vm.gray_count + 1) {
            vm.gray_capacity = growCapacity(vm.gray_capacity);
            vm.gray_stack.resize(vm.gray_capacity) catch {};
        }
        vm.gray_stack.items[vm.gray_count] = object;
        vm.gray_count += 1;
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
    while (vm.gray_count > 0) {
        vm.gray_count -= 1;
        const object = vm.gray_stack.items[vm.gray_count];
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
            markTable(class.fields);
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
        ObjType.Table => {
            const table: *obj.ObjTable = @ptrCast(object);
            var key_iter = table.entries.keyIterator();
            while (key_iter.next()) |key| {
                markValue(key.*);
                const value = table.entries.get(key.*);
                markValue(value.?);
            }
        },
        ObjType.String, ObjType.Native, ObjType.ObjectMethod => {},
    }
}

fn sweep() void {
    var previous: ?*obj.Obj = null;
    var object = vm.objects;
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
                vm.objects = object;
            }
            freeObject(unreached);
        }
    }
}

fn removeUnmarkedStrings() void {
    var table = &vm.strings;
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
        const res = vm.globals.get(vm.strings.get(key.*).?);
        if (res == null) {
            _ = vm.strings.removeByPtr(key);
        }
    }
}
