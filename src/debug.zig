const std = @import("std");
const chunks = @import("chunk.zig");
const values = @import("value.zig");

const OpCode = chunks.OpCode;

pub const debug_print = false;
pub const debug_trace_stack = false;

pub fn disassembleChunk(chunk: *chunks.Chunk, name: [*:0]const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;

    while (offset < chunk.code.items.len) {
        offset = disassembleInstruction(chunk, offset);
    }
}

pub fn disassembleInstruction(chunk: *chunks.Chunk, offset: usize) usize {
    std.debug.print("{d:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:4} ", .{chunk.lines.items[offset]});
    }

    const instruction: u8 = chunk.code.items[offset];
    switch (instruction) {
        @intFromEnum(OpCode.Constant) => return constantInstruction(
            "OP_CONSTANT",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.Constant_16) => return constant16Instruction(
            "OP_CONSTANT_16",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.Null) => return simpleInstruction("OP_NULL", offset),
        @intFromEnum(OpCode.True) => return simpleInstruction("OP_TRUE", offset),
        @intFromEnum(OpCode.False) => return simpleInstruction("OP_FALSE", offset),
        @intFromEnum(OpCode.GetLocal) => return byteInstruction("OP_GET_LOCAL", chunk, offset),
        @intFromEnum(OpCode.GetLocal_16) => return byteInstruction_16("OP_GET_LOCAL_16", chunk, offset),
        @intFromEnum(OpCode.SetLocal) => return byteInstruction("OP_SET_LOCAL", chunk, offset),
        @intFromEnum(OpCode.SetLocal_16) => return byteInstruction_16("OP_SET_LOCAL_16", chunk, offset),
        @intFromEnum(OpCode.GetGlobal) => return constantInstruction(
            "OP_GET_GLOBAL",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.GetGlobal_16) => return constant16Instruction(
            "OP_GET_GLOBAL_16",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.DefineGlobal) => return constantInstruction(
            "OP_DEFINE_GLOBAL",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.DefineGlobal_16) => return constant16Instruction(
            "OP_DEFINE_GLOBAL_16",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.SetGlobal) => return constantInstruction(
            "OP_SET_GLOBAL_16",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.SetGlobal_16) => return constant16Instruction(
            "OP_SET_GLOBAL_16",
            chunk,
            offset,
        ),
        @intFromEnum(OpCode.Equal) => return simpleInstruction("OP_EQUAL", offset),
        @intFromEnum(OpCode.Pop) => return simpleInstruction("OP_POP", offset),
        @intFromEnum(OpCode.Greater) => return simpleInstruction("OP_GREATER", offset),
        @intFromEnum(OpCode.Less) => return simpleInstruction("OP_LESS", offset),
        @intFromEnum(OpCode.Add) => return simpleInstruction("OP_ADD", offset),
        @intFromEnum(OpCode.Subtract) => return simpleInstruction("OP_SUBTRACT", offset),
        @intFromEnum(OpCode.Multiply) => return simpleInstruction("OP_MULTIPLY", offset),
        @intFromEnum(OpCode.Divide) => return simpleInstruction("OP_DIVIDE", offset),
        @intFromEnum(OpCode.Not) => return simpleInstruction("OP_NOT", offset),
        @intFromEnum(OpCode.Negate) => return simpleInstruction("OP_NEGATE", offset),
        @intFromEnum(OpCode.Print) => return simpleInstruction("OP_PRINT", offset),
        @intFromEnum(OpCode.Jump) => return jumpInstruction("OP_JUMP", 1, chunk, offset),
        @intFromEnum(OpCode.JumpIfFalse) => return jumpInstruction("OP_JUMP_IF_FALSE", 1, chunk, offset),
        @intFromEnum(OpCode.Loop) => return jumpInstruction("OP_LOOP", -1, chunk, offset),
        @intFromEnum(OpCode.Return) => return simpleInstruction("OP_RETURN", offset),
        else => {
            std.debug.print("Unknown OpCode {d}\n", .{instruction});
            return offset + 1;
        },
    }
}

fn constantInstruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    var constant: usize = undefined;
    var new_offset = offset + 1;

    constant = chunk.code.items[offset + 1];
    new_offset += 1;

    std.debug.print("{s} {d:4} '", .{ name, constant });
    values.printValue(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return new_offset;
}

fn constant16Instruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    var constant: usize = undefined;
    var new_offset = offset + 1;

    const big_end: u16 = chunk.code.items[offset + 1];
    const little_end: u16 = chunk.code.items[offset + 2];
    constant = (big_end * 256) + little_end;
    new_offset += 2;

    std.debug.print("{s} {d:4} '", .{ name, constant });
    values.printValue(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return new_offset;
}

fn simpleInstruction(name: [*:0]const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name[0..]});
    return offset + 1;
}

fn byteInstruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    const slot: usize = chunk.code[offset + 1];
    std.debug.print("{s} {d:4}", .{ name, slot });
    return offset + 2;
}

fn byteInstruction_16(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    const slot: usize = chunk.code[offset + 1] * 256 + chunk.code[offset + 2];
    std.debug.print("{s} {d:4}", .{ name, slot });
    return offset + 3;
}

fn jumpInstruction(name: [*:0]const u8, sign: i32, chunk: *chunks.Chunk, offset: usize) usize {
    const jump: usize = chunk.code[offset + 1] * 256 + chunk.code[offset + 2];
    std.debug.print("{s} {d} -> {d}", .{ name, offset, offset + 3 + sign * jump });
    return offset + 3;
}
