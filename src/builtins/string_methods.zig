const std = @import("std");
const Value = @import("../value.zig").Value;
const obj = @import("../object.zig");
const Obj = @import("../object.zig").Obj;
const ObjString = @import("../object.zig").ObjString;

const VM = @import("../vm.zig");
var vm: *VM.VM = undefined;
pub fn init(_vm: *VM.VM) void {
    vm = _vm;
    defineNatives();
}

fn defineNatives() void {
    defineStringMethod("length", lengthStringMethod) catch {};
    defineStringMethod("slice", sliceStringMethod) catch {};
}

fn defineStringMethod(name: []const u8, function: obj.ObjectMethodFn) !void {
    vm.push(Value.makeObj(@ptrCast(try obj.ObjString.copy(name.ptr, name.len))));
    vm.push(Value.makeObj(@ptrCast(try obj.ObjNativeMethod.init(function, obj.ObjType.String))));
    vm.string_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = vm.pop();
    _ = vm.pop();
}

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
