const std = @import("std");
const Value = @import("value.zig").Value;
const ObjList = @import("object.zig").ObjList;

pub fn appendListMethod(list: *ObjList, arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    list.append(args[0]);
    return Value.makeNull();
}

pub fn lengthListMethod(list: *ObjList, arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    _ = args;
    return Value.makeNumber(@floatFromInt(list.items.items.len));
}
