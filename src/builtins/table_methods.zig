const std = @import("std");
const Value = @import("../value.zig").Value;
const obj = @import("../object.zig");
const Obj = @import("../object.zig").Obj;
const ObjTable = @import("../object.zig").ObjTable;

const VM = @import("../vm.zig");
var vm: *VM.VM = undefined;
pub fn init(_vm: *VM.VM) void {
    vm = _vm;
    defineTableMethods();
}

fn defineTableMethods() void {
    defineTableMethod("put", addEntryTableMethod) catch {};
    defineTableMethod("get", getEntryTableMethod) catch {};
    defineTableMethod("keys", getKeysTableMethod) catch {};
}

fn defineTableMethod(name: []const u8, function: obj.ObjectMethodFn) !void {
    vm.push(Value.makeObj(@ptrCast(try obj.ObjString.copy(name.ptr, name.len))));
    vm.push(Value.makeObj(@ptrCast(try obj.ObjNativeMethod.init(function, obj.ObjType.Table))));
    vm.table_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = vm.pop();
    _ = vm.pop();
}

pub fn addEntryTableMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const table: *ObjTable = @ptrCast(object);
    try table.entries.put(args[0], args[1]);
    return Value.makeNull();
}

pub fn getEntryTableMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const table: *ObjTable = @ptrCast(object);
    const result = table.entries.get(args[0]);
    if (result) |value| {
        return value;
    }
    return Value.makeNull();
}

pub fn getKeysTableMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    _ = args;
    const table: *ObjTable = @ptrCast(object);
    var keys_iter = table.entries.keyIterator();
    const list: *obj.ObjList = try obj.ObjList.init();
    while (keys_iter.next()) |key| {
        list.append(key.*);
    }
    return Value.makeObj(@ptrCast(list));
}
