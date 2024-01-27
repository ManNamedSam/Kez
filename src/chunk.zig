const std = @import("std");

const mem = @import("memory.zig");
const values = @import("value.zig");

pub const OpCode = enum(u8) {
    Constant,
    Constant_16,
    Null,
    True,
    False,
    Pop,
    GetLocal,
    GetLocal_16,
    GetGlobal,
    GetGlobal_16,
    DefineGlobal,
    DefineGlobal_16,
    SetLocal,
    SetLocal_16,
    SetGlobal,
    SetGlobal_16,
    Equal,
    Greater,
    Less,
    Add,
    Subtract,
    Multiply,
    Divide,
    Not,
    Print,
    Negate,
    Jump,
    JumpIfFalse,
    Loop,
    Call,
    Closure,
    Closure_16,
    Return,
};

pub const Chunk = struct {
    code: *std.ArrayList(u8) = undefined,
    constants: values.ValueArray = undefined,
    lines: *std.ArrayList(u32) = undefined,
};

pub fn initChunk(chunk: *Chunk) !void {
    chunk.code = try mem.allocator.create(std.ArrayList(u8));
    chunk.code.* = std.ArrayList(u8).init(mem.allocator);
    chunk.lines = try mem.allocator.create(std.ArrayList(u32));
    chunk.lines.* = std.ArrayList(u32).init(mem.allocator);

    values.initValueArray(&chunk.constants) catch {};
}

pub fn writeChunk(chunk: *Chunk, byte: u8, line: u32) !void {
    if (chunk.code.capacity < chunk.code.items.len + 1) {
        const old_cap = chunk.code.items.len;
        const new_cap = mem.growCapacity(old_cap);
        mem.growArray(u8, chunk.code, old_cap, new_cap);
        mem.growArray(u32, chunk.lines, old_cap, new_cap);
    }
    chunk.code.appendAssumeCapacity(byte);
    chunk.lines.appendAssumeCapacity(line);
}

pub fn freeChunk(chunk: *Chunk) void {
    chunk.code.clearAndFree();
    mem.allocator.destroy(chunk.code);
    chunk.lines.clearAndFree();
    mem.allocator.destroy(chunk.lines);
    values.freeValueArray(&chunk.constants);
    initChunk(chunk) catch {};
}

pub fn addConstant(chunk: *Chunk, value: values.Value) !usize {
    try values.writeValueArray(&chunk.constants, value);
    const index = chunk.constants.values.items.len - 1;
    return index;
}
