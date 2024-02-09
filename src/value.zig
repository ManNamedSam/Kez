const std = @import("std");
const mem = @import("memory.zig");
const objects = @import("object.zig");

const Obj = @import("object.zig").Obj;

const stdout = std.io.getStdOut().writer();

pub const Value = struct {
    as: ValueType,

    pub fn isBool(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.bool;
    }

    pub fn isNull(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.null;
    }

    pub fn isNumber(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.number;
    }

    pub fn isObj(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.obj;
    }

    pub fn isError(self: Value) bool {
        return @as(ValueTypeTag, self.as) == ValueTypeTag.error_;
    }

    pub fn isString(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.String);
    }

    pub fn isList(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.List);
    }

    pub fn isTable(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.Table);
    }

    pub fn isNative(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.Native);
    }

    pub fn isClosure(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.Closure);
    }
    pub fn isClass(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.Class);
    }

    pub fn isInstance(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.Instance);
    }

    pub fn isBoundMethod(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.BoundMethod);
    }

    pub fn makeBool(value: bool) Value {
        return Value{ .as = ValueType{ .bool = value } };
    }

    pub fn makeNull() Value {
        return Value{ .as = ValueType{ .null = undefined } };
    }

    pub fn makeNumber(value: f64) Value {
        return Value{ .as = ValueType{ .number = value } };
    }

    pub fn makeObj(value: *Obj) Value {
        return Value{ .as = ValueType{ .obj = value } };
    }

    pub fn makeError() Value {
        return Value{ .as = ValueType{ .error_ = {} } };
    }

    pub fn asString(self: Value) *objects.ObjString {
        return @ptrCast(self.as.obj);
    }

    pub fn asFunction(self: Value) *objects.ObjFunction {
        return @ptrCast(self.as.obj);
    }

    pub fn asList(self: Value) *objects.ObjList {
        const list: *objects.ObjList = @ptrCast(self.as.obj);
        return list;
    }

    pub fn asObjectMethod(self: Value) *objects.ObjObjectMethod {
        const method: *objects.ObjObjectMethod = @ptrCast(self.as.obj);
        return method;
    }

    pub fn asNative(self: Value) *objects.ObjNative {
        const native: *objects.ObjNative = @ptrCast(self.as.obj);
        return native;
    }

    pub fn asClosure(self: Value) *objects.ObjClosure {
        const closure: *objects.ObjClosure = @ptrCast(self.as.obj);
        return closure;
    }

    pub fn asClass(self: Value) *objects.ObjClass {
        const class: *objects.ObjClass = @ptrCast(self.as.obj);
        return class;
    }

    pub fn asInstance(self: Value) *objects.ObjInstance {
        const instance: *objects.ObjInstance = @ptrCast(self.as.obj);
        return instance;
    }

    pub fn asBoundMethod(self: Value) *objects.ObjBoundMethod {
        const method: *objects.ObjBoundMethod = @ptrCast(self.as.obj);
        return method;
    }
};

pub const ValueTypeTag = enum {
    bool,
    number,
    null,
    obj,
    error_,
};

pub const ValueType = union(ValueTypeTag) {
    bool: bool,
    number: f64,
    null: void,
    obj: *Obj,
    error_: void,
};

pub const ValueArray = struct {
    values: *std.ArrayList(Value) = undefined,
    // values: *std.ArrayList(Value) = std.ArrayList(Value).init(mem.allocator),
    pub fn init(self: *ValueArray) !void {
        // array.values.clearAndFree();
        self.values = try mem.allocator.create(std.ArrayList(Value));
        self.values.* = std.ArrayList(Value).init(mem.allocator);
    }

    pub fn free(self: *ValueArray) void {
        self.values.clearAndFree();
        mem.allocator.destroy(self.values);
    }

    pub fn write(self: *ValueArray, value: Value) !void {
        if (self.values.capacity < self.values.items.len + 1) {
            const old_cap = self.values.items.len;
            const new_cap = mem.growCapacity(old_cap);
            mem.growArray(Value, self.values, old_cap, new_cap);
        }
        self.values.appendAssumeCapacity(value);
    }
};

// pub fn initValueArray(array: *ValueArray) !void {
//     // array.values.clearAndFree();
//     array.values = try mem.allocator.create(std.ArrayList(Value));
//     array.values.* = std.ArrayList(Value).init(mem.allocator);
// }

// pub fn writeValueArray(array: *ValueArray, value: Value) !void {
//     if (array.values.capacity < array.values.items.len + 1) {
//         const old_cap = array.values.items.len;
//         const new_cap = mem.growCapacity(old_cap);
//         mem.growArray(Value, array.values, old_cap, new_cap);
//     }
//     array.values.appendAssumeCapacity(value);
// }

// pub fn freeValueArray(array: *ValueArray) void {
//     array.values.clearAndFree();
//     mem.allocator.destroy(array.values);
// }

pub fn printValue(value: Value) void {
    switch (@as(ValueTypeTag, value.as)) {
        ValueTypeTag.bool => stdout.print("{any}", .{value.as.bool}) catch {},
        ValueTypeTag.null => stdout.print("null", .{}) catch {},
        ValueTypeTag.number => stdout.print("{d}", .{value.as.number}) catch {},
        ValueTypeTag.obj => objects.printObject(value),
        else => {},
    }
}

pub fn valueToString(value: Value) ![]u8 {
    switch (@as(ValueTypeTag, value.as)) {
        ValueTypeTag.bool => return try std.fmt.allocPrint(mem.allocator, "{any}", .{value.as.bool}),
        ValueTypeTag.null => return try std.fmt.allocPrint(mem.allocator, "null", .{}),
        ValueTypeTag.number => return try std.fmt.allocPrint(mem.allocator, "{d}", .{value.as.number}),
        ValueTypeTag.obj => return try objects.objectToString(value),
        ValueTypeTag.error_ => return try std.fmt.allocPrint(mem.allocator, "<error>", .{}),
    }
}

pub fn valuesEqual(a: Value, b: Value) bool {
    if (@as(ValueTypeTag, a.as) != @as(ValueTypeTag, b.as)) return false;
    switch (@as(ValueTypeTag, a.as)) {
        ValueTypeTag.bool => return a.as.bool == b.as.bool,
        ValueTypeTag.null => return true,
        ValueTypeTag.number => return a.as.number == b.as.number,
        ValueTypeTag.obj => {
            return objects.objectsEqual(a, b);
        },
        ValueTypeTag.error_ => return true,
        // else => return false,
    }
}
