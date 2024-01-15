const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");

pub fn main() !void {
    var chunk = chunks.Chunk{};
    chunks.init_chunk(&chunk);

    const constant: u8 = try chunks.add_constant(&chunk, values.Value{ .value = 1.2 });
    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Constant), 123);
    try chunks.write_chunk(&chunk, constant, 123);

    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Return), 123);
    debug.disassemble_chunk(&chunk, "test chunk");
    chunks.free_chunk(&chunk);
}
