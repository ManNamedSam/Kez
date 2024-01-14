const std = @import("std");

const chunks = @import("chunk.zig");

pub fn main() !void {
    var chunk = chunks.Chunk{};
    chunks.init_chunk(&chunk);
    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Return));
    chunks.free_chunk(&chunk);
}
