const std = @import("std");

const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const mem = @import("memory.zig");
const objects = @import("object.zig");
const VM = @import("vm.zig");

const stdin = std.io.getStdIn().reader();
const stdout = std.io.getStdIn().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    const virtual_machine = VM.VM{};
    const vm: *VM.VM = @constCast(&virtual_machine);
    mem.initVM(vm);
    objects.initVM(vm);
    chunks.initVM(vm);
    // vm.* = VM.VM{};
    try vm.init();

    var args = std.process.args();
    _ = args.skip();

    const file = args.next();

    if (args.skip()) {
        stderr.print("Usage: kez [path]\n", .{}) catch {};
        std.os.exit(64);
    }

    if (file) |f| {
        try runFile(vm, f);
    } else {
        try repl(vm);
    }

    vm.free();
}

fn repl(vm: *VM.VM) !void {
    var buf: [5000]u8 = undefined;
    while (true) {
        stdout.print("> ", .{}) catch {};

        if (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |line| {
            // stdout.print("\n", .{});
            _ = try vm.interpret(line);
        } else {
            stdout.print("\n", .{}) catch {};
            break;
        }
    }
}

fn runFile(vm: *VM.VM, path: []const u8) !void {
    const source: []const u8 = readFile(path);
    defer mem.allocator.free(source);

    const result: VM.InterpretResult = try vm.interpret(source);

    if (result == VM.InterpretResult.compiler_error) std.os.exit(65);
    if (result == VM.InterpretResult.runtime_error) std.os.exit(70);
}

pub fn readFile(path: []const u8) []const u8 {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Could not open file '{s}', error: {any}.\n", .{ path, err });
        std.os.exit(74);
    };
    defer file.close();

    return file.readToEndAlloc(mem.allocator, 100_000_000) catch |err| {
        std.debug.print("Could not read file '{s}', error: {any}.\n", .{ path, err });
        std.os.exit(74);
    };
}
