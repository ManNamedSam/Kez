const std = @import("std");

const mem = @import("memory.zig");
const values = @import("value.zig");

pub const OpCode = enum(u8) {
    Constant,
    Constant_16,
    Add,
    Subtract,
    Multiply,
    Divide,
    Negate,
    Return,
};

pub const Chunk = struct {
    code: std.ArrayList(u8) = std.ArrayList(u8).init(mem.allocator),
    constants: values.ValueArray = values.ValueArray{},
    lines: std.ArrayList(u32) = std.ArrayList(u32).init(mem.allocator),
};

pub fn initChunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
    chunk.lines.clearAndFree();
    values.initValueArray(&chunk.constants);
}

pub fn writeChunk(chunk: *Chunk, byte: u8, line: u32) !void {
    try chunk.code.append(byte);
    try chunk.lines.append(line);
}

pub fn freeChunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
    chunk.lines.clearAndFree();
    values.freeValueArray(&chunk.constants);
}

pub fn addConstant(chunk: *Chunk, value: values.Value) !usize {
    try values.writeValueArray(&chunk.constants, value);
    const index = chunk.constants.values.items.len - 1;
    return index;
}
