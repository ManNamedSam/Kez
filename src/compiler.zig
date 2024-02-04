const std = @import("std");

const stderr = std.io.getStdErr().writer();

const scanner = @import("scanner.zig");
const chunks = @import("chunk.zig");
const values = @import("value.zig");
const debug = @import("debug.zig");
const object = @import("object.zig");
const mem = @import("memory.zig");

//types
const Chunk = chunks.Chunk;
const OpCode = chunks.OpCode;
const Token = scanner.Token;
const TokenType = scanner.TokenType;
const Value = @import("value.zig").Value;

var current: ?*Compiler = null;
var parser: Parser = Parser{};
var compilingChunk: *Chunk = undefined;

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

const ParseFn = *const fn (can_assign: bool) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence = Precedence.none,
};

const Compiler = struct {
    enclosing: ?*Compiler,
    function: ?*object.ObjFunction,
    type: FunctionType,
    locals: [65536]Local,
    local_count: usize,
    upvalues: [256]Upvalue,
    scope_depth: i32,
};

const Local = struct {
    name: Token,
    depth: i32,
    is_captured: bool,
};

const Upvalue = struct {
    index: u8,
    is_local: bool,
};

const FunctionType = enum {
    Function,
    Script,
};

fn currentChunk() *Chunk {
    return &current.?.function.?.chunk;
}

pub fn compile(source: []const u8) ?*object.ObjFunction {
    scanner.initScanner(source);
    var compiler: Compiler = undefined;
    initCompiler(&compiler, FunctionType.Script) catch {};

    parser.hadError = false;
    parser.panicMode = false;

    advance() catch {};
    while (!match(TokenType.eof)) {
        declaration();
    }
    const function: *object.ObjFunction = endCompiler();
    return if (parser.hadError) null else function;
}

fn initCompiler(compiler: *Compiler, function_type: FunctionType) !void {
    compiler.enclosing = current;
    compiler.function = null;
    compiler.type = function_type;
    compiler.local_count = 0;
    compiler.scope_depth = 0;
    compiler.function = try object.newFunction();
    current = compiler;
    if (function_type != FunctionType.Script) {
        current.?.function.?.name = try object.copyString(parser.previous.start, parser.previous.length);
    }

    var local: *Local = &current.?.locals[current.?.local_count];
    current.?.local_count += 1;
    local.depth = 0;
    local.is_captured = false;
    local.name.start = "";
    local.name.length = 0;
}

fn endCompiler() *object.ObjFunction {
    emitReturn();

    const function: *object.ObjFunction = current.?.function.?;
    if (debug.debug_print) {
        if (!parser.hadError) {
            debug.disassembleChunk(currentChunk(), if (function.name == null) "<script>" else function.name.?.chars[0 .. function.name.?.chars.len - 1 :0]);
        }
    }
    current = current.?.enclosing;
    return function;
}

pub fn markCompilerRoots() void {
    var compiler = current;
    while (compiler) |c| {
        mem.markObject(@alignCast(@ptrCast(c.function)));
        compiler = c.enclosing;
    }
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

fn check(token_type: TokenType) bool {
    return parser.current.type == token_type;
}

fn match(token_type: TokenType) bool {
    if (!check(token_type)) return false;
    advance() catch {};
    return true;
}

fn emitByte(byte: u8) void {
    chunks.writeChunk(currentChunk(), byte, parser.previous.line) catch {};
}

fn emitInstruction(op_code: OpCode) void {
    emitByte(@intFromEnum(op_code));
}

fn emitBytes(byte_1: u8, byte_2: u8) void {
    emitByte(byte_1);
    emitByte(byte_2);
}

fn emitReturn() void {
    emitInstruction(OpCode.Null);
    emitInstruction(OpCode.Return);
}

fn emitJump(instruction: OpCode) usize {
    emitInstruction(instruction);
    emitByte(0xff);
    emitByte(0xff);
    return currentChunk().code.items.len - 2;
}

fn emitLoop(loop_start: usize) void {
    emitInstruction(OpCode.Loop);

    const offset = currentChunk().code.items.len - loop_start + 2;
    if (offset > 0xffff) error_("Loop body too large.") catch {};

    emitByte(@intCast(@divFloor(offset, 256)));
    emitByte(@intCast(@mod(offset, 256)));
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
        emitBytes(@intFromEnum(OpCode.Constant), @as(u8, @intCast(@mod(constant, 256))));
    } else {
        emitInstruction(OpCode.Constant_16);
        const byte_1: u8 = @intCast(@mod(@divFloor(constant, 256), 256));
        const byte_2: u8 = @intCast(@mod(constant, 256));
        emitBytes(byte_1, byte_2);
    }
}

fn patchJump(offset: usize) void {
    const jump = currentChunk().code.items.len - offset - 2;
    if (jump > 0xffff) {
        error_("Too much code to jump over.") catch {};
    }

    currentChunk().code.items[offset] = @intCast(@divFloor(jump, 256));
    currentChunk().code.items[offset + 1] = @intCast(@mod(jump, 256));
}

fn beginScope() void {
    current.?.scope_depth += 1;
}

fn endScope() void {
    current.?.scope_depth -= 1;

    while (current.?.local_count > 0 and current.?.locals[@intCast(current.?.local_count - 1)].depth > current.?.scope_depth) {
        if (current.?.locals[current.?.local_count - 1].is_captured) {
            emitInstruction(OpCode.CloseUpvalue);
        } else {
            emitInstruction(OpCode.Pop);
        }
        current.?.local_count -= 1;
    }
}

fn unary(can_assign: bool) !void {
    _ = can_assign;
    const operatorType = parser.previous.type;

    //compile the operand.
    try parsePrecedence(Precedence.unary);

    //Emit the operator instruction.
    switch (operatorType) {
        TokenType.bang => emitInstruction(OpCode.Not),
        TokenType.minus => emitInstruction(OpCode.Negate),
        else => return,
    }
}

fn binary(can_assign: bool) !void {
    _ = can_assign;
    const operatorType = parser.previous.type;
    const rule = getRule(operatorType);
    try parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

    switch (operatorType) {
        TokenType.bang_equal => emitBytes(@intFromEnum(OpCode.Equal), @intFromEnum(OpCode.Not)),
        TokenType.equal_equal => emitInstruction(OpCode.Equal),
        TokenType.greater => emitInstruction(OpCode.Greater),
        TokenType.greater_equal => emitBytes(@intFromEnum(OpCode.Less), @intFromEnum(OpCode.Not)),
        TokenType.less => emitInstruction(OpCode.Less),
        TokenType.less_equal => emitBytes(@intFromEnum(OpCode.Greater), @intFromEnum(OpCode.Not)),
        TokenType.plus => emitInstruction(OpCode.Add),
        TokenType.minus => emitInstruction(OpCode.Subtract),
        TokenType.star => emitInstruction(OpCode.Multiply),
        TokenType.slash => emitInstruction(OpCode.Divide),
        else => return,
    }
}

fn literal(can_assign: bool) !void {
    _ = can_assign;
    switch (parser.previous.type) {
        TokenType.false_keyword => emitInstruction(OpCode.False),
        TokenType.null_keyword => emitInstruction(OpCode.Null),
        TokenType.true_keyword => emitInstruction(OpCode.True),
        else => return,
    }
}

fn grouping(can_assign: bool) !void {
    _ = can_assign;
    try expression();
    try consume(TokenType.right_paren, "Expect ')' after expression.");
}

fn number(can_assign: bool) !void {
    _ = can_assign;
    const value: f64 = try std.fmt.parseFloat(f64, parser.previous.start[0..parser.previous.length]);
    try emitConstant(Value.makeNumber(value));
}

fn string(can_assign: bool) !void {
    _ = can_assign;
    const obj_string = try object.copyString(parser.previous.start + 1, parser.previous.length - 2);
    const obj: *object.Obj = @ptrCast(obj_string);
    emitConstant(Value.makeObj(obj)) catch {};
}

fn variable(can_assign: bool) !void {
    try namedVariable(parser.previous, can_assign);
}

fn function_(function_type: FunctionType) !void {
    var compiler: Compiler = undefined;
    initCompiler(&compiler, function_type) catch {};
    beginScope();
    consume(TokenType.left_paren, "Expect '(' after function name.") catch {};
    if (!check(TokenType.right_paren)) {
        try addFunctionParameter();
        while (match(TokenType.comma)) try addFunctionParameter();
    }
    consume(TokenType.right_paren, "Expect ')' after parameters.") catch {};
    consume(TokenType.left_brace, "Expect '{' before function body.") catch {};
    block();

    const function: *object.ObjFunction = endCompiler();

    const constant: u16 = try makeConstant(Value.makeObj(@ptrCast(function)));
    if (constant < 256) {
        emitBytes(@intFromEnum(OpCode.Closure), @intCast(@mod(constant, 256)));
    } else {
        emitInstruction(OpCode.Closure_16);
        emitBytes(@intCast(@divFloor(constant, 256)), @intCast(@mod(constant, 256)));
    }

    var i: usize = 0;
    while (i < function.upvalue_count) : (i += 1) {
        emitByte(if (compiler.upvalues[i].is_local) 1 else 0);
        emitByte(compiler.upvalues[i].index);
    }
}

fn addFunctionParameter() !void {
    current.?.function.?.arity += 1;
    if (current.?.function.?.arity > 255) {
        errorAtCurrent("Can't have more than 255 parameters.") catch {};
    }
    const constant = try parseVariable("Expect parameter name.");
    defineVariable(constant);
}

fn namedVariable(name: Token, can_assign: bool) !void {
    var arg: i32 = resolveLocal(current.?, &name);
    var get_op: OpCode = undefined;
    var set_op: OpCode = undefined;

    if (arg != -1) {
        if (arg < 256) {
            get_op = OpCode.GetLocal;
            set_op = OpCode.SetLocal;
        } else {
            get_op = OpCode.GetLocal_16;
            set_op = OpCode.SetLocal_16;
        }
    } else {
        arg = resolveUpvalue(current.?, &name);

        if (arg != -1) {
            get_op = OpCode.GetUpvalue;
            set_op = OpCode.SetUpvalue;
        } else {
            arg = try identifierConstant(&name);

            if (arg < 256) {
                get_op = OpCode.GetGlobal;
                set_op = OpCode.SetGlobal;
            } else {
                get_op = OpCode.GetGlobal_16;
                set_op = OpCode.SetGlobal_16;
            }
        }
    }

    if (can_assign and match(TokenType.equal)) {
        try expression();
        if (arg < 256) {
            const index: u8 = @intCast(@mod(arg, 256));
            emitBytes(@intFromEnum(set_op), index);
        } else {
            emitInstruction(set_op);
            const byte_1: u8 = @intCast(@mod(@divFloor(arg, 256), 256));
            const byte_2: u8 = @intCast(@mod(arg, 256));
            emitBytes(byte_1, byte_2);
        }
    } else {
        if (arg < 256) {
            const index: u8 = @intCast(@mod(arg, 256));
            emitBytes(@intFromEnum(get_op), index);
        } else {
            emitInstruction(get_op);
            const byte_1: u8 = @intCast(@mod(@divFloor(arg, 256), 256));
            const byte_2: u8 = @intCast(@mod(arg, 256));
            emitBytes(byte_1, byte_2);
        }
    }
}

fn parsePrecedence(precedence: Precedence) !void {
    const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.assignment);
    try advance();
    const prefixRule_option = getRule(parser.previous.type).prefix;
    if (prefixRule_option) |prefixRule| {
        try prefixRule(can_assign);
    } else {
        try error_("Expect expression.");
        return;
    }

    while (@intFromEnum(precedence) <= @intFromEnum(getRule(parser.current.type).precedence)) {
        try advance();
        const infixRule_option = getRule(parser.previous.type).infix;
        if (infixRule_option) |infixRule| {
            try infixRule(can_assign);
        }
    }

    if (can_assign and match(TokenType.equal)) {
        error_("Invalid assignment target.") catch {};
    }
}

fn identifierConstant(name: *const Token) !u16 {
    const obj_str: *object.ObjString = try object.copyString(name.start, name.length);
    const obj: *object.Obj = @ptrCast(obj_str);
    const index = try makeConstant(Value.makeObj(obj));
    return @intCast(@mod(index, 256));
}

fn identifiersEqual(a: *const Token, b: *const Token) bool {
    if (a.length != b.length) return false;
    return std.mem.eql(u8, a.start[0..a.length], b.start[0..a.length]);
}

fn resolveLocal(compiler: *Compiler, name: *const Token) i32 {
    var i: i32 = @intCast(@mod(compiler.local_count, 65536) - 1);
    while (i >= 0) : (i -= 1) {
        const local = &compiler.locals[@intCast(i)];
        if (identifiersEqual(name, &local.name)) {
            if (local.depth == -1) {
                error_("Can't read local variable in its own initializer.") catch {};
            }
            return @intCast(@mod(i, 65536));
        }
    }
    return -1;
}

fn resolveUpvalue(compiler: *Compiler, name: *const Token) i32 {
    if (compiler.enclosing == null) return -1;

    const local = resolveLocal(compiler.enclosing.?, name);
    if (local != -1) {
        compiler.enclosing.?.locals[@intCast(local)].is_captured = true;
        return addUpvalue(compiler, @intCast(local), true);
    }

    const upvalue = resolveUpvalue(compiler.enclosing.?, name);
    if (upvalue != -1) {
        return addUpvalue(compiler, @intCast(upvalue), false);
    }

    return -1;
}

fn addUpvalue(compiler: *Compiler, index: u8, is_local: bool) i32 {
    const upvalue_count = compiler.function.?.upvalue_count;

    var i: usize = 0;
    while (i < upvalue_count) : (i += 1) {
        const upvalue = &compiler.upvalues[i];
        if (upvalue.index == index and upvalue.is_local == is_local) {
            return @intCast(i);
        }
    }
    compiler.upvalues[upvalue_count].is_local = is_local;
    compiler.upvalues[upvalue_count].index = index;
    defer compiler.function.?.upvalue_count += 1;
    return compiler.function.?.upvalue_count;
}

fn addLocal(name: Token) void {
    if (current.?.local_count == 256) {
        error_("Too many local variables in scope.") catch {};
        return;
    }

    var local: *Local = &current.?.locals[@intCast(current.?.local_count)];
    current.?.local_count += 1;
    local.name = name;
    local.depth = -1;
    local.is_captured = false;
}

fn declareVariable() void {
    if (current.?.scope_depth == 0) return;

    const name: *Token = &parser.previous;

    var i = current.?.local_count - 1;
    while (i >= 0) : (i -= 1) {
        const local = &current.?.locals[@intCast(i)];
        if (local.depth != -1 and local.depth < current.?.scope_depth) {
            break;
        }
        if (identifiersEqual(name, &local.name)) {
            error_("Already a variable with this name in this scope.") catch {};
        }
    }

    addLocal(name.*);
}

fn parseVariable(message: [*:0]const u8) !u16 {
    consume(TokenType.identifier, message) catch {};

    declareVariable();
    if (current.?.scope_depth > 0) return 0;

    return try identifierConstant(&parser.previous);
}

fn markInitialized() void {
    if (current.?.scope_depth == 0) return;
    current.?.locals[@intCast(current.?.local_count - 1)].depth = current.?.scope_depth;
}

fn defineVariable(global: u16) void {
    if (current.?.scope_depth > 0) {
        markInitialized();
        return;
    }

    if (global < 256) {
        const byte: u8 = @intCast(@mod(global, 256));
        emitBytes(@intFromEnum(OpCode.DefineGlobal), byte);
    } else {
        const byte_1: u8 = @intCast(@mod(@divFloor(global, 256), 256));
        const byte_2: u8 = @intCast(@mod(global, 256));
        emitInstruction(OpCode.DefineGlobal_16);
        emitBytes(byte_1, byte_2);
    }
}

fn argumentList() u8 {
    var arg_count: u8 = 0;
    if (!check(TokenType.right_paren)) {
        expression() catch {};
        arg_count += 1;
        while (match(TokenType.comma)) {
            expression() catch {};
            if (arg_count == 255) {
                error_("Can't have more than 255 arguments.") catch {};
            }
            arg_count += 1;
        }
    }

    consume(TokenType.right_paren, "Expect ')' after arguments.") catch {};
    return arg_count;
}

fn and_(can_assign: bool) !void {
    _ = can_assign;
    const end_jump = emitJump(OpCode.JumpIfFalse);

    emitInstruction(OpCode.Pop);
    parsePrecedence(Precedence.and_) catch {};

    patchJump(end_jump);
}

fn or_(can_assign: bool) !void {
    _ = can_assign;
    const else_jump = emitJump(OpCode.JumpIfFalse);
    const end_jump = emitJump(OpCode.Jump);

    patchJump(else_jump);
    emitInstruction(OpCode.Pop);

    parsePrecedence(Precedence.or_) catch {};
    patchJump(end_jump);
}

fn call(can_assign: bool) !void {
    _ = can_assign; // autofix
    const arg_count: u8 = argumentList();
    emitBytes(@intFromEnum(OpCode.Call), arg_count);
}

fn expression() !void {
    try parsePrecedence(Precedence.assignment);
}

fn block() void {
    while (!check(TokenType.right_brace) and !check(TokenType.eof)) {
        declaration();
    }

    consume(TokenType.right_brace, "Expect '}' after block.") catch {};
}

fn functionDeclaration() !void {
    const global: u16 = try parseVariable("Expect function name.");
    markInitialized();
    try function_(FunctionType.Function);
    defineVariable(global);
}

fn varDeclaration() !void {
    const global = try parseVariable("Expect variable name.");

    if (match(TokenType.equal)) {
        expression() catch {};
    } else {
        emitInstruction(OpCode.Null);
    }
    consume(TokenType.semicolon, "Expect ';' after variable declaration.") catch {};

    defineVariable(global);
}

fn expressionStatement() void {
    expression() catch {};
    consume(TokenType.semicolon, "Expect ';' after expression.") catch {};
    emitInstruction(OpCode.Pop);
}

fn ifStatement() void {
    consume(TokenType.left_paren, "Expect '(' after 'if'.") catch {};
    expression() catch {};
    consume(TokenType.right_paren, "Expect ')' after condition.") catch {};

    const then_jump = emitJump(OpCode.JumpIfFalse);
    emitInstruction(OpCode.Pop);
    statement();

    const else_jump = emitJump(OpCode.Jump);

    patchJump(then_jump);
    emitInstruction(OpCode.Pop);

    if (match(TokenType.else_keyword)) {
        statement();
    }
    patchJump(else_jump);
}

fn returnStatement() void {
    if (current.?.type == FunctionType.Script) {
        error_("Can't return from top-level code.") catch {};
    }
    if (match(TokenType.semicolon)) {
        emitReturn();
    } else {
        expression() catch {};
        consume(TokenType.semicolon, "Expect ';' after return value.") catch {};
        emitInstruction(OpCode.Return);
    }
}

fn whileStatement() void {
    const loop_start = currentChunk().code.items.len;
    consume(TokenType.left_paren, "Expect '(' after 'while'.") catch {};
    expression() catch {};
    consume(TokenType.right_paren, "Expect ')' after condition.") catch {};

    const exit_jump = emitJump(OpCode.JumpIfFalse);
    emitInstruction(OpCode.Pop);
    statement();
    emitLoop(loop_start);

    patchJump(exit_jump);

    emitInstruction(OpCode.Pop);
}

fn forStatement() void {
    beginScope();
    consume(TokenType.left_paren, "Expect '(' after 'for'.") catch {};
    if (match(TokenType.semicolon)) {} else if (match(TokenType.var_keyword)) {
        varDeclaration() catch {};
    } else {
        expressionStatement();
    }

    var loop_start = currentChunk().code.items.len;
    var exit_jump: i32 = -1;
    if (!match(TokenType.semicolon)) {
        expression() catch {};
        consume(TokenType.semicolon, "Expect ';' after loop condition.") catch {};

        //Jump out of loop if condition is false.
        exit_jump = @intCast(emitJump(OpCode.JumpIfFalse));

        emitInstruction(OpCode.Pop);
    }
    if (!match(TokenType.right_paren)) {
        const body_jump = emitJump(OpCode.Jump);
        const increment_start = currentChunk().code.items.len;
        expression() catch {};
        emitInstruction(OpCode.Pop);
        consume(TokenType.right_paren, "Expect ')' after for clauses.") catch {};

        emitLoop(loop_start);

        loop_start = increment_start;
        patchJump(body_jump);
    }

    statement();
    emitLoop(loop_start);

    if (exit_jump != -1) {
        patchJump(@intCast(exit_jump));
        emitInstruction(OpCode.Pop);
    }
    endScope();
}

fn printStatement() void {
    expression() catch {};
    consume(TokenType.semicolon, "Expect ';' after value.") catch {};
    emitInstruction(OpCode.Print);
}

fn synchronize() void {
    parser.panicMode = false;

    while (parser.current.type != TokenType.eof) {
        if (parser.previous.type == TokenType.semicolon) return;
        switch (parser.current.type) {
            TokenType.class_keyword,
            TokenType.fn_keyword,
            TokenType.var_keyword,
            TokenType.for_keyword,
            TokenType.if_keyword,
            TokenType.while_keyword,
            TokenType.print_keyword,
            TokenType.return_keyword,
            => return,
            else => {},
        }

        advance() catch {};
    }
}

fn statement() void {
    if (match(TokenType.print_keyword)) {
        printStatement();
    } else if (match(TokenType.for_keyword)) {
        forStatement();
    } else if (match(TokenType.if_keyword)) {
        ifStatement();
    } else if (match(TokenType.return_keyword)) {
        returnStatement();
    } else if (match(TokenType.while_keyword)) {
        whileStatement();
    } else if (match(TokenType.left_brace)) {
        beginScope();
        block();
        endScope();
    } else {
        expressionStatement();
    }
}

fn declaration() void {
    if (match(TokenType.fn_keyword)) {
        functionDeclaration() catch {};
    } else if (match(TokenType.var_keyword)) {
        varDeclaration() catch {};
    } else {
        statement();
    }

    if (parser.panicMode) synchronize();
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
        TokenType.left_paren => return ParseRule{ .prefix = grouping, .infix = call, .precedence = Precedence.call },
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
        TokenType.identifier => return ParseRule{ .prefix = variable },
        TokenType.string => return ParseRule{ .prefix = string },
        TokenType.number => return ParseRule{ .prefix = number },
        TokenType.and_keyword => return ParseRule{ .infix = and_, .precedence = Precedence.and_ },
        TokenType.false_keyword => return ParseRule{ .prefix = literal },
        TokenType.null_keyword => return ParseRule{ .prefix = literal },
        TokenType.or_keyword => return ParseRule{ .infix = or_, .precedence = Precedence.or_ },
        TokenType.true_keyword => return ParseRule{ .prefix = literal },
        else => return ParseRule{},
    }
}
