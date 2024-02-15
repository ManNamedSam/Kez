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
    vm.push(Value.makeObj(@ptrCast(obj.ObjString.copy(name.ptr, name.len))));
    vm.push(Value.makeObj(@ptrCast(obj.ObjNativeMethod.init(function, obj.ObjType.List))));
    vm.list_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = vm.pop();
    _ = vm.pop();
}
fn defineListMethods() void {
    defineListMethod("append", appendListMethod) catch {};
    defineListMethod("pop", popListMethod) catch {};
    defineListMethod("length", lengthListMethod) catch {};
    defineListMethod("slice", sliceListMethod) catch {};
    defineListMethod("reverse", reverseListMethod) catch {};
}

pub fn appendListMethod(object: *Obj, arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    const list: *ObjList = @ptrCast(object);
    list.append(args[0]);
    return Value.makeNull();
}

pub fn popListMethod(object: *Obj, arg_count: u8, args: [*]Value) Value {
    if (arg_count > 1) {
        return Value.makeError("Expected 0 or 1 arguments but got {d}.", .{arg_count});
    }
    const list: *ObjList = @ptrCast(object);
    if (arg_count > 0) {
        if (args[0].as.number != @trunc(args[0].as.number)) {
            return Value.makeError("Index must be an integer.", .{});
        }
        return list.remove(@as(usize, @intFromFloat(args[0].as.number)));
    } else {
        return list.remove(list.items.items.len - 1);
    }
    // return Value.makeNull();
}

pub fn lengthListMethod(object: *Obj, arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    _ = args;
    const list: *ObjList = @ptrCast(object);
    return Value.makeNumber(@floatFromInt(list.items.items.len));
}

pub fn sliceListMethod(object: *Obj, arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    const list: *ObjList = @ptrCast(object);
    const new_list = obj.ObjList.init();
    const index_1: usize = @intFromFloat(args[0].as.number);
    const index_2: usize = @intFromFloat(args[1].as.number);
    new_list.items.appendSlice(list.items.items[index_1..index_2]) catch {};
    return Value.makeObj(@ptrCast(new_list));
}

pub fn reverseListMethod(object: *Obj, arg_count: u8, args: [*]Value) Value {
    _ = arg_count;
    _ = args;
    const list: *ObjList = @ptrCast(object);
    var left: usize = 0;
    var right = list.items.items.len - 1;
    while (left < right) {
        const temp = list.items.items[left];
        list.items.items[left] = list.items.items[right];
        list.items.items[right] = temp;
        left += 1;
        right -= 1;
    }
    return Value.makeNull();
}
