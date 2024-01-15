const std = @import("std");
const chunks = @import("chunk.zig");
const values = @import("value.zig");

pub fn disassemble_chunk(chunk: *chunks.Chunk, name: [*:0]const u8) void {
    std.debug.print("== {s} ==\n", .{name});

    var offset: usize = 0;

    while (offset < chunk.code.items.len) {
        offset = disassemble_instruction(chunk, offset);
    }
}

pub fn disassemble_instruction(chunk: *chunks.Chunk, offset: usize) usize {
    std.debug.print("{d:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        std.debug.print("   | ", .{});
    } else {
        std.debug.print("{d:4} ", .{chunk.lines.items[offset]});
    }

    const instruction: u8 = chunk.code.items[offset];
    switch (instruction) {
        @intFromEnum(chunks.OpCode.Constant) => return constant_instruction(
            "OP_CONSTANT",
            chunk,
            offset,
        ),
        @intFromEnum(chunks.OpCode.Add) => return simple_instruction("OP_ADD", offset),
        @intFromEnum(chunks.OpCode.Subtract) => return simple_instruction("OP_SUBTRACT", offset),
        @intFromEnum(chunks.OpCode.Multiply) => return simple_instruction("OP_MULTIPLY", offset),
        @intFromEnum(chunks.OpCode.Divide) => return simple_instruction("OP_DIVIDE", offset),
        @intFromEnum(chunks.OpCode.Negate) => return simple_instruction("OP_NEGATE", offset),
        @intFromEnum(chunks.OpCode.Return) => return simple_instruction("OP_RETURN", offset),
        else => {
            std.debug.print("Unknown OpCode {d}\n", .{instruction});
            return offset + 1;
        },
    }
}

fn constant_instruction(name: [*:0]const u8, chunk: *chunks.Chunk, offset: usize) usize {
    const constant: usize = chunk.code.items[offset + 1];
    std.debug.print("{s} {d:4} '", .{ name, constant });
    values.print_value(chunk.constants.values.items[constant]);
    std.debug.print("'\n", .{});
    return offset + 2;
}

fn simple_instruction(name: [*:0]const u8, offset: usize) usize {
    std.debug.print("{s}\n", .{name[0..]});
    return offset + 1;
}
