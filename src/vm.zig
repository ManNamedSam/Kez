const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");

const STACK_MAX = 256;

pub const VM = struct {
    chunk: *chunks.Chunk = undefined,
    ip: [*]u8 = undefined,
    stack: [STACK_MAX]values.Value = undefined,
    stack_top: [*]values.Value = undefined,
};

pub const InterpretResult = enum {
    INTERPRET_OK,
    INTERPRET_COMPILE_ERROR,
    INTERPRET_RUNTIME_ERROR,
};

var vm = VM{};
var debug_mode = true;

pub fn init_VM() void {
    reset_stack();
}

fn reset_stack() void {
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

pub fn free_VM() void {}

pub fn interpret(chunk: *chunks.Chunk) InterpretResult {
    vm.chunk = chunk;
    vm.ip = vm.chunk.code.items.ptr;
    return run();
}

fn read_byte() u8 {
    // const add: usize = 1;
    const result = vm.ip;
    vm.ip += 1;
    return result[0];
}

fn read_constant() values.Value {
    return vm.chunk.constants.values.items[read_byte()];
}

fn run() InterpretResult {
    while (true) {
        if (debug_mode) {
            std.debug.print("          ", .{});
            var slot: [*]values.Value = &vm.stack;
            const shift: usize = 1;
            while (@intFromPtr(slot) < @intFromPtr(vm.stack_top)) : (slot += shift) {
                std.debug.print("[ ", .{});
                values.print_value(slot[0]);
                std.debug.print(" ]", .{});
            }
            std.debug.print("\n", .{});
            const offset = vm.ip - @as(usize, @intFromPtr(vm.chunk.code.items.ptr));
            _ = debug.disassemble_instruction(vm.chunk, @intFromPtr(offset));
        }
        const instruction: u8 = read_byte();
        switch (instruction) {
            @intFromEnum(chunks.OpCode.Constant) => {
                const constant = read_constant();
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
                const new_value = values.Value{ .value = value_a - value_b };
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
                const new_value = values.Value{ .value = value_a / value_b };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Negate) => {
                const value = pop().value;
                const new_value = values.Value{ .value = 0 - value };
                push(new_value);
            },
            @intFromEnum(chunks.OpCode.Return) => {
                values.print_value(pop());
                std.debug.print("\n", .{});
                return InterpretResult.INTERPRET_OK;
            },
            else => {
                return InterpretResult.INTERPRET_RUNTIME_ERROR;
            },
        }
    }
    return InterpretResult.INTERPRET_RUNTIME_ERROR;
}
