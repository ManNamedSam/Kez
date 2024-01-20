const std = @import("std");

const stderr = std.io.getStdErr().writer();

const scanner = @import("scanner.zig");
const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const object = @import("object.zig");

//types
const Chunk = chunks.Chunk;
const OpCode = chunks.OpCode;
const Token = scanner.Token;
const TokenType = scanner.TokenType;
const Value = @import("value.zig").Value;

// const debug_mode = @import("vm.zig").debug_mode;

const Parser = struct {
    current: Token = undefined,
    previous: Token = undefined,
    hadError: bool = false,
    panicMode: bool = false,
};

const Precedence = enum {
    none,
    assignment,
    or_,
    and_,
    equality,
    comparison,
    term,
    factor,
    unary,
    call,
    primary,
};

const ParseFn = *const fn () anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence = Precedence.none,
};

var parser: Parser = Parser{};
var compilingChunk: *Chunk = undefined;

fn currentChunk() *Chunk {
    return compilingChunk;
}

pub fn compile(source: []const u8, chunk: *Chunk) !bool {
    scanner.initScanner(source);
    compilingChunk = chunk;

    parser.hadError = false;
    parser.panicMode = false;

    try advance();
    try expression();
    try consume(TokenType.eof, "Expect end of expression.");
    try endCompiler();
    return !parser.hadError;
}

fn advance() !void {
    parser.previous = parser.current;

    while (true) {
        parser.current = scanner.scanToken();
        if (parser.current.type != TokenType.error_) break;

        try errorAtCurrent(parser.current.start[0..parser.current.length :0].ptr);
    }
}

fn consume(token_type: TokenType, message: [*:0]const u8) !void {
    if (parser.current.type == token_type) {
        try advance();
        return;
    }

    try errorAtCurrent(message);
}

fn emitByte(byte: u8) !void {
    try chunks.writeChunk(currentChunk(), byte, parser.previous.line);
}

fn emitBytes(byte_1: u8, byte_2: u8) !void {
    try emitByte(byte_1);
    try emitByte(byte_2);
}

fn emitReturn() !void {
    try emitByte(@intFromEnum(OpCode.Return));
}

fn makeConstant(value: values.Value) !u16 {
    const constant = try chunks.addConstant(currentChunk(), value);
    if (constant > 65535) {
        try error_("Too many constants in one chunk.");
        return 0;
    }

    return @intCast(@mod(constant, 65536));
}

fn emitConstant(value: values.Value) !void {
    const constant = try makeConstant(value);
    if (constant <= 255) {
        try emitBytes(@intFromEnum(OpCode.Constant), @as(u8, @intCast(@mod(constant, 256))));
    } else {
        try emitByte(@intFromEnum(OpCode.Constant_16));
        const byte_1: u8 = @intCast(@mod(@divFloor(constant, 256), 256));
        const byte_2: u8 = @intCast(@mod(constant, 256));
        try emitBytes(byte_1, byte_2);
    }
}

fn endCompiler() !void {
    try emitReturn();
    if (debug.debug_print) {
        if (!parser.hadError) {
            debug.disassembleChunk(currentChunk(), "code");
        }
    }
}

fn binary() !void {
    const operatorType = parser.previous.type;
    const rule = getRule(operatorType);
    try parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

    switch (operatorType) {
        TokenType.bang_equal => try emitBytes(@intFromEnum(OpCode.Equal), @intFromEnum(OpCode.Not)),
        TokenType.equal_equal => try emitByte(@intFromEnum(OpCode.Equal)),
        TokenType.greater => try emitByte(@intFromEnum(OpCode.Greater)),
        TokenType.greater_equal => try emitBytes(@intFromEnum(OpCode.Less), @intFromEnum(OpCode.Not)),
        TokenType.less => try emitByte(@intFromEnum(OpCode.Less)),
        TokenType.less_equal => try emitBytes(@intFromEnum(OpCode.Greater), @intFromEnum(OpCode.Not)),
        TokenType.plus => try emitByte(@intFromEnum(OpCode.Add)),
        TokenType.minus => try emitByte(@intFromEnum(OpCode.Subtract)),
        TokenType.star => try emitByte(@intFromEnum(OpCode.Multiply)),
        TokenType.slash => try emitByte(@intFromEnum(OpCode.Divide)),
        else => return,
    }
}

fn literal() !void {
    switch (parser.previous.type) {
        TokenType.false_keyword => try emitByte(@intFromEnum(OpCode.False)),
        TokenType.null_keyword => try emitByte(@intFromEnum(OpCode.Null)),
        TokenType.true_keyword => try emitByte(@intFromEnum(OpCode.True)),
        else => return,
    }
}

fn grouping() !void {
    try expression();
    try consume(TokenType.right_paren, "Expect ')' after expression.");
}

fn number() !void {
    const value: f64 = try std.fmt.parseFloat(f64, parser.previous.start[0..parser.previous.length]);
    try emitConstant(Value.makeNumber(value));
}

fn string() !void {
    const obj_string = try object.copyString(parser.previous.start + 1, parser.previous.length - 2);
    const obj: *object.Obj = @ptrCast(obj_string);
    emitConstant(Value.makeObj(obj)) catch {};
}

fn unary() !void {
    const operatorType = parser.previous.type;

    //compile the operand.
    try parsePrecedence(Precedence.unary);

    //Emit the operator instruction.
    switch (operatorType) {
        TokenType.bang => try emitByte(@intFromEnum(OpCode.Not)),
        TokenType.minus => try emitByte(@intFromEnum(OpCode.Negate)),
        else => return,
    }
}

fn parsePrecedence(precedence: Precedence) !void {
    try advance();
    const prefixRule_option = getRule(parser.previous.type).prefix;
    if (prefixRule_option) |prefixRule| {
        try prefixRule();
    } else {
        try error_("Expect expression.");
        return;
    }

    while (@intFromEnum(precedence) <= @intFromEnum(getRule(parser.current.type).precedence)) {
        try advance();
        const infixRule_option = getRule(parser.previous.type).infix;
        if (infixRule_option) |infixRule| {
            try infixRule();
        }
    }
}

fn expression() !void {
    try parsePrecedence(Precedence.assignment);
}

fn errorAtCurrent(message: [*:0]const u8) !void {
    try errorAt(&parser.current, message);
}

fn error_(message: [*:0]const u8) !void {
    try errorAt(&parser.previous, message);
}

fn errorAt(token: *Token, message: [*:0]const u8) !void {
    if (parser.panicMode) return;
    parser.panicMode = true;
    try stderr.print("[line {d}] Error", .{token.line});

    if (token.type == TokenType.eof) {
        try stderr.print(" at end", .{});
    } else if (token.type == TokenType.error_) {} else {
        try stderr.print(" at '{s}'", .{token.start[0..token.length]});
    }

    try stderr.print(": {s}\n", .{message[0..]});
    parser.hadError = true;
}

fn getRule(token_type: TokenType) ParseRule {
    switch (token_type) {
        TokenType.left_paren => return ParseRule{ .prefix = grouping },
        TokenType.minus => return ParseRule{ .prefix = unary, .infix = binary, .precedence = Precedence.term },
        TokenType.plus => return ParseRule{ .infix = binary, .precedence = Precedence.term },
        TokenType.slash => return ParseRule{ .infix = binary, .precedence = Precedence.factor },
        TokenType.star => return ParseRule{ .infix = binary, .precedence = Precedence.factor },
        TokenType.bang => return ParseRule{ .prefix = unary },
        TokenType.bang_equal => return ParseRule{ .infix = binary, .precedence = Precedence.equality },
        TokenType.equal_equal => return ParseRule{ .infix = binary, .precedence = Precedence.equality },
        TokenType.greater => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.greater_equal => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.less => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.less_equal => return ParseRule{ .infix = binary, .precedence = Precedence.comparison },
        TokenType.string => return ParseRule{ .prefix = string },
        TokenType.number => return ParseRule{ .prefix = number },
        TokenType.false_keyword => return ParseRule{ .prefix = literal },
        TokenType.null_keyword => return ParseRule{ .prefix = literal },
        TokenType.true_keyword => return ParseRule{ .prefix = literal },
        else => return ParseRule{},
    }
}
