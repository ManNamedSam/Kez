const std = @import("std");
const values = @import("value.zig");
const VM = @import("vm.zig");
const mem = @import("memory.zig");
const chunks = @import("chunk.zig");

const Value = values.Value;

const stdout = std.io.getStdOut().writer();
const allocator = @import("memory.zig").allocator;

var vm: *VM.VM = undefined;

pub fn initVM(_vm: *VM.VM) void {
    vm = _vm;
}
// var vm = VM.vm;

pub const ObjType = enum {
    String,
    Function,
    Native,
    Closure,
    NativeMethod,
    Upvalue,
    Class,
    Instance,
    BoundMethod,
    BoundNativeMethod,
    List,
    Table,
    Module,
};

pub const Obj = struct {
    type: ObjType,
    next: ?*Obj,
    is_marked: bool,
};

pub const ObjString = struct {
    obj: Obj,
    length: usize,
    chars: []u8,

    pub fn allocate(chars: []u8, length: usize) *ObjString {
        var string = mem.allocateObject(ObjString, ObjType.String) catch undefined;
        string.obj.type = ObjType.String;
        string.length = length;
        string.chars = chars;
        vm.push(Value.makeObj(@alignCast(@ptrCast(string))));
        vm.strings.put(chars, string) catch {};
        _ = vm.pop();
        return string;
    }

    pub fn copy(chars: [*]const u8, length: usize) *ObjString {
        var heapChars = allocator.alloc(u8, length + 1) catch undefined;
        heapChars[length] = 0;
        std.mem.copyForwards(u8, heapChars, chars[0..length]);
        const interned = vm.strings.get(heapChars);

        if (interned) |string| {
            defer allocator.free(heapChars);
            return string;
        }
        vm.bytes_allocated += @sizeOf(u8) * length + 1;

        return ObjString.allocate(heapChars, length);
    }

    pub fn take(chars: []u8, length: usize) *ObjString {
        var heapChars = allocator.alloc(u8, length + 1) catch undefined;
        heapChars[length] = 0;
        std.mem.copyForwards(u8, heapChars, chars[0..length]);
        const interned = vm.strings.get(heapChars);
        if (interned) |string| {
            defer allocator.free(heapChars);
            return string;
        }
        vm.bytes_allocated += @sizeOf(u8) * length + 1;
        return ObjString.allocate(chars, length);
    }
};

pub const ObjUpvalue = struct {
    obj: Obj,
    closed: Value,
    location: *Value,
    next: ?*ObjUpvalue,

    pub fn init(slot: *Value) *ObjUpvalue {
        const upvalue = mem.allocateObject(ObjUpvalue, ObjType.Upvalue) catch undefined;
        upvalue.closed = Value.makeNull();
        upvalue.location = slot;
        upvalue.next = null;
        return upvalue;
    }
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: u32,
    upvalue_count: u8,
    chunk: chunks.Chunk,
    name: ?*ObjString,

    pub fn init() *ObjFunction {
        var function: *ObjFunction = mem.allocateObject(ObjFunction, ObjType.Function) catch undefined;
        function.arity = 0;
        function.name = null;
        function.upvalue_count = 0;
        function.chunk.init() catch {};
        // chunks.initChunk(&function.chunk) catch {};
        return function;
    }

    fn print(self: ObjFunction) void {
        if (self.name) |name| {
            stdout.print("<fn {s}>", .{name.chars}) catch {};
        } else {
            stdout.print("<script>", .{}) catch {};
        }
    }

    fn toString(self: ObjFunction) []u8 {
        if (self.name) |name| {
            return std.fmt.allocPrint(mem.allocator, "<fn {s}>", .{name.chars}) catch undefined;
        } else {
            return std.fmt.allocPrint(mem.allocator, "<script>", .{}) catch undefined;
        }
    }
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *ObjFunction,
    upvalues: [*]?*ObjUpvalue,
    upvalue_count: u8,

    pub export fn init(function: *ObjFunction) *ObjClosure {
        const vals = mem.allocator.alloc(?*ObjUpvalue, function.upvalue_count) catch undefined;
        const upvalues = vals.ptr;
        var i: usize = 0;
        while (i < function.upvalue_count) : (i += 1) {
            upvalues[i] = null;
        }
        const closure: *ObjClosure = mem.allocateObject(ObjClosure, ObjType.Closure) catch undefined;
        closure.function = function;
        closure.upvalues = upvalues;
        closure.upvalue_count = function.upvalue_count;
        return closure;
    }
};

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,

    pub fn init(function: NativeFn) *ObjNative {
        const native: *ObjNative = mem.allocateObject(ObjNative, ObjType.Native) catch undefined;
        native.function = function;
        return native;
    }
};

pub const ObjClass = struct {
    obj: Obj,
    name: *ObjString,
    methods: *std.AutoHashMap(*ObjString, Value),
    fields: *std.AutoHashMap(*ObjString, Value),

    pub fn init(name: *ObjString) *ObjClass {
        const class: *ObjClass = mem.allocateObject(ObjClass, ObjType.Class) catch undefined;
        class.name = name;
        class.fields = mem.allocator.create(std.AutoHashMap(*ObjString, Value)) catch undefined;
        class.fields.* = std.AutoHashMap(*ObjString, Value).init(allocator);
        class.methods = mem.allocator.create(std.AutoHashMap(*ObjString, Value)) catch undefined;
        class.methods.* = std.AutoHashMap(*ObjString, Value).init(allocator);
        return class;
    }

    pub fn addMethod(self: *ObjClass, name: *ObjString, method: Value) void {
        if (@as(f32, @floatFromInt(self.methods.capacity())) <= @as(f32, @floatFromInt(self.methods.count())) * 1.5) {
            const old_cap = self.methods.capacity();
            const new_cap = mem.growCapacity(old_cap);
            mem.growTable(*ObjString, Value, self.methods, old_cap, @intCast(new_cap));
        }
        self.methods.putAssumeCapacity(name, method);
    }

    pub fn addField(self: *ObjClass, name: *ObjString, method: Value) void {
        if (@as(f32, @floatFromInt(self.fields.capacity())) <= @as(f32, @floatFromInt(self.fields.count())) * 1.5) {
            const old_cap = self.fields.capacity();
            const new_cap = mem.growCapacity(old_cap);
            mem.growTable(*ObjString, Value, self.fields, old_cap, @intCast(new_cap));
        }
        self.fields.putAssumeCapacity(name, method);
    }
};

pub const ObjInstance = struct {
    obj: Obj,
    class: *ObjClass,
    fields: *std.AutoHashMap(*ObjString, Value),

    pub fn init(class: *ObjClass) *ObjInstance {
        const instance = mem.allocateObject(ObjInstance, ObjType.Instance) catch undefined;
        instance.class = class;
        instance.fields = mem.allocator.create(std.AutoHashMap(*ObjString, Value)) catch undefined;
        instance.fields.* = std.AutoHashMap(*ObjString, Value).init(mem.allocator);
        var keys_iter = class.fields.keyIterator();
        while (keys_iter.next()) |key| {
            instance.setProperty(key.*, class.fields.get(key.*).?);
        }
        return instance;
    }

    pub fn setProperty(self: *ObjInstance, name: *ObjString, property: Value) void {
        if (@as(f32, @floatFromInt(self.fields.capacity())) <= @as(f32, @floatFromInt(self.fields.count())) * 1.5) {
            const old_cap = self.fields.capacity();
            const new_cap = mem.growCapacity(old_cap);
            mem.growTable(*ObjString, Value, self.fields, old_cap, @intCast(new_cap));
        }
        self.fields.put(name, property) catch {};
    }
};

pub const ObjBoundMethod = struct {
    obj: Obj,
    reciever: Value,
    method: *ObjClosure,

    pub fn init(reciever: Value, method: *ObjClosure) *ObjBoundMethod {
        const bound = mem.allocateObject(ObjBoundMethod, ObjType.BoundMethod) catch undefined;
        bound.reciever = reciever;
        bound.method = method;
        return bound;
    }
};

pub const ObjBoundNativeMethod = struct {
    obj: Obj,
    reciever: Value,
    method: *ObjNativeMethod,

    pub fn init(reciever: Value, method: *ObjNativeMethod) *ObjBoundNativeMethod {
        const bound = mem.allocateObject(ObjBoundNativeMethod, ObjType.BoundNativeMethod) catch undefined;
        bound.reciever = reciever;
        bound.method = method;
        return bound;
    }
};

pub const ObjList = struct {
    obj: Obj,
    items: *std.ArrayList(Value),

    pub fn init() *ObjList {
        const list = mem.allocateObject(ObjList, ObjType.List) catch undefined;
        list.items = mem.allocator.create(std.ArrayList(Value)) catch undefined;
        list.items.* = std.ArrayList(Value).init(allocator);
        return list;
    }

    pub fn append(self: ObjList, value: Value) void {
        if (self.items.capacity < self.items.items.len + 1) {
            const old_cap = self.items.capacity;
            const new_cap = mem.growCapacity(old_cap);
            mem.growArray(Value, self.items, old_cap, new_cap);
        }
        self.items.appendAssumeCapacity(value);
    }

    pub fn store(self: ObjList, index: usize, value: Value) void {
        self.items.items[index] = value;
    }

    pub fn getByIndex(self: ObjList, index: usize) Value {
        return self.items.items[index];
    }

    pub fn remove(self: ObjList, index: usize) Value {
        return self.items.orderedRemove(index);
    }

    pub fn isValidIndex(self: ObjList, index: usize) bool {
        if (index < 0 or index > self.items.items.len - 1) return false;
        return true;
    }

    pub fn toString(self: ObjList) ![]u8 {
        var string: []u8 = "";
        if (self.items.items.len > 0) {
            var x = values.valueToString(self.items.items[0]);
            string = try std.fmt.allocPrint(mem.allocator, "{s}", .{x});
            var i: usize = 1;
            while (i < self.items.items.len) : (i += 1) {
                x = values.valueToString(self.items.items[i]);
                string = try std.fmt.allocPrint(mem.allocator, "{s}, {s}", .{ string, x });
            }
        }
        string = try std.fmt.allocPrint(mem.allocator, "[{s}]", .{string});

        // const obj_s = objString.take(chars, chars.len);
        return string;
    }
};

pub const ObjTable = struct {
    obj: Obj,
    entries: *std.HashMap(
        Value,
        Value,
        ObjTable.ObjTableContext,
        std.hash_map.default_max_load_percentage,
    ),

    pub fn init() *ObjTable {
        const table = mem.allocateObject(ObjTable, ObjType.Table) catch undefined;
        table.entries = mem.allocator.create(std.HashMap(
            Value,
            Value,
            ObjTable.ObjTableContext,
            std.hash_map.default_max_load_percentage,
        )) catch undefined;
        table.entries.* = std.HashMap(
            Value,
            Value,
            ObjTable.ObjTableContext,
            std.hash_map.default_max_load_percentage,
        ).init(mem.allocator);
        return table;
    }

    pub const ObjTableContext = struct {
        pub fn eql(self: ObjTableContext, a: Value, b: Value) bool {
            _ = self;
            return values.valuesEqual(a, b);
        }

        pub fn hash(self: ObjTableContext, value: Value) u64 {
            _ = self;
            return std.hash_map.hashString(values.valueToString(value));
        }
    };
};

pub const ObjNativeMethod = struct {
    obj: Obj,
    function: ObjectMethodFn,
    object_type: ObjType,

    pub fn init(function: ObjectMethodFn, object_type: ObjType) *ObjNativeMethod {
        const method: *ObjNativeMethod = mem.allocateObject(ObjNativeMethod, ObjType.NativeMethod) catch undefined;
        method.function = function;
        method.object_type = object_type;
        return method;
    }
};

pub const ObjModule = struct {
    obj: Obj,
    globals: *std.AutoHashMap(*ObjString, values.Value),

    pub fn init() *ObjModule {
        var module: *ObjModule = mem.allocateObject(ObjModule, ObjType.Module) catch undefined;
        module.globals = mem.allocator.create(std.AutoHashMap(*ObjString, values.Value)) catch undefined;
        module.globals.* = std.AutoHashMap(*ObjString, values.Value).init(allocator);
        return module;
    }
};

pub const NativeFn = *const fn (arg_count: u8, args: [*]Value) Value;
pub const ObjectMethodFn = *const fn (object: *Obj, arg_count: u8, args: [*]Value) Value;

pub inline fn isObjType(value: Value, object_type: ObjType) bool {
    return value.isObj() and value.as.obj.type == object_type;
}

pub fn printObject(value: Value) void {
    stdout.print("{s}", .{objectToString(value) catch undefined}) catch {};
}

pub fn objectToString(value: Value) ![]u8 {
    switch (value.as.obj.type) {
        ObjType.String => {
            const string: *ObjString = @alignCast(@ptrCast(value.as.obj));
            return try std.fmt.allocPrint(mem.allocator, "{s}", .{string.chars[0 .. string.chars.len - 1]});
        },
        ObjType.Upvalue => {
            return try std.fmt.allocPrint(mem.allocator, "upvalue", .{});
        },
        ObjType.Function => return value.asFunction().toString(),
        ObjType.Closure => {
            return value.asClosure().function.toString();
        },
        ObjType.Native => return try std.fmt.allocPrint(mem.allocator, "<native fn>", .{}),
        ObjType.BoundMethod => return value.asBoundMethod().method.function.toString(),
        ObjType.BoundNativeMethod => return try std.fmt.allocPrint(mem.allocator, "<{s} method>", .{value.asBoundNativeMethod().reciever.asInstance().class.name.chars}),
        ObjType.Class => {
            return try std.fmt.allocPrint(mem.allocator, "<class {s}>", .{value.asClass().name.chars});
        },
        ObjType.Instance => {
            return try std.fmt.allocPrint(mem.allocator, "<{s} instance>", .{value.asInstance().class.name.chars});
        },
        ObjType.List => {
            const list: *ObjList = @ptrCast(value.as.obj);
            return try std.fmt.allocPrint(mem.allocator, "{s}", .{list.toString() catch ""});
        },
        ObjType.Table => return try std.fmt.allocPrint(mem.allocator, "<table>", .{}),
        ObjType.NativeMethod => {
            var obj_type: [*:0]const u8 = undefined;
            switch (value.asNativeMethod().object_type) {
                ObjType.List => obj_type = "list",
                ObjType.Table => obj_type = "table",
                ObjType.Instance => obj_type = "instance",
                else => obj_type = "unknown object",
            }
            return try std.fmt.allocPrint(mem.allocator, "<{any} method>", .{value.asNativeMethod().object_type});
        },
        ObjType.Module => return try std.fmt.allocPrint(mem.allocator, "<Module>", .{}),
    }
}

fn printFunction(function: *ObjFunction) void {
    if (function.name) |name| {
        stdout.print("<fn {s}>", .{name.chars}) catch {};
    } else {
        stdout.print("<script>", .{}) catch {};
    }
}

pub fn objectsEqual(a: Value, b: Value) bool {
    if (a.as.obj.type != b.as.obj.type) return false;
    switch (a.as.obj.type) {
        ObjType.List => {
            const list_a: *ObjList = @ptrCast(a.as.obj);
            const list_b: *ObjList = @ptrCast(b.as.obj);
            if (list_a.items.items.len != list_b.items.items.len) {
                return false;
            }
            var i: usize = 0;
            while (i < list_a.items.items.len) : (i += 1) {
                if (!values.valuesEqual(list_a.items.items[i], list_b.items.items[i])) {
                    return false;
                }
            }
            return true;
        },
        ObjType.String => {
            const obj_string_a: *ObjString = @alignCast(@ptrCast(a.as.obj));
            const obj_string_b: *ObjString = @alignCast(@ptrCast(b.as.obj));
            return std.mem.eql(u8, obj_string_a.chars, obj_string_b.chars);
        },
        else => return false,
    }
    return a.as.obj == b.as.obj;
}
