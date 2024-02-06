const std = @import("std");
const Value = @import("../value.zig").Value;
const object = @import("../object.zig");
const ObjList = @import("../object.zig").ObjList;

pub fn appendListMethod(list: *ObjList, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    list.append(args[0]);
    return Value.makeNull();
}

pub fn lengthListMethod(list: *ObjList, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    _ = args;
    return Value.makeNumber(@floatFromInt(list.items.items.len));
}

pub fn sliceListMethod(list: *ObjList, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const new_list = try object.ObjList.init();
    const index_1: usize = @intFromFloat(args[0].as.number);
    const index_2: usize = @intFromFloat(args[1].as.number);
    try new_list.items.appendSlice(list.items.items[index_1..index_2]);
    return Value.makeObj(@ptrCast(new_list));
}
