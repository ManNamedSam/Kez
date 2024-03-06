const std = @import("std");

const mem = @import("memory.zig");
const values = @import("value.zig");
const VM = @import("vm.zig");
var vm: *VM.VM = undefined;

pub fn initVM(_vm: *VM.VM) void {
    vm = _vm;
}

pub const Chunk = struct {
    code: *std.ArrayList(u8) = undefined,
    constants: values.ValueArray = undefined,
    lines: *std.ArrayList(u32) = undefined,

    pub fn init(self: *Chunk) !void {
        self.code = try mem.allocator.create(std.ArrayList(u8));
        self.code.* = std.ArrayList(u8).init(mem.allocator);
        self.lines = try mem.allocator.create(std.ArrayList(u32));
        self.lines.* = std.ArrayList(u32).init(mem.allocator);
        try self.constants.init();

        // values.initValueArray(&chunk.constants) catch {};
    }

    pub fn free(self: *Chunk) void {
        self.code.clearAndFree();
        mem.allocator.destroy(self.code);
        self.lines.clearAndFree();
        mem.allocator.destroy(self.lines);
        self.constants.free();
        self.init() catch {};
        // values.freeValueArray(&chunk.constants);
        // initChunk(chunk) catch {};
    }

    pub fn write(self: *Chunk, byte: u8, line: u32) !void {
        if (self.code.capacity < self.code.items.len + 1) {
            const old_cap = self.code.items.len;
            const new_cap = mem.growCapacity(old_cap);
            mem.growArray(u8, self.code, old_cap, new_cap);
            mem.growArray(u32, self.lines, old_cap, new_cap);
        }
        self.code.appendAssumeCapacity(byte);
        self.lines.appendAssumeCapacity(line);
    }

    pub fn addConstant(self: *Chunk, value: values.Value) !usize {
        vm.push(value);
        self.constants.write(value) catch {};
        // try values.writeValueArray(&chunk.constants, value);
        _ = vm.pop();
        const index = self.constants.values.items.len - 1;
        return index;
    }
};

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
    GetUpvalue,
    SetUpvalue,
    GetProperty,
    SetProperty,
    GetSuper,
    Equal,
    Greater,
    Less,
    Add,
    Subtract,
    Multiply,
    Divide,
    Modulo,
    Not,
    Print,
    Negate,
    Jump,
    JumpIfFalse,
    Loop,
    Call,
    Invoke,
    SuperInvoke,
    Closure,
    Closure_16,
    CloseUpvalue,
    Return,
    Import,
    Import_16,
    Class,
    Inherit,
    Field,
    Method,
    BuildList,
    IndexSubscr,
    StoreSubscr,
};
