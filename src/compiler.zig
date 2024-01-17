const std = @import("std");

const scanner = @import("scanner.zig");

pub fn compile(source: []const u8) void {
    scanner.initScanner(source);
    var line: u32 = 0;

    while (true) {
        const token = scanner.scanToken();
        if (token.line != line) {
            std.debug.print("{d:0>4} ", .{token.line});
            line = token.line;
        } else {
            std.debug.print("   | ", .{});
        }
        std.debug.print("{any:0>2} '{s}'\n", .{ @intFromEnum(token.type), token.start[0..token.length] });

        if (token.type == scanner.TokenType.eof or token.type == scanner.TokenType._error) break;
    }
}
