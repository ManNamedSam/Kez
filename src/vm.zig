const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const objects = @import("object.zig");
const mem = @import("memory.zig");
const natives = @import("natives.zig");

const Value = values.Value;
const ValueTypeTag = values.ValueTypeTag;
const OpCode = chunks.OpCode;
const allocator = @import("memory.zig").allocator;

const stdout = std.io.getStdOut().writer();

const FRAMES_MAX = 64;
const STACK_MAX = FRAMES_MAX * 256;

pub const VM = struct {
    frames: [FRAMES_MAX]CallFrame = undefined,
    frame_count: u16 = undefined,
    stack: [STACK_MAX]values.Value = undefined,
    stack_top: [*]values.Value = undefined,
    globals: std.hash_map.StringHashMap(values.Value) = undefined,
    objects: ?*objects.Obj = null,
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

pub fn initVM() void {
    vm.objects = null;

    vm.globals = std.hash_map.StringHashMap(values.Value).init(allocator);

    resetStack();
    defineNative("clock", natives.clockNative) catch {};
}

fn resetStack() void {
    vm.stack_top = &vm.stack;
    vm.frame_count = 0;
}

fn runtimeError(comptime format: [*:0]const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ "\n", args) catch {};

    var i = vm.frame_count - 1;
    while (i >= 0) : (i -= 1) {
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

fn defineNative(name: []const u8, function: objects.NativeFn) !void {
    push(Value.makeObj(@ptrCast(try objects.copyString(name.ptr, name.len))));
    push(Value.makeObj(@ptrCast(try objects.newNative(function))));
    vm.globals.put(vm.stack[0].asString().chars, vm.stack[1]) catch {};
    _ = pop();
    _ = pop();
}

fn push(value: values.Value) void {
    vm.stack_top[0] = value;
    vm.stack_top += @as(usize, 1);
}

fn pop() values.Value {
    vm.stack_top -= @as(usize, 1);
    return vm.stack_top[0];
}

fn peek(distance: usize) values.Value {
    const item_ptr = vm.stack_top - (1 + distance);
    return item_ptr[0];
}

fn callValue(callee: Value, arg_count: u8) bool {
    if (callee.isObj()) {
        switch (callee.as.obj.type) {
            objects.ObjType.Closure => {
                return call(callee.asClosure(), arg_count);
            },
            objects.ObjType.Native => {
                const native = callee.asNative();
                const result = native(arg_count, vm.stack_top - arg_count);
                vm.stack_top -= arg_count + 1;
                push(result);
                return true;
            },
            else => {},
        }
    }
    runtimeError("Can only call functions and classes", .{});
    return false;
}

fn captureUpvalue(local: [*]Value) !*objects.ObjUpvalue {
    const createdUpvalue = try objects.newUpvalue(&local[0]);
    return createdUpvalue;
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

fn isFalsey(value: values.Value) bool {
    return value.isNull() or (value.isBool() and !value.as.bool);
}

fn concatenate() !void {
    const b: *objects.ObjString = pop().asString();
    const a: *objects.ObjString = pop().asString();
    const length = a.chars.len + b.chars.len;
    var chars = try allocator.alloc(u8, length + 1);
    // const string = a.chars ++ b.chars;
    const string = try std.fmt.allocPrint(allocator, "{s}{s}", .{ a.chars, b.chars });
    std.mem.copyForwards(u8, chars, string);
    chars[length] = 0;

    const result = try objects.takeString(chars, length);
    const res_obj: *objects.Obj = @ptrCast(result);
    push(Value.makeObj(res_obj));
}

pub fn freeVM() void {
    vm.globals.deinit();
    mem.freeObjects();
}

pub fn interpret(source: []const u8) !InterpretResult {
    const function_result = compiler.compile(source);

    if (function_result) |function| {
        push(values.Value.makeObj(@ptrCast(function)));
        const closure = objects.newClosure(function) catch {
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
                const value = vm.globals.get(name.chars);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                }
                push(value.?);
            },
            OpCode.GetGlobal_16 => {
                const name = readConstant_16(frame).asString();
                const value = vm.globals.get(name.chars);
                if (value != null) {
                    push(value.?);
                } else {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                }
            },
            OpCode.DefineGlobal => {
                const name: *objects.ObjString = readConstant(frame).asString();
                vm.globals.put(name.chars, peek(0)) catch {};
                _ = pop();
            },
            OpCode.DefineGlobal_16 => {
                const name = readConstant_16(frame).asString();
                vm.globals.put(name.chars, peek(0)) catch {};
                _ = pop();
            },
            OpCode.SetGlobal => {
                const name = readConstant(frame).asString();
                const value = vm.globals.get(name.chars);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                } else {
                    vm.globals.put(name.chars, peek(0)) catch {};
                }
            },
            OpCode.SetGlobal_16 => {
                const name = readConstant_16(frame).asString();
                const value = vm.globals.get(name.chars);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                } else {
                    vm.globals.put(name.chars, peek(0)) catch {};
                }
            },
            OpCode.GetUpvalue => {
                const slot = readByte(frame);
                push(frame.closure.upvalues[slot].location.*);
            },
            OpCode.SetUpvalue => {
                const slot = readByte(frame);
                frame.closure.upvalues[slot].location.* = peek(0);
            },
            OpCode.Equal => {
                const value_a = pop();
                const value_b = pop();
                push(Value.makeBool(values.valuesEqual(value_a, value_b)));
            },
            OpCode.Greater => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeBool(value_a < value_b);
                push(new_value);
            },
            OpCode.Less => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeBool(value_a > value_b);
                push(new_value);
            },
            OpCode.Add => {
                if (objects.isObjType(
                    peek(0),
                    objects.ObjType.String,
                ) and objects.isObjType(
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
                    runtimeError("Operands must be numbers", .{});
                }
            },
            OpCode.Subtract => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b - value_a);
                push(new_value);
            },
            OpCode.Multiply => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b * value_a);
                push(new_value);
            },
            OpCode.Divide => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b / value_a);
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
                if (!callValue(peek(arg_count), arg_count)) {
                    return InterpretResult.runtime_error;
                }
                frame = &vm.frames[vm.frame_count - 1];
            },
            OpCode.Closure => {
                const function: *objects.ObjFunction = readConstant(frame).asFunction();
                const closure: *objects.ObjClosure = try objects.newClosure(function);
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
                const closure: *objects.ObjClosure = try objects.newClosure(function);
                push(Value.makeObj(@ptrCast(closure)));
            },
            OpCode.Return => {
                const result = pop();
                vm.frame_count -= 1;
                if (vm.frame_count == 0) {
                    _ = pop();
                    return InterpretResult.ok;
                }

                vm.stack_top = frame.slots;
                push(result);
                frame = &vm.frames[vm.frame_count - 1];
            },
        }
    }
    return InterpretResult.runtime_error;
}
