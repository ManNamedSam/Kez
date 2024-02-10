const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const objects = @import("object.zig");
const mem = @import("memory.zig");
const natives = @import("builtins/natives.zig");
const string_methods = @import("builtins/string_methods.zig");
const list_methods = @import("builtins/list_methods.zig");
const table_methods = @import("builtins/table_methods.zig");

const Value = values.Value;
const ValueTypeTag = values.ValueTypeTag;
const OpCode = chunks.OpCode;
const allocator = @import("memory.zig").allocator;

const stdout = std.io.getStdOut().writer();

const FRAMES_MAX = 2560;
const STACK_MAX = FRAMES_MAX * 256;

pub const VM = struct {
    frames: [FRAMES_MAX]CallFrame = undefined,
    frame_count: u16 = undefined,
    stack: [STACK_MAX]values.Value = undefined,
    stack_top: [*]values.Value = undefined,
    strings: std.hash_map.StringHashMap(*objects.ObjString) = undefined,
    init_string: ?*objects.ObjString = null,
    globals: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,

    string_methods: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,
    list_methods: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,
    table_methods: std.hash_map.AutoHashMap(*objects.ObjString, values.Value) = undefined,

    bytes_allocated: u64 = 0,
    next_gc: u64 = 8 * 1024,
    objects: ?*objects.Obj = null,
    open_upvalues: ?*objects.ObjUpvalue = null,

    gray_stack: *std.ArrayList(*objects.Obj) = undefined,
    gray_count: usize = 0,
    gray_capacity: usize = 0,
};

pub const CallFrame = struct {
    closure: *objects.ObjClosure,
    ip: [*]u8,
    slots: [*]Value,
};

pub const InterpretResult = enum {
    ok,
    compiler_error,
    runtime_error,
};

pub var vm = VM{};

pub fn initVM() !void {
    vm.objects = null;
    vm.gray_stack = try allocator.create(std.ArrayList(*objects.Obj));
    vm.gray_stack.* = std.ArrayList(*objects.Obj).init(allocator);

    vm.strings = std.hash_map.StringHashMap(*objects.ObjString).init(allocator);
    vm.globals = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);

    vm.string_methods = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);
    vm.list_methods = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);
    vm.table_methods = std.hash_map.AutoHashMap(*objects.ObjString, values.Value).init(allocator);

    resetStack();
    vm.init_string = null;
    vm.init_string = try objects.ObjString.copy("init", 4);

    defineNatives();
    defineStringMethods();
    defineListMethods();
    defineTableMethods();
}

fn defineNatives() void {
    defineNative("number", natives.numberNative, 1) catch {};
    defineNative("input", natives.inputNative, 1) catch {};
    defineNative("clock", natives.clockNative, 0) catch {};
    defineNative("clock_milli", natives.clockMilliNative, 0) catch {};
    defineNative("Table", natives.tableCreate, 0) catch {};
    defineNative("assert", natives.assert, 2) catch {};
}

fn defineStringMethods() void {
    defineStringMethod("length", string_methods.lengthStringMethod, 0) catch {};
    defineStringMethod("slice", string_methods.sliceStringMethod, 2) catch {};
}

fn defineListMethods() void {
    defineListMethod("append", list_methods.appendListMethod, 1) catch {};
    defineListMethod("length", list_methods.lengthListMethod, 0) catch {};
    defineListMethod("slice", list_methods.sliceListMethod, 2) catch {};
}

fn defineTableMethods() void {
    defineTableMethod("put", table_methods.addEntryTableMethod, 2) catch {};
    defineTableMethod("get", table_methods.getEntryTableMethod, 1) catch {};
    defineTableMethod("keys", table_methods.getKeysTableMethod, 0) catch {};
}

fn defineNative(name: []const u8, function: objects.NativeFn, num_args: ?u32) !void {
    push(Value.makeObj(@ptrCast(try objects.ObjString.copy(name.ptr, name.len))));
    push(Value.makeObj(@ptrCast(try objects.ObjNative.init(function, num_args))));
    vm.globals.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = pop();
    _ = pop();
}

fn defineStringMethod(name: []const u8, function: objects.ObjectMethodFn, num_args: ?u32) !void {
    push(Value.makeObj(@ptrCast(try objects.ObjString.copy(name.ptr, name.len))));
    push(Value.makeObj(@ptrCast(try objects.ObjObjectMethod.init(function, num_args, objects.ObjType.String))));
    vm.string_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = pop();
    _ = pop();
}

fn defineListMethod(name: []const u8, function: objects.ObjectMethodFn, num_args: ?u32) !void {
    push(Value.makeObj(@ptrCast(try objects.ObjString.copy(name.ptr, name.len))));
    push(Value.makeObj(@ptrCast(try objects.ObjObjectMethod.init(function, num_args, objects.ObjType.List))));
    vm.list_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = pop();
    _ = pop();
}

fn defineTableMethod(name: []const u8, function: objects.ObjectMethodFn, num_args: ?u32) !void {
    push(Value.makeObj(@ptrCast(try objects.ObjString.copy(name.ptr, name.len))));
    push(Value.makeObj(@ptrCast(try objects.ObjObjectMethod.init(function, num_args, objects.ObjType.Table))));
    vm.table_methods.put(vm.stack[0].asString(), vm.stack[1]) catch {};
    _ = pop();
    _ = pop();
}

pub fn freeVM() void {
    vm.strings.deinit();
    vm.globals.deinit();
    vm.string_methods.deinit();
    vm.list_methods.deinit();
    vm.table_methods.deinit();
    vm.init_string = null;
    mem.freeObjects();
}

fn resetStack() void {
    vm.stack_top = &vm.stack;
    vm.frame_count = 0;
}

pub fn runtimeError(comptime format: [*:0]const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print("ERROR: " ++ format ++ " @ ", args) catch {};

    var i: usize = vm.frame_count;
    while (i > 0) {
        i -= 1;
        const frame: *CallFrame = &vm.frames[i];
        const function = frame.closure.function;
        const instruction: usize = @intFromPtr(frame.ip) - @intFromPtr(frame.closure.function.chunk.code.items.ptr) - 1;
        stderr.print("[line {d}] in ", .{frame.closure.function.chunk.lines.items[instruction]}) catch {};
        if (function.name == null) {
            stderr.print("script\n", .{}) catch {};
        } else {
            stderr.print("{s}()\n", .{function.name.?.chars}) catch {};
        }
    }
    resetStack();
}

pub fn push(value: values.Value) void {
    vm.stack_top[0] = value;
    vm.stack_top += @as(usize, 1);
}

pub fn pop() values.Value {
    vm.stack_top -= @as(usize, 1);
    return vm.stack_top[0];
}

fn peek(distance: usize) values.Value {
    const item_ptr = vm.stack_top - (1 + distance);
    return item_ptr[0];
}

fn call(closure: *objects.ObjClosure, arg_count: u8) bool {
    if (arg_count != closure.function.arity) {
        runtimeError("Expected {d} arguments but got {d}.", .{ closure.function.arity, arg_count });
        return false;
    }

    if (vm.frame_count == FRAMES_MAX) {
        runtimeError("Stack overflow.", .{});
        return false;
    }

    const frame: *CallFrame = &vm.frames[vm.frame_count];
    vm.frame_count += 1;
    frame.closure = closure;
    frame.ip = closure.function.chunk.code.items.ptr;
    frame.slots = vm.stack_top - arg_count - 1;
    return true;
}

fn callObjectMethod(callee: Value, arg_count: u8, object: *objects.Obj) !bool {
    const method = callee.asObjectMethod();
    if (method.arity) |arity| {
        if (arg_count != method.arity.?) {
            runtimeError("Expected {d} arguments but got {d}.", .{ arity, arg_count });
            return false;
        }
    }
    const result = try method.function(object, arg_count, vm.stack_top - arg_count);
    vm.stack_top -= arg_count + 1;
    push(result);
    return true;
}

fn callValue(callee: Value, arg_count: u8) !bool {
    if (callee.isObj()) {
        switch (callee.as.obj.type) {
            objects.ObjType.BoundMethod => {
                const bound = callee.asBoundMethod();
                const slot = vm.stack_top - @as(usize, @intCast(arg_count)) - 1;
                slot[0] = bound.reciever;
                return call(bound.method, arg_count);
            },
            objects.ObjType.Closure => {
                return call(callee.asClosure(), arg_count);
            },
            objects.ObjType.Native => {
                const native = callee.asNative();
                if (native.arity) |arity| {
                    if (arg_count != arity) {
                        runtimeError("Expected {d} arguments but got {d}.", .{ arity, arg_count });
                        return false;
                    }
                }
                const result = native.function(arg_count, vm.stack_top - arg_count);
                if (result.isError()) {
                    return false;
                }
                vm.stack_top -= arg_count + 1;
                push(result);
                return true;
            },
            objects.ObjType.Class => {
                const class: *objects.ObjClass = callee.asClass();
                const slot = vm.stack_top - @as(usize, @intCast(arg_count)) - 1;
                const instance = try objects.ObjInstance.init(class);
                slot[0] = Value.makeObj(@ptrCast(instance));
                const initializer = class.methods.get(vm.init_string.?);
                if (initializer) |i| {
                    return call(i.asClosure(), arg_count);
                } else if (arg_count != 0) {
                    runtimeError("Expected 0 arguments but got {d}.", .{arg_count});
                    return false;
                }
                return true;
            },
            else => {},
        }
    }
    runtimeError("Can only call functions and classes", .{});
    return false;
}

fn invoke(name: *objects.ObjString, arg_count: u8) !bool {
    const receiver = peek(arg_count);

    if (receiver.isInstance()) {
        const instance = receiver.asInstance();

        const value_result = instance.fields.get(name);
        if (value_result) |value| {
            const slot = vm.stack_top - @as(usize, @intCast(arg_count)) - 1;
            slot[0] = value;
            return try callValue(value, arg_count);
        }
        return invokeFromClass(instance.class, name, arg_count);
    } else if (receiver.isList()) {
        const list = receiver.as.obj;
        const method_result = vm.list_methods.get(name);
        if (method_result) |method| {
            return try callObjectMethod(method, arg_count, list);
        }
        runtimeError("Invalid list method.", .{});
        return false;
    } else if (receiver.isString()) {
        const string = receiver.as.obj;
        const method_result = vm.string_methods.get(name);
        if (method_result) |method| {
            return try callObjectMethod(method, arg_count, string);
        }
        runtimeError("Invalid list method.", .{});
        return false;
    } else if (receiver.isTable()) {
        const table = receiver.as.obj;
        const method_result = vm.table_methods.get(name);
        if (method_result) |method| {
            return try callObjectMethod(method, arg_count, table);
        }
        runtimeError("Invalid table method.", .{});
        return false;
    }
    runtimeError("Only instances have methods.", .{});
    return false;
}

fn invokeFromClass(class: *objects.ObjClass, name: *objects.ObjString, arg_count: u8) bool {
    const method_result = class.methods.get(name);
    if (method_result) |method| {
        return call(method.asClosure(), arg_count);
    }
    runtimeError("Undefined property '{s}'.", .{name.chars});
    return false;
}

fn bindMethod(class: *objects.ObjClass, name: *objects.ObjString) !bool {
    const method_result = class.methods.get(name);

    if (method_result) |method| {
        const bound = try objects.ObjBoundMethod.init(peek(0), method.asClosure());
        _ = pop();
        push(Value.makeObj(@ptrCast(bound)));
        return true;
    }

    runtimeError("Undefined property '{s}'.", .{name.chars});
    return false;
}

fn captureUpvalue(local: [*]Value) !*objects.ObjUpvalue {
    var prev: ?*objects.ObjUpvalue = null;
    var upvalue = vm.open_upvalues;
    while (upvalue != null and @intFromPtr(upvalue.?.location) > @intFromPtr(&local[0])) {
        prev = upvalue;
        upvalue = upvalue.?.next;
    }

    if (upvalue != null and @intFromPtr(upvalue.?.location) == @intFromPtr(&local[0])) {
        return upvalue.?;
    }

    const createdUpvalue = try objects.ObjUpvalue.init(&local[0]);
    createdUpvalue.next = upvalue;
    if (prev == null) {
        vm.open_upvalues = createdUpvalue;
    } else {
        prev.?.next = createdUpvalue;
    }
    return createdUpvalue;
}

fn closeUpvalue(last: [*]Value) void {
    while (vm.open_upvalues != null and @intFromPtr(vm.open_upvalues.?.location) >= @intFromPtr(last)) {
        const upvalue = vm.open_upvalues.?;
        upvalue.closed = upvalue.location.*;
        upvalue.location = &upvalue.closed;
        vm.open_upvalues = upvalue.next;
    }
}

fn defineField(name: *objects.ObjString) void {
    const value = peek(0);
    const class = peek(1).asClass();
    class.addField(name, value);
    _ = pop();
}

fn defineMethod(name: *objects.ObjString) void {
    const method = peek(0);
    const class = peek(1).asClass();
    class.addMethod(name, method);
    _ = pop();
}

fn isFalsey(value: values.Value) bool {
    return value.isNull() or (value.isBool() and !value.as.bool);
}

fn concatenate() !void {
    const b = try values.valueToString(peek(0));
    const a: *objects.ObjString = peek(1).asString();
    const length = a.chars.len + b.len;
    var chars = try allocator.alloc(u8, length + 1);
    // const string = a.chars ++ b.chars;
    const string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ a.chars, b });
    std.mem.copyForwards(u8, chars, string);
    chars[length] = 0;

    const result = try objects.ObjString.take(chars, length);
    const res_obj: *objects.Obj = @ptrCast(result);
    _ = pop();
    _ = pop();
    push(Value.makeObj(res_obj));
}

pub fn interpret(source: []const u8) !InterpretResult {
    const function_result = compiler.compile(source);

    if (function_result) |function| {
        push(values.Value.makeObj(@ptrCast(function)));
        const closure = objects.ObjClosure.init(function) catch {
            return InterpretResult.compiler_error;
        };
        _ = pop();
        push(Value.makeObj(@ptrCast(closure)));
        _ = call(closure, 0);
    } else {
        return InterpretResult.compiler_error;
    }

    return try run();
}

fn readByte(frame: *CallFrame) u8 {
    const result = frame.ip;
    frame.ip += 1;
    return result[0];
}

fn readShort(frame: *CallFrame) u16 {
    const b1: u16 = readByte(frame);
    const b2: u16 = readByte(frame);
    const result: u16 = (b1 * 256) + b2;
    return result;
}

fn readConstant(frame: *CallFrame) values.Value {
    return frame.closure.function.chunk.constants.values.items[readByte(frame)];
}

fn readConstant_16(frame: *CallFrame) values.Value {
    return frame.closure.function.chunk.constants.values.items[readShort(frame)];
}

fn run() !InterpretResult {
    var frame: *CallFrame = &vm.frames[vm.frame_count - 1];

    while (true) {
        if (debug.debug_trace_stack) {
            std.debug.print("          ", .{});
            var slot: [*]values.Value = &vm.stack;
            const shift: usize = 1;
            while (@intFromPtr(slot) < @intFromPtr(vm.stack_top)) : (slot += shift) {
                std.debug.print("[ ", .{});
                values.printValue(slot[0]);
                std.debug.print(" ]", .{});
            }
            std.debug.print("\n", .{});
            const offset = frame.ip - @as(usize, @intFromPtr(frame.closure.function.chunk.code.items.ptr));
            _ = debug.disassembleInstruction(&frame.closure.function.chunk, @intFromPtr(offset));
        }
        const instruction: OpCode = @enumFromInt(readByte(frame));
        switch (instruction) {
            OpCode.Constant => {
                const constant = readConstant(frame);
                push(constant);
            },
            OpCode.Constant_16 => {
                const constant = readConstant_16(frame);
                push(constant);
            },
            OpCode.Null => push(Value.makeNull()),
            OpCode.True => push(Value.makeBool(true)),
            OpCode.False => push(Value.makeBool(false)),
            OpCode.Pop => {
                _ = pop();
            },
            OpCode.GetLocal => {
                const slot: usize = readByte(frame);
                push(frame.slots[slot]);
            },
            OpCode.GetLocal_16 => {
                const slot = readShort(frame);
                push(frame.slots[slot]);
            },
            OpCode.SetLocal => {
                const slot: usize = readByte(frame);
                frame.slots[slot] = peek(0);
            },
            OpCode.SetLocal_16 => {
                const slot = readShort(frame);
                frame.slots[slot] = peek(0);
            },
            OpCode.GetGlobal => {
                const name = readConstant(frame).asString();
                const value = vm.globals.get(name);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                }
                push(value.?);
            },
            OpCode.GetGlobal_16 => {
                const name = readConstant_16(frame).asString();
                const value = vm.globals.get(name);
                if (value != null) {
                    push(value.?);
                } else {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                }
            },
            OpCode.DefineGlobal => {
                const name: *objects.ObjString = readConstant(frame).asString();
                vm.globals.put(name, peek(0)) catch {};
                _ = pop();
            },
            OpCode.DefineGlobal_16 => {
                const name = readConstant_16(frame).asString();
                vm.globals.put(name, peek(0)) catch {};
                _ = pop();
            },
            OpCode.SetGlobal => {
                const name = readConstant(frame).asString();
                const value = vm.globals.get(name);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                } else {
                    vm.globals.put(name, peek(0)) catch {};
                }
            },
            OpCode.SetGlobal_16 => {
                const name = readConstant_16(frame).asString();
                const value = vm.globals.get(name);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                } else {
                    vm.globals.put(name, peek(0)) catch {};
                }
            },
            OpCode.GetUpvalue => {
                const slot = readByte(frame);
                push(frame.closure.upvalues[slot].?.location.*);
            },
            OpCode.SetUpvalue => {
                const slot = readByte(frame);
                frame.closure.upvalues[slot].?.location.* = peek(0);
            },
            OpCode.GetProperty => {
                if (!peek(0).isInstance()) {
                    runtimeError("Only instances have properties.", .{});
                    return InterpretResult.runtime_error;
                }
                const instance = peek(0).asInstance();
                const name = readConstant_16(frame).asString();

                const value_result = instance.fields.get(name);
                if (value_result) |value| {
                    _ = pop();
                    push(value);
                } else {
                    if (!(try bindMethod(instance.class, name))) {
                        return InterpretResult.runtime_error;
                    }
                    // runtimeError("Undefined property '{s}'.", .{name.chars});
                    // return InterpretResult.runtime_error;
                }
            },
            OpCode.SetProperty => {
                if (!peek(1).isInstance()) {
                    runtimeError("Only instances have fields.", .{});
                    return InterpretResult.runtime_error;
                }
                const instance = peek(1).asInstance();
                instance.setProperty(readConstant_16(frame).asString(), peek(0));
                const value = pop();
                _ = pop();
                push(value);
            },
            OpCode.GetSuper => {
                const name = readConstant_16(frame).asString();
                const superclass = pop().asClass();
                if (!(bindMethod(superclass, name) catch true)) {
                    return InterpretResult.runtime_error;
                }
            },
            OpCode.Equal => {
                const value_a = pop();
                const value_b = pop();
                push(Value.makeBool(values.valuesEqual(value_a, value_b)));
            },
            OpCode.Greater => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                    return InterpretResult.runtime_error;
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeBool(value_a < value_b);
                push(new_value);
            },
            OpCode.Less => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                    return InterpretResult.runtime_error;
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeBool(value_a > value_b);
                push(new_value);
            },
            OpCode.Add => {
                if (
                //     objects.isObjType(
                //     peek(0),
                //     objects.ObjType.String,
                // ) and
                objects.isObjType(
                    peek(1),
                    objects.ObjType.String,
                )) {
                    concatenate() catch {};
                } else if (peek(0).isNumber() and peek(1).isNumber()) {
                    const value_a = pop().as.number;
                    const value_b = pop().as.number;
                    const new_value = Value.makeNumber(value_a + value_b);
                    push(new_value);
                } else {
                    runtimeError("Operands must be numbers or a string concatenation", .{});
                    return InterpretResult.runtime_error;
                }
            },
            OpCode.Subtract => {
                if (!peek(0).isNumber() or !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                    return InterpretResult.runtime_error;
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b - value_a);
                push(new_value);
            },
            OpCode.Multiply => {
                if (!peek(0).isNumber() or !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                    return InterpretResult.runtime_error;
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b * value_a);
                push(new_value);
            },
            OpCode.Divide => {
                if (!peek(0).isNumber() or !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                    return InterpretResult.runtime_error;
                }
                const value_a = pop().as.number;
                if (value_a == 0) {
                    runtimeError("Denominator cannot be 0.", .{});
                    return InterpretResult.runtime_error;
                }
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b / value_a);
                push(new_value);
            },
            OpCode.Modulo => {
                if (!peek(0).isNumber() or !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers.", .{});
                    return InterpretResult.runtime_error;
                }
                const value_a = pop().as.number;
                if (value_a == 0) {
                    runtimeError("Denominator cannot be 0.", .{});
                    return InterpretResult.runtime_error;
                }
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(@mod(value_b, value_a));
                push(new_value);
            },
            OpCode.Not => {
                push(Value.makeBool(isFalsey(pop())));
            },
            OpCode.Negate => {
                const value = peek(0);
                if (!value.isNumber()) {
                    runtimeError("Operand must be a number.", .{});
                    return InterpretResult.runtime_error;
                }
                const new_value = Value.makeNumber(0 - value.as.number);
                push(new_value);
            },
            OpCode.Print => {
                values.printValue(pop());
                stdout.print("\n", .{}) catch {};
            },
            OpCode.Jump => {
                const offset = readShort(frame);
                frame.ip += offset;
            },
            OpCode.JumpIfFalse => {
                const offset = readShort(frame);
                if (isFalsey(peek(0))) frame.ip += offset;
            },
            OpCode.Loop => {
                const offset = readShort(frame);
                frame.ip -= offset;
            },
            OpCode.Call => {
                const arg_count = readByte(frame);
                if (!(try callValue(peek(arg_count), arg_count))) {
                    return InterpretResult.runtime_error;
                }
                frame = &vm.frames[vm.frame_count - 1];
            },
            OpCode.Invoke => {
                const method = readConstant_16(frame).asString();
                const arg_count = readByte(frame);
                if (!(try invoke(method, arg_count))) {
                    return InterpretResult.runtime_error;
                }
                frame = &vm.frames[vm.frame_count - 1];
            },
            OpCode.SuperInvoke => {
                const method = readConstant_16(frame).asString();
                const arg_count = readByte(frame);
                const superclass = pop().asClass();
                if (!invokeFromClass(superclass, method, arg_count)) {
                    return InterpretResult.runtime_error;
                }
                frame = &vm.frames[vm.frame_count - 1];
            },
            OpCode.Closure => {
                const function: *objects.ObjFunction = readConstant(frame).asFunction();
                const closure: *objects.ObjClosure = try objects.ObjClosure.init(function);
                push(Value.makeObj(@ptrCast(closure)));
                var i: usize = 0;
                while (i < closure.upvalue_count) : (i += 1) {
                    const is_local = readByte(frame);
                    const index = readByte(frame);
                    if (is_local == 1) {
                        // const local = frame.slots + index;
                        // _ = local; // autofix
                        closure.upvalues[i] = try captureUpvalue(frame.slots + index);
                    } else {
                        closure.upvalues[i] = frame.closure.upvalues[index];
                    }
                }
            },
            OpCode.Closure_16 => {
                const function: *objects.ObjFunction = readConstant_16(frame).asFunction();
                const closure: *objects.ObjClosure = try objects.ObjClosure.init(function);
                push(Value.makeObj(@ptrCast(closure)));
            },
            OpCode.CloseUpvalue => {
                closeUpvalue((vm.stack_top - 1));
                _ = pop();
            },
            OpCode.Return => {
                const result = pop();
                closeUpvalue(frame.slots);
                vm.frame_count -= 1;
                if (vm.frame_count == 0) {
                    _ = pop();
                    return InterpretResult.ok;
                }

                vm.stack_top = frame.slots;
                push(result);
                frame = &vm.frames[vm.frame_count - 1];
            },
            OpCode.Class => {
                const class = try objects.ObjClass.init(readConstant_16(frame).asString());
                push(Value.makeObj(@ptrCast(class)));
            },
            OpCode.Inherit => {
                const superclass = peek(1);
                if (!superclass.isClass()) {
                    runtimeError("Superclass must be a class.", .{});
                    return InterpretResult.runtime_error;
                }
                const subclass = peek(0).asClass();
                subclass.methods.* = try superclass.asClass().methods.clone();
                subclass.fields.* = try superclass.asClass().fields.clone();
                _ = pop();
            },
            OpCode.Field => defineField(readConstant_16(frame).asString()),
            OpCode.Method => defineMethod(readConstant_16(frame).asString()),
            OpCode.BuildList => {
                const list = try objects.ObjList.init();
                var item_count = readByte(frame);

                push(Value.makeObj(@ptrCast(list)));
                var i = item_count;
                while (i > 0) : (i -= 1) {
                    list.append(peek(i));
                }

                _ = pop();

                while (item_count > 0) : (item_count -= 1) {
                    _ = pop();
                }

                push(Value.makeObj(@ptrCast(list)));
            },
            OpCode.IndexSubscr => {
                if (!peek(1).isList()) {
                    runtimeError("Invalid type to index into.", .{});
                    return InterpretResult.runtime_error;
                }

                if (!peek(0).isNumber()) {
                    runtimeError("List index is not a number.", .{});
                    return InterpretResult.runtime_error;
                }

                const index: usize = @intFromFloat(pop().as.number);
                const list = pop().asList();

                if (!list.isValidIndex(@intCast(index))) {
                    runtimeError("List index out of range.", .{});
                    return InterpretResult.runtime_error;
                }

                const result = list.getByIndex(index);
                push(result);
            },
            OpCode.StoreSubscr => {
                if (!peek(2).isList()) {
                    runtimeError("Cannot store value to non-list.", .{});
                    return InterpretResult.runtime_error;
                }
                if (!peek(1).isNumber()) {
                    runtimeError("List index not a number.", .{});
                    return InterpretResult.runtime_error;
                }
                const item = pop();
                const index: usize = @intFromFloat(pop().as.number);
                const list = pop().asList();

                if (!list.isValidIndex(index)) {
                    runtimeError("List index out of range.", .{});
                    return InterpretResult.runtime_error;
                }

                list.store(index, item);
                push(item);
            },
        }
    }
    return InterpretResult.runtime_error;
}
