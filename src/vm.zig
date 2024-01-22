const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const objects = @import("object.zig");
const mem = @import("memory.zig");

const Value = values.Value;
const ValueTypeTag = values.ValueTypeTag;
const OpCode = chunks.OpCode;
const allocator = @import("memory.zig").allocator;

const stdout = std.io.getStdOut().writer();

const STACK_MAX = 65536;

pub const VM = struct {
    chunk: *chunks.Chunk = undefined,
    ip: [*]u8 = undefined,
    stack: [STACK_MAX]values.Value = undefined,
    stack_top: [*]values.Value = undefined,
    globals: std.hash_map.StringHashMap(values.Value) = undefined,
    objects: ?*objects.Obj = null,
};

pub const InterpretResult = enum {
    ok,
    compiler_error,
    runtime_error,
};

pub var vm = VM{};
// pub const debug_mode = true;

pub fn initVM() void {
    vm.objects = null;

    vm.globals = std.hash_map.StringHashMap(values.Value).init(allocator);
    resetStack();
}

fn resetStack() void {
    vm.stack_top = &vm.stack;
}

fn runtimeError(comptime format: [*:0]const u8, args: anytype) void {
    const stderr = std.io.getStdErr().writer();
    stderr.print(format ++ "\n", args) catch {};
    const instruction: usize = @intFromPtr(vm.ip) - @intFromPtr(vm.chunk.code.items.ptr) - 1;
    stderr.print("[line {d}] in script\n", .{vm.chunk.lines.items[instruction]}) catch {};
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
    var chunk = chunks.Chunk{};
    chunks.initChunk(&chunk);

    if (!(try compiler.compile(source, &chunk))) {
        chunks.freeChunk(&chunk);
        return InterpretResult.compiler_error;
    }
    vm.chunk = &chunk;
    vm.ip = vm.chunk.code.items.ptr;

    const result: InterpretResult = run();

    chunks.freeChunk(&chunk);
    return result;
}

fn readByte() u8 {
    // const add: usize = 1;
    const result = vm.ip;
    vm.ip += 1;
    return result[0];
}

fn readShort() u16 {
    const b1: u16 = readByte();
    const b2: u16 = readByte();
    const result: u16 = (b1 * 256) + b2;
    return result;
}

fn readConstant() values.Value {
    return vm.chunk.constants.values.items[readByte()];
}

fn readConstant_16() values.Value {
    const big: u16 = readByte();
    const small: u16 = readByte();
    const index: u16 = (big * 256) + small;
    return vm.chunk.constants.values.items[index];
}

fn run() InterpretResult {
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
            const offset = vm.ip - @as(usize, @intFromPtr(vm.chunk.code.items.ptr));
            _ = debug.disassembleInstruction(vm.chunk, @intFromPtr(offset));
        }
        const instruction: u8 = readByte();
        switch (instruction) {
            @intFromEnum(OpCode.Constant) => {
                const constant = readConstant();
                push(constant);
            },
            @intFromEnum(OpCode.Constant_16) => {
                const constant = readConstant_16();
                push(constant);
            },
            @intFromEnum(OpCode.Null) => push(Value.makeNull()),
            @intFromEnum(OpCode.True) => push(Value.makeBool(true)),
            @intFromEnum(OpCode.False) => push(Value.makeBool(false)),
            @intFromEnum(OpCode.Pop) => {
                _ = pop();
            },
            @intFromEnum(OpCode.GetLocal) => {
                const slot: usize = readByte();
                push(vm.stack[slot]);
            },
            @intFromEnum(OpCode.GetLocal_16) => {
                const big: u16 = readByte();
                const small: u16 = readByte();
                const slot: usize = big * 256 + small;
                push(vm.stack[slot]);
            },
            @intFromEnum(OpCode.SetLocal) => {
                const slot: usize = readByte();
                vm.stack[slot] = peek(0);
            },
            @intFromEnum(OpCode.SetLocal_16) => {
                const big: u16 = readByte();
                const small: u16 = readByte();
                const slot: usize = big * 256 + small;
                vm.stack[slot] = peek(0);
            },
            @intFromEnum(OpCode.GetGlobal) => {
                const name = readConstant().asString();
                const value = vm.globals.get(name.chars);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                }
                push(value.?);
            },
            @intFromEnum(OpCode.GetGlobal_16) => {
                const name = readConstant_16().asString();
                const value = vm.globals.get(name.chars);
                if (value != null) {
                    push(value.?);
                } else {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                }
            },
            @intFromEnum(OpCode.DefineGlobal) => {
                const name: *objects.ObjString = readConstant().asString();
                vm.globals.put(name.chars, peek(0)) catch {};
                _ = pop();
            },
            @intFromEnum(OpCode.DefineGlobal_16) => {
                const name = readConstant_16().asString();
                vm.globals.put(name.chars, peek(0)) catch {};
                _ = pop();
            },
            @intFromEnum(OpCode.SetGlobal) => {
                const name = readConstant().asString();
                const value = vm.globals.get(name.chars);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                } else {
                    vm.globals.put(name.chars, peek(0)) catch {};
                }
            },
            @intFromEnum(OpCode.SetGlobal_16) => {
                const name = readConstant_16().asString();
                const value = vm.globals.get(name.chars);
                if (value == null) {
                    runtimeError("Undefined variable '{s}'.", .{name.chars});
                    return InterpretResult.runtime_error;
                } else {
                    vm.globals.put(name.chars, peek(0)) catch {};
                }
            },
            @intFromEnum(OpCode.Equal) => {
                const value_a = pop();
                const value_b = pop();
                push(Value.makeBool(values.valuesEqual(value_a, value_b)));
            },
            @intFromEnum(OpCode.Greater) => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeBool(value_a < value_b);
                push(new_value);
            },
            @intFromEnum(OpCode.Less) => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeBool(value_a > value_b);
                push(new_value);
            },
            @intFromEnum(OpCode.Add) => {
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
            @intFromEnum(OpCode.Subtract) => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b - value_a);
                push(new_value);
            },
            @intFromEnum(OpCode.Multiply) => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b * value_a);
                push(new_value);
            },
            @intFromEnum(OpCode.Divide) => {
                if (!peek(0).isNumber() and !peek(1).isNumber()) {
                    runtimeError("Operands must be numbers", .{});
                }
                const value_a = pop().as.number;
                const value_b = pop().as.number;
                const new_value = Value.makeNumber(value_b / value_a);
                push(new_value);
            },
            @intFromEnum(OpCode.Not) => {
                push(Value.makeBool(isFalsey(pop())));
            },
            @intFromEnum(OpCode.Negate) => {
                const value = peek(0);
                if (!value.isNumber()) {
                    runtimeError("Operand must be a number.", .{});
                    return InterpretResult.runtime_error;
                }
                const new_value = Value.makeNumber(0 - value.as.number);
                push(new_value);
            },
            @intFromEnum(OpCode.Print) => {
                values.printValue(pop());
                stdout.print("\n", .{}) catch {};
            },
            @intFromEnum(OpCode.Jump) => {
                const offset = readShort();
                vm.ip += offset;
            },
            @intFromEnum(OpCode.JumpIfFalse) => {
                const offset = readShort();
                if (isFalsey(peek(0))) vm.ip += offset;
            },
            @intFromEnum(OpCode.Loop) => {
                const offset = readShort();
                vm.ip -= offset;
            },
            @intFromEnum(OpCode.Return) => {
                //Exit interpreter.
                return InterpretResult.ok;
            },
            else => {
                return InterpretResult.runtime_error;
            },
        }
    }
    return InterpretResult.runtime_error;
}
