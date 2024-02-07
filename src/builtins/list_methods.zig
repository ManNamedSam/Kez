const std = @import("std");
const Value = @import("../value.zig").Value;
const obj = @import("../object.zig");
const Obj = @import("../object.zig").Obj;
const ObjList = @import("../object.zig").ObjList;

pub fn appendListMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const list: *ObjList = @ptrCast(object);
    list.append(args[0]);
    return Value.makeNull();
}

pub fn lengthListMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    _ = args;
    const list: *ObjList = @ptrCast(object);
    return Value.makeNumber(@floatFromInt(list.items.items.len));
}

pub fn sliceListMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const list: *ObjList = @ptrCast(object);
    const new_list = try ObjList.init();
    const index_1: usize = @intFromFloat(args[0].as.number);
    const index_2: usize = @intFromFloat(args[1].as.number);
    try new_list.items.appendSlice(list.items.items[index_1..index_2]);
    return Value.makeObj(@ptrCast(new_list));
}
