const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const VM = @import("vm.zig");

pub fn main() !void {
    VM.init_VM();

    var chunk = chunks.Chunk{};
    chunks.init_chunk(&chunk);

    var constant: u8 = try chunks.add_constant(&chunk, values.Value{ .value = 1.2 });
    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Constant), 123);
    try chunks.write_chunk(&chunk, constant, 123);

    constant = try chunks.add_constant(&chunk, values.Value{ .value = 3.4 });
    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Constant), 123);
    try chunks.write_chunk(&chunk, constant, 123);

    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Add), 123);

    constant = try chunks.add_constant(&chunk, values.Value{ .value = 5.6 });
    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Constant), 123);
    try chunks.write_chunk(&chunk, constant, 123);

    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Divide), 123);

    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Negate), 123);

    try chunks.write_chunk(&chunk, @intFromEnum(chunks.OpCode.Return), 123);
    // debug.disassemble_chunk(&chunk, "test chunk");
    _ = VM.interpret(&chunk);
    VM.free_VM();
    chunks.free_chunk(&chunk);
}
