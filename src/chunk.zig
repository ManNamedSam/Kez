const std = @import("std");

const mem = @import("memory.zig");

pub const OpCode = enum(u8) {
    Return,
};

pub const Chunk = struct {
    code: std.ArrayList(u8) = std.ArrayList(u8).init(mem.allocator),
};

pub fn init_chunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
}

pub fn write_chunk(chunk: *Chunk, byte: u8) !void {
    try chunk.code.append(byte);
}

pub fn free_chunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
}
