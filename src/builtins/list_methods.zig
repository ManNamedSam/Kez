const std = @import("std");
const Value = @import("../value.zig").Value;
const obj = @import("../object.zig");
const Obj = @import("../object.zig").Obj;
const ObjList = @import("../object.zig").ObjList;

const VM = @import("../vm.zig");
var vm: *VM.VM = undefined;
pub fn init(_vm: *VM.VM) void {
    vm = _vm;
    defineListMethods();
}

fn defineListMethod(name: []const u8, function: obj.ObjectMethodFn) !void {
    vm.push(Value.makeObj(@ptrCast(try obj.ObjString.copy(name.ptr, name.len))));
    vm.push(Value.makeObj(@ptrCast(try obj.ObjNativeMethod.init(function, obj.ObjType.List))));
    vm.list_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = vm.pop();
    _ = vm.pop();
}
fn defineListMethods() void {
    defineListMethod("append", appendListMethod) catch {};
    defineListMethod("length", lengthListMethod) catch {};
    defineListMethod("slice", sliceListMethod) catch {};
    defineListMethod("reverse", reverseListMethod) catch {};
}

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

pub fn reverseListMethod(object: *Obj, arg_count: u8, args: [*]Value) !Value {
    _ = arg_count;
    _ = args;
    const list: *ObjList = @ptrCast(object);
    const new_list = try ObjList.init();
    var i = list.items.items.len;
    while (i > 0) {
        i -= 1;
        new_list.append(list.items.items[i]);
    }
    return Value.makeObj(@ptrCast(new_list));
}
