const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");

const STACK_MAX = 256;

pub const VM = struct {
    chunk: *chunks.Chunk = undefined,
    ip: [*]u8 = undefined,
    stack: [STACK_MAX]values.Value = undefined,
    stack_top: [*]values.Value = undefined,
};

pub const InterpretResult = enum {
    ok,
    compiler_error,
    runtime_error,
};

var vm = VM{};
pub const debug_mode = true;

pub fn initVM() void {
    resetStack();
}

fn resetStack() void {
    vm.stack_top = &vm.stack;
}

fn push(value: values.Value) void {
    vm.stack_top[0] = value;
    vm.stack_top += @as(usize, 1);
}

fn pop() values.Value {
    vm.stack_top -= @as(usize, 1);
    return vm.stack_top[0];
}

pub fn freeVM() void {}

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

fn readConstant() values.Value {
    return vm.chunk.constants.values.items[readByte()];
}

fn readConstant_16() values.Value {
    const index: u16 = (readByte() * 255) + readByte();
    return vm.chunk.constants.values.items[index];
}

fn run() InterpretResult {
    while (true) {
        // if (debug_mode) {
        //     std.debug.print("          ", .{});
        //     var slot: [*]values.Value = &vm.stack;
        //     const shift: usize = 1;
        //     while (@intFromPtr(slot) < @intFromPtr(vm.stack_top)) : (slot += shift) {
        //         std.debug.print("[ ", .{});
        //         values.printValue(slot[0]);
        //         std.debug.print(" ]", .{});
        //     }
        //     std.debug.print("\n", .{});
        //     const offset = vm.ip - @as(usize, @intFromPtr(vm.chunk.code.items.ptr));
        //     _ = debug.disassembleInstruction(vm.chunk, @intFromPtr(offset));
        // }
        const instruction: u8 = readByte();
        switch (instruction) {
            @intFromEnum(chunks.OpCode.Constant) => {
                const constant = readConstant();
                push(constant);
            },
            @intFromEnum(chunks.OpCode.Constant_16) => {
                const constant = readConstant_16();
                push(constant);
            },
            @intFromEnum(chunks.OpCode.Add) => {
                const value_a = pop().value;
                const value_b = pop().value;
                const new_value = values.Value{ .value = value_a + value_b };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Subtract) => {
                const value_a = pop().value;
                const value_b = pop().value;
                const new_value = values.Value{ .value = value_b - value_a };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Multiply) => {
                const value_a = pop().value;
                const value_b = pop().value;
                const new_value = values.Value{ .value = value_a * value_b };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Divide) => {
                const value_a = pop().value;
                const value_b = pop().value;
                const new_value = values.Value{ .value = value_b / value_a };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Negate) => {
                const value = pop().value;
                const new_value = values.Value{ .value = 0 - value };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Return) => {
                values.printValue(pop());
                std.debug.print("\n", .{});
                return InterpretResult.ok;
            },
            else => {
                return InterpretResult.runtime_error;
            },
        }
    }
    return InterpretResult.runtime_error;
}
