const std = @import("std");
const Value = @import("../value.zig").Value;
const obj = @import("../object.zig");
const Obj = @import("../object.zig").Obj;
const ObjString = @import("../object.zig").ObjString;

pub fn lengthStringMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    _ = args;
    const string: *ObjString = @ptrCast(object);
    return Value.makeNumber(@floatFromInt(string.chars.len));
}

pub fn sliceStringMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    const string: *ObjString = @ptrCast(object);
    const index_1: usize = @intFromFloat(args[0].as.number);
    const index_2: usize = @intFromFloat(args[1].as.number);
    const new_string_chars: []u8 = string.chars[index_1..index_2];
    const new_string = try obj.ObjString.copy(new_string_chars.ptr, new_string_chars.len);
    return Value.makeObj(@ptrCast(new_string));
}
