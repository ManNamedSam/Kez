const std = @import("std");

const mem = @import("memory.zig");
const values = @import("value.zig");

pub const OpCode = enum(u8) {
    Constant,
    Return,
};

pub const Chunk = struct {
    code: std.ArrayList(u8) = std.ArrayList(u8).init(mem.allocator),
    constants: values.ValueArray = values.ValueArray{},
    lines: std.ArrayList(u32) = std.ArrayList(u32).init(mem.allocator),
};

pub fn init_chunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
    chunk.lines.clearAndFree();
    values.init_value_array(&chunk.constants);
}

pub fn write_chunk(chunk: *Chunk, byte: u8, line: u32) !void {
    try chunk.code.append(byte);
    try chunk.lines.append(line);
}

pub fn free_chunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
    chunk.lines.clearAndFree();
    values.free_value_array(&chunk.constants);
}

pub fn add_constant(chunk: *Chunk, value: values.Value) !u8 {
    try values.write_value_array(&chunk.constants, value);
    const index = chunk.constants.values.items.len - 1;
    if (index == 0) {
        return 0;
    }
    return @intCast(@mod(255, index));
}
