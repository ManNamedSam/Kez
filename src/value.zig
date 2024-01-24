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

    pub fn isNative(self: Value) bool {
        return objects.isObjType(self, objects.ObjType.Native);
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

    pub fn asString(self: Value) *objects.ObjString {
        return @alignCast(@ptrCast(self.as.obj));
    }

    pub fn asFunction(self: Value) *objects.ObjFunction {
        return @alignCast(@ptrCast(self.as.obj));
    }

    pub fn asNative(self: Value) objects.NativeFn {
        const native: *objects.ObjNative = @alignCast(@ptrCast(self.as.obj));
        return native.function;
    }
};

pub const ValueTypeTag = enum {
    bool,
    number,
    null,
    obj,
};

pub const ValueType = union(ValueTypeTag) {
    bool: bool,
    number: f64,
    null: void,
    obj: *Obj,
};

pub const ValueArray = struct {
    values: *std.ArrayList(Value) = undefined,
    // values: *std.ArrayList(Value) = std.ArrayList(Value).init(mem.allocator),
};

pub fn initValueArray(array: *ValueArray) !void {
    // array.values.clearAndFree();
    array.values = try mem.allocator.create(std.ArrayList(Value));
    array.values.* = std.ArrayList(Value).init(mem.allocator);
}

pub fn writeValueArray(array: *ValueArray, value: Value) !void {
    if (array.values.capacity < array.values.items.len + 1) {
        const old_cap = array.values.items.len;
        const new_cap = mem.growCapacity(old_cap);
        mem.growArray(Value, array.values, old_cap, new_cap);
    }
    array.values.appendAssumeCapacity(value);
}

pub fn freeValueArray(array: *ValueArray) void {
    array.values.clearAndFree();
    mem.allocator.destroy(array.values);
}

pub fn printValue(value: Value) void {
    switch (@as(ValueTypeTag, value.as)) {
        ValueTypeTag.bool => stdout.print("{any}", .{value.as.bool}) catch {},
        ValueTypeTag.null => stdout.print("null", .{}) catch {},
        ValueTypeTag.number => stdout.print("{d}", .{value.as.number}) catch {},
        ValueTypeTag.obj => objects.printObject(value),
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
        // else => return false,
    }
}
