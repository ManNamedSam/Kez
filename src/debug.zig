const std = @import("std");
const chunks = @import("chunk.zig");
const values = @import("value.zig");

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
        @intFromEnum(chunks.OpCode.Constant) => return constantInstruction(
            "OP_CONSTANT",
            chunk,
            offset,
        ),
        @intFromEnum(chunks.OpCode.Add) => return simpleInstruction("OP_ADD", offset),
        @intFromEnum(chunks.OpCode.Subtract) => return simpleInstruction("OP_SUBTRACT", offset),
        @intFromEnum(chunks.OpCode.Multiply) => return simpleInstruction("OP_MULTIPLY", offset),
        @intFromEnum(chunks.OpCode.Divide) => return simpleInstruction("OP_DIVIDE", offset),
        @intFromEnum(chunks.OpCode.Negate) => return simpleInstruction("OP_NEGATE", offset),
        @intFromEnum(chunks.OpCode.Return) => return simpleInstruction("OP_RETURN", offset),
        else => {
            std.debug.print("Unknown OpCode {d}\n", .{instruction});
            return offset + 1;
        },
    }
}

fn constantInstruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    const constant: usize = chunk.code.items[offset + 1];
    std.debug.print("{s} {d:4} '", .{ name, constant });
    values.printValue(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn simpleInstruction(name: [*:0]const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name[0..]});
    return offset + 1;
}
