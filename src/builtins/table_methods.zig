const std = @import("std");
const Value = @import("../value.zig").Value;
const obj = @import("../object.zig");
const Obj = @import("../object.zig").Obj;
const ObjTable = @import("../object.zig").ObjTable;

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
