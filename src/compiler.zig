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

// var current: ?*Compiler = null;
var parser: Parser = Parser{};
// var compilingChunk: *Chunk = undefined;

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
    Subscript,
    primary,
};

const ParseFn = *const fn (compiler: *Compiler, can_assign: bool) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn = null,
    infix: ?ParseFn = null,
    precedence: Precedence = Precedence.none,
};

pub fn compile(source: []const u8) ?*object.ObjFunction {
    scanner.initScanner(source);
    var compiler: Compiler = undefined;
    compiler.init(FunctionType.Script, null, null) catch {};

    parser.hadError = false;
    parser.panicMode = false;

    compiler.advance() catch {};
    while (!compiler.match(TokenType.eof)) {
        compiler.declaration();
    }
    const function: *object.ObjFunction = compiler.endCompiler();
    return if (parser.hadError) null else function;
}

const ClassCompiler = struct {
    enclosing: ?*ClassCompiler,
    hasSuperclass: bool,
};

pub fn markCompilerRoots(compiler: ?*Compiler) void {
    // var compiler = current;
    var comp: ?*Compiler = compiler;
    while (comp) |c| {
        mem.markObject(@alignCast(@ptrCast(c.function)));
        comp = c.enclosing;
    }
}

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
    Method,
    Initializer,
};

pub const Compiler = struct {
    enclosing: ?*Compiler,
    function: ?*object.ObjFunction,
    type: FunctionType,
    locals: [65536]Local,
    local_count: usize,
    upvalues: [256]Upvalue,
    scope_depth: i32,
    current_class: ?*ClassCompiler,

    fn init(self: *Compiler, function_type: FunctionType, enclosing: ?*Compiler, current_class: ?*ClassCompiler) !void {
        self.enclosing = enclosing;
        self.function = null;
        self.type = function_type;
        self.local_count = 0;
        self.scope_depth = 0;
        mem.setCompiler(self);
        self.function = try object.ObjFunction.init();
        self.current_class = current_class;
        // current = compiler;
        if (function_type != FunctionType.Script) {
            self.function.?.name = try object.ObjString.copy(parser.previous.start, parser.previous.length);
        }

        var local: *Local = &self.locals[self.local_count];
        self.local_count += 1;
        local.depth = 0;
        local.is_captured = false;
        if (function_type != FunctionType.Function) {
            local.name.start = "self";
            local.name.length = 4;
        } else {
            local.name.start = "";
            local.name.length = 0;
        }
    }

    fn currentChunk(self: *Compiler) *Chunk {
        return &self.function.?.chunk;
    }

    fn endCompiler(self: *Compiler) *object.ObjFunction {
        self.emitReturn();

        const function: *object.ObjFunction = self.function.?;
        if (debug.debug_print) {
            if (!parser.hadError) {
                debug.disassembleChunk(self.currentChunk(), if (function.name == null) "<script>" else function.name.?.chars[0 .. function.name.?.chars.len - 1 :0]);
            }
        }
        mem.setCompiler(self.enclosing);
        // current = self.enclosing;
        return function;
    }

    fn advance(self: *Compiler) !void {
        parser.previous = parser.current;

        while (true) {
            parser.current = scanner.scanToken();
            if (parser.current.type != TokenType.error_) break;

            try self.errorAtCurrent(parser.current.start[0..parser.current.length :0].ptr);
        }
    }

    fn consume(self: *Compiler, token_type: TokenType, message: [*:0]const u8) !void {
        if (parser.current.type == token_type) {
            try self.advance();
            return;
        }

        try self.errorAtCurrent(message);
    }

    fn check(self: *Compiler, token_type: TokenType) bool {
        _ = self;
        return parser.current.type == token_type;
    }

    fn match(self: *Compiler, token_type: TokenType) bool {
        if (!self.check(token_type)) return false;
        self.advance() catch {};
        return true;
    }

    fn emitByte(self: *Compiler, byte: u8) void {
        self.currentChunk().write(byte, parser.previous.line) catch {};
    }

    fn emitInstruction(self: *Compiler, op_code: OpCode) void {
        self.emitByte(@intFromEnum(op_code));
    }

    fn emitBytes(self: *Compiler, byte_1: u8, byte_2: u8) void {
        self.emitByte(byte_1);
        self.emitByte(byte_2);
    }

    fn emitReturn(self: *Compiler) void {
        if (self.type == FunctionType.Initializer) {
            self.emitInstruction(OpCode.GetLocal);
            self.emitByte(0);
        } else {
            self.emitInstruction(OpCode.Null);
        }

        self.emitInstruction(OpCode.Return);
    }

    fn emitJump(self: *Compiler, instruction: OpCode) usize {
        self.emitInstruction(instruction);
        self.emitByte(0xff);
        self.emitByte(0xff);
        return self.currentChunk().code.items.len - 2;
    }

    fn emitLoop(self: *Compiler, loop_start: usize) void {
        self.emitInstruction(OpCode.Loop);

        const offset = self.currentChunk().code.items.len - loop_start + 2;
        if (offset > 0xffff) self.error_("Loop body too large.") catch {};

        self.emitByte(@intCast(@divFloor(offset, 256)));
        self.emitByte(@intCast(@mod(offset, 256)));
    }

    fn makeConstant(self: *Compiler, value: values.Value) !u16 {
        const constant = self.currentChunk().addConstant(value) catch {};
        if (constant > 65535) {
            self.error_("Too many constants in one chunk.") catch {};
            return 0;
        }

        return @intCast(@mod(constant, 65536));
    }

    fn emitConstant(self: *Compiler, value: values.Value) !void {
        const constant = try self.makeConstant(value);
        if (constant <= 255) {
            self.emitInstruction(OpCode.Constant);
            self.emitByte(@truncate(constant));
        } else {
            self.emitInstruction(OpCode.Constant_16);
            self.emitShort(constant);
        }
    }

    fn emitShort(self: *Compiler, index: u16) void {
        const byte_1: u8 = @truncate(index >> 8);
        const byte_2: u8 = @truncate(index);
        self.emitBytes(byte_1, byte_2);
    }

    fn patchJump(self: *Compiler, offset: usize) void {
        const jump = self.currentChunk().code.items.len - offset - 2;
        if (jump > 0xffff) {
            self.error_("Too much code to jump over.") catch {};
        }

        self.currentChunk().code.items[offset] = @intCast(@divFloor(jump, 256));
        self.currentChunk().code.items[offset + 1] = @intCast(@mod(jump, 256));
    }

    fn beginScope(self: *Compiler) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Compiler) void {
        self.scope_depth -= 1;

        while (self.local_count > 0 and self.locals[@intCast(self.local_count - 1)].depth > self.scope_depth) {
            if (self.locals[self.local_count - 1].is_captured) {
                self.emitInstruction(OpCode.CloseUpvalue);
            } else {
                self.emitInstruction(OpCode.Pop);
            }
            self.local_count -= 1;
        }
    }

    fn syntheticToken(self: *Compiler, text: [*]const u8, length: usize) scanner.Token {
        _ = self;
        var token: scanner.Token = undefined;
        token.start = text;
        token.length = length;
        return token;
    }

    fn function_(self: *Compiler, function_type: FunctionType) !void {
        var compiler: Compiler = undefined;
        compiler.init(function_type, self, self.current_class) catch {};
        compiler.beginScope();
        compiler.consume(TokenType.left_paren, "Expect '(' after function name.") catch {};
        if (!compiler.check(TokenType.right_paren)) {
            try compiler.addFunctionParameter();
            while (compiler.match(TokenType.comma)) try compiler.addFunctionParameter();
        }
        compiler.consume(TokenType.right_paren, "Expect ')' after parameters.") catch {};
        compiler.consume(TokenType.left_brace, "Expect '{' before function body.") catch {};
        compiler.block();

        const function: *object.ObjFunction = compiler.endCompiler();

        const constant: u16 = try self.makeConstant(Value.makeObj(@ptrCast(function)));
        if (constant < 256) {
            self.emitInstruction(OpCode.Closure);
            self.emitByte(@truncate(constant));
        } else {
            self.emitInstruction(OpCode.Closure_16);
            self.emitShort(constant);
        }

        var i: usize = 0;
        while (i < function.upvalue_count) : (i += 1) {
            self.emitByte(if (compiler.upvalues[i].is_local) 1 else 0);
            self.emitByte(compiler.upvalues[i].index);
        }
    }

    fn addFunctionParameter(
        self: *Compiler,
    ) !void {
        self.function.?.arity += 1;
        if (self.function.?.arity > 255) {
            self.errorAtCurrent("Can't have more than 255 parameters.") catch {};
        }
        const constant = try self.parseVariable("Expect parameter name.");
        self.defineVariable(constant);
    }

    fn classDeclaration(
        self: *Compiler,
    ) !void {
        self.consume(TokenType.identifier, "Expect class name.") catch {};
        const class_name = parser.previous;
        const name_constant = try self.identifierConstant(&parser.previous);
        self.declareVariable();

        self.emitInstruction(OpCode.Class);
        self.emitShort(name_constant);
        self.defineVariable(name_constant);

        const classCompiler = try mem.allocator.create(ClassCompiler);
        classCompiler.enclosing = self.current_class;
        self.current_class = classCompiler;

        if (self.match(TokenType.colon)) {
            self.consume(TokenType.identifier, "Expect superclass name.") catch {};
            variable(self, false) catch {};

            if (self.identifiersEqual(&class_name, &parser.previous)) {
                self.error_("A class can't inherit from itself.") catch {};
            }

            self.beginScope();
            self.addLocal(self.syntheticToken("super", 5));
            self.defineVariable(0);

            namedVariable(self, class_name, false) catch {};
            self.emitInstruction(OpCode.Inherit);
            classCompiler.hasSuperclass = true;
        }

        namedVariable(self, class_name, false) catch {};

        self.consume(TokenType.left_brace, "Expect '{' before class body.") catch {};
        while (!self.check(TokenType.right_brace) and !self.check(TokenType.eof)) {
            if (self.check(TokenType.fn_keyword)) {
                self.consume(TokenType.fn_keyword, "") catch {};
                self.method() catch {};
            } else {
                self.field() catch {};
                self.consume(TokenType.semicolon, "Expect ';' after field declaration.") catch {};
            }
        }
        self.consume(TokenType.right_brace, "Expect '}' after class body.") catch {};
        self.emitInstruction(OpCode.Pop);

        if (classCompiler.hasSuperclass) {
            self.endScope();
        }

        self.current_class = self.current_class.?.enclosing;
        mem.allocator.destroy(classCompiler);
    }

    fn field(
        self: *Compiler,
    ) !void {
        self.consume(TokenType.identifier, "Expect field name.") catch {};
        const constant = try self.identifierConstant(&parser.previous);
        self.consume(TokenType.equal, "Expect '=' after field name.") catch {};
        self.expression() catch {};
        self.emitInstruction(OpCode.Field);
        self.emitShort(constant);
    }

    fn method(
        self: *Compiler,
    ) !void {
        self.consume(TokenType.identifier, "Expect method name.") catch {};
        const constant = try self.identifierConstant(&parser.previous);
        var function_type = FunctionType.Method;

        if (parser.previous.length == 4 and std.mem.eql(u8, parser.previous.start[0..parser.previous.length], "init")) {
            function_type = FunctionType.Initializer;
        }
        self.function_(function_type) catch {};
        self.emitInstruction(OpCode.Method);
        self.emitShort(constant);
    }

    fn parsePrecedence(self: *Compiler, precedence: Precedence) !void {
        const can_assign = @intFromEnum(precedence) <= @intFromEnum(Precedence.assignment);
        try self.advance();
        const prefixRule_option = self.getRule(parser.previous.type).prefix;
        if (prefixRule_option) |prefixRule| {
            try prefixRule(self, can_assign);
        } else {
            try self.error_("Expect expression.");
            return;
        }

        while (@intFromEnum(precedence) <= @intFromEnum(self.getRule(parser.current.type).precedence)) {
            try self.advance();
            const infixRule_option = self.getRule(parser.previous.type).infix;
            if (infixRule_option) |infixRule| {
                try infixRule(self, can_assign);
            }
        }

        if (can_assign and self.match(TokenType.equal)) {
            self.error_("Invalid assignment target.") catch {};
        }
    }

    fn identifierConstant(self: *Compiler, name: *const Token) !u16 {
        const obj_str: *object.ObjString = try object.ObjString.copy(name.start, name.length);
        const obj: *object.Obj = @ptrCast(obj_str);
        const index = try self.makeConstant(Value.makeObj(obj));
        return @intCast(@mod(index, 256));
    }

    fn identifiersEqual(self: *Compiler, a: *const Token, b: *const Token) bool {
        _ = self;
        if (a.length != b.length) return false;
        return std.mem.eql(u8, a.start[0..a.length], b.start[0..a.length]);
    }

    fn resolveLocal(self: *Compiler, compiler: *Compiler, name: *const Token) i32 {
        var i: i32 = @intCast(@mod(compiler.local_count, 65536) - 1);
        while (i >= 0) : (i -= 1) {
            const local = &compiler.locals[@intCast(i)];
            if (self.identifiersEqual(name, &local.name)) {
                if (local.depth == -1) {
                    self.error_("Can't read local variable in its own initializer.") catch {};
                }
                return @intCast(@mod(i, 65536));
            }
        }
        return -1;
    }

    fn resolveUpvalue(self: *Compiler, compiler: *Compiler, name: *const Token) i32 {
        if (compiler.enclosing == null) return -1;

        const local = self.resolveLocal(compiler.enclosing.?, name);
        if (local != -1) {
            compiler.enclosing.?.locals[@intCast(local)].is_captured = true;
            return self.addUpvalue(compiler, @intCast(local), true);
        }

        const upvalue = self.resolveUpvalue(compiler.enclosing.?, name);
        if (upvalue != -1) {
            return self.addUpvalue(compiler, @intCast(upvalue), false);
        }

        return -1;
    }

    fn addUpvalue(self: *Compiler, compiler: *Compiler, index: u8, is_local: bool) i32 {
        _ = self;
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

    fn addLocal(self: *Compiler, name: Token) void {
        if (self.local_count == 256) {
            self.error_("Too many local variables in scope.") catch {};
            return;
        }

        var local: *Local = &self.locals[@intCast(self.local_count)];
        self.local_count += 1;
        local.name = name;
        local.depth = -1;
        local.is_captured = false;
    }

    fn declareVariable(
        self: *Compiler,
    ) void {
        if (self.scope_depth == 0) return;

        const name: *Token = &parser.previous;

        var i = self.local_count - 1;
        while (i >= 0) : (i -= 1) {
            const local = &self.locals[@intCast(i)];
            if (local.depth != -1 and local.depth < self.scope_depth) {
                break;
            }
            if (self.identifiersEqual(name, &local.name)) {
                self.error_("Already a variable with this name in this scope.") catch {};
            }
        }

        self.addLocal(name.*);
    }

    fn parseVariable(self: *Compiler, message: [*:0]const u8) !u16 {
        self.consume(TokenType.identifier, message) catch {};

        self.declareVariable();
        if (self.scope_depth > 0) return 0;

        return try self.identifierConstant(&parser.previous);
    }

    fn markInitialized(
        self: *Compiler,
    ) void {
        if (self.scope_depth == 0) return;
        self.locals[@intCast(self.local_count - 1)].depth = self.scope_depth;
    }

    fn defineVariable(self: *Compiler, global: u16) void {
        if (self.scope_depth > 0) {
            self.markInitialized();
            return;
        }

        if (global < 256) {
            const byte: u8 = @intCast(@mod(global, 256));
            self.emitBytes(@intFromEnum(OpCode.DefineGlobal), byte);
        } else {
            const byte_1: u8 = @intCast(@mod(@divFloor(global, 256), 256));
            const byte_2: u8 = @intCast(@mod(global, 256));
            self.emitInstruction(OpCode.DefineGlobal_16);
            self.emitBytes(byte_1, byte_2);
        }
    }

    fn argumentList(
        self: *Compiler,
    ) u8 {
        var arg_count: u8 = 0;
        if (!self.check(TokenType.right_paren)) {
            self.expression() catch {};
            arg_count += 1;
            while (self.match(TokenType.comma)) {
                self.expression() catch {};
                if (arg_count == 255) {
                    self.error_("Can't have more than 255 arguments.") catch {};
                }
                arg_count += 1;
            }
        }

        self.consume(TokenType.right_paren, "Expect ')' after arguments.") catch {};
        return arg_count;
    }

    fn expression(
        self: *Compiler,
    ) !void {
        try self.parsePrecedence(Precedence.assignment);
    }

    fn block(
        self: *Compiler,
    ) void {
        while (!self.check(TokenType.right_brace) and !self.check(TokenType.eof)) {
            self.declaration();
        }

        self.consume(TokenType.right_brace, "Expect '}' after block.") catch {};
    }

    fn functionDeclaration(
        self: *Compiler,
    ) !void {
        const global: u16 = try self.parseVariable("Expect function name.");
        self.markInitialized();
        try self.function_(FunctionType.Function);
        self.defineVariable(global);
    }

    fn varDeclaration(
        self: *Compiler,
    ) !void {
        const global = try self.parseVariable("Expect variable name.");

        if (self.match(TokenType.equal)) {
            self.expression() catch {};
        } else {
            self.emitInstruction(OpCode.Null);
        }
        self.consume(TokenType.semicolon, "Expect ';' after variable declaration.") catch {};

        self.defineVariable(global);
    }

    fn expressionStatement(
        self: *Compiler,
    ) void {
        self.expression() catch {};
        self.consume(TokenType.semicolon, "Expect ';' after expression.") catch {};
        self.emitInstruction(OpCode.Pop);
    }

    fn ifStatement(
        self: *Compiler,
    ) void {
        self.consume(TokenType.left_paren, "Expect '(' after 'if'.") catch {};
        self.expression() catch {};
        self.consume(TokenType.right_paren, "Expect ')' after condition.") catch {};

        const then_jump = self.emitJump(OpCode.JumpIfFalse);
        self.emitInstruction(OpCode.Pop);
        self.statement();

        const else_jump = self.emitJump(OpCode.Jump);

        self.patchJump(then_jump);
        self.emitInstruction(OpCode.Pop);

        if (self.match(TokenType.else_keyword)) {
            self.statement();
        }
        self.patchJump(else_jump);
    }

    fn returnStatement(
        self: *Compiler,
    ) void {
        if (self.type == FunctionType.Script) {
            self.error_("Can't return from top-level code.") catch {};
        }
        if (self.match(TokenType.semicolon)) {
            self.emitReturn();
        } else {
            if (self.type == FunctionType.Initializer) {
                self.error_("Can't return a value from an initializer.") catch {};
            }
            self.expression() catch {};
            self.consume(TokenType.semicolon, "Expect ';' after return value.") catch {};
            self.emitInstruction(OpCode.Return);
        }
    }

    fn whileStatement(
        self: *Compiler,
    ) void {
        const loop_start = self.currentChunk().code.items.len;
        self.consume(TokenType.left_paren, "Expect '(' after 'while'.") catch {};
        self.expression() catch {};
        self.consume(TokenType.right_paren, "Expect ')' after condition.") catch {};

        const exit_jump = self.emitJump(OpCode.JumpIfFalse);
        self.emitInstruction(OpCode.Pop);
        self.statement();
        self.emitLoop(loop_start);

        self.patchJump(exit_jump);

        self.emitInstruction(OpCode.Pop);
    }

    fn forStatement(
        self: *Compiler,
    ) void {
        self.beginScope();
        self.consume(TokenType.left_paren, "Expect '(' after 'for'.") catch {};
        if (self.match(TokenType.semicolon)) {} else if (self.match(TokenType.var_keyword)) {
            self.varDeclaration() catch {};
        } else {
            self.expressionStatement();
        }

        var loop_start = self.currentChunk().code.items.len;
        var exit_jump: i32 = -1;
        if (!self.match(TokenType.semicolon)) {
            self.expression() catch {};
            self.consume(TokenType.semicolon, "Expect ';' after loop condition.") catch {};

            //Jump out of loop if condition is false.
            exit_jump = @intCast(self.emitJump(OpCode.JumpIfFalse));

            self.emitInstruction(OpCode.Pop);
        }
        if (!self.match(TokenType.right_paren)) {
            const body_jump = self.emitJump(OpCode.Jump);
            const increment_start = self.currentChunk().code.items.len;
            self.expression() catch {};
            self.emitInstruction(OpCode.Pop);
            self.consume(TokenType.right_paren, "Expect ')' after for clauses.") catch {};

            self.emitLoop(loop_start);

            loop_start = increment_start;
            self.patchJump(body_jump);
        }

        self.statement();
        self.emitLoop(loop_start);

        if (exit_jump != -1) {
            self.patchJump(@intCast(exit_jump));
            self.emitInstruction(OpCode.Pop);
        }
        self.endScope();
    }

    fn printStatement(
        self: *Compiler,
    ) void {
        self.expression() catch {};
        self.consume(TokenType.semicolon, "Expect ';' after value.") catch {};
        self.emitInstruction(OpCode.Print);
    }

    fn synchronize(
        self: *Compiler,
    ) void {
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

            self.advance() catch {};
        }
    }

    fn statement(
        self: *Compiler,
    ) void {
        if (self.match(TokenType.print_keyword)) {
            self.printStatement();
        } else if (self.match(TokenType.for_keyword)) {
            self.forStatement();
        } else if (self.match(TokenType.if_keyword)) {
            self.ifStatement();
        } else if (self.match(TokenType.return_keyword)) {
            self.returnStatement();
        } else if (self.match(TokenType.while_keyword)) {
            self.whileStatement();
        } else if (self.match(TokenType.left_brace)) {
            self.beginScope();
            self.block();
            self.endScope();
        } else {
            self.expressionStatement();
        }
    }

    fn declaration(
        self: *Compiler,
    ) void {
        if (self.match(TokenType.class_keyword)) {
            self.classDeclaration() catch {};
        } else if (self.match(TokenType.fn_keyword)) {
            self.functionDeclaration() catch {};
        } else if (self.match(TokenType.var_keyword)) {
            self.varDeclaration() catch {};
        } else {
            self.statement();
        }

        if (parser.panicMode) self.synchronize();
    }

    fn errorAtCurrent(self: *Compiler, message: [*:0]const u8) !void {
        try self.errorAt(&parser.current, message);
    }

    fn error_(self: *Compiler, message: [*:0]const u8) !void {
        try self.errorAt(&parser.previous, message);
    }

    fn errorAt(self: *Compiler, token: *Token, message: [*:0]const u8) !void {
        _ = self;
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

    fn getRule(self: *Compiler, token_type: TokenType) ParseRule {
        _ = self;
        switch (token_type) {
            TokenType.left_paren => return ParseRule{ .prefix = grouping, .infix = call, .precedence = Precedence.call },
            TokenType.left_bracket => return ParseRule{ .prefix = list, .infix = subscript, .precedence = Precedence.Subscript },
            TokenType.dot => return ParseRule{ .infix = dot, .precedence = Precedence.call },
            TokenType.minus => return ParseRule{ .prefix = unary, .infix = binary, .precedence = Precedence.term },
            TokenType.plus => return ParseRule{ .infix = binary, .precedence = Precedence.term },
            TokenType.slash => return ParseRule{ .infix = binary, .precedence = Precedence.factor },
            TokenType.modulo => return ParseRule{ .infix = binary, .precedence = Precedence.factor },
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
            TokenType.self_keyword => return ParseRule{ .prefix = self_ },
            TokenType.super_keyword => return ParseRule{ .prefix = super },
            TokenType.true_keyword => return ParseRule{ .prefix = literal },
            else => return ParseRule{},
        }
    }
};

fn unary(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    const operatorType = parser.previous.type;

    //compile the operand.
    try compiler.parsePrecedence(Precedence.unary);

    //Emit the operator instruction.
    switch (operatorType) {
        TokenType.bang => compiler.emitInstruction(OpCode.Not),
        TokenType.minus => compiler.emitInstruction(OpCode.Negate),
        else => return,
    }
}

fn binary(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    const operatorType = parser.previous.type;
    const rule = compiler.getRule(operatorType);
    try compiler.parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

    switch (operatorType) {
        TokenType.bang_equal => compiler.emitBytes(@intFromEnum(OpCode.Equal), @intFromEnum(OpCode.Not)),
        TokenType.equal_equal => compiler.emitInstruction(OpCode.Equal),
        TokenType.greater => compiler.emitInstruction(OpCode.Greater),
        TokenType.greater_equal => compiler.emitBytes(@intFromEnum(OpCode.Less), @intFromEnum(OpCode.Not)),
        TokenType.less => compiler.emitInstruction(OpCode.Less),
        TokenType.less_equal => compiler.emitBytes(@intFromEnum(OpCode.Greater), @intFromEnum(OpCode.Not)),
        TokenType.plus => compiler.emitInstruction(OpCode.Add),
        TokenType.minus => compiler.emitInstruction(OpCode.Subtract),
        TokenType.star => compiler.emitInstruction(OpCode.Multiply),
        TokenType.slash => compiler.emitInstruction(OpCode.Divide),
        TokenType.modulo => compiler.emitInstruction(OpCode.Modulo),
        else => return,
    }
}

fn literal(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    switch (parser.previous.type) {
        TokenType.false_keyword => compiler.emitInstruction(OpCode.False),
        TokenType.null_keyword => compiler.emitInstruction(OpCode.Null),
        TokenType.true_keyword => compiler.emitInstruction(OpCode.True),
        else => return,
    }
}

fn grouping(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    try compiler.expression();
    try compiler.consume(TokenType.right_paren, "Expect ')' after expression.");
}

fn number(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    const value: f64 = try std.fmt.parseFloat(f64, parser.previous.start[0..parser.previous.length]);
    try compiler.emitConstant(Value.makeNumber(value));
}

fn string(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    var chars_array: std.ArrayList(u8) = std.ArrayList(u8).init(mem.allocator);
    defer chars_array.deinit();
    // try chars_array.insertSlice(0, parser.previous.start[1 .. parser.previous.length - 1]);
    var i: usize = 1;
    const length = parser.previous.length - 1;
    while (i < length) : (i += 1) {
        if (parser.previous.start[i] == '\\') {
            switch (parser.previous.start[i + 1]) {
                'n' => {
                    chars_array.append('\n') catch {};
                    i += 1;
                },
                't' => {
                    chars_array.append('\t') catch {};
                    i += 1;
                },
                '"' => {
                    chars_array.append('"') catch {};
                    i += 1;
                },
                '\\' => {
                    chars_array.append('\\') catch {};
                    i += 1;
                },
                else => {
                    try compiler.error_("Invalid escape sequence.");
                },
            }
        } else {
            chars_array.append(parser.previous.start[i]) catch {};
        }
    }
    const chars = try chars_array.toOwnedSlice();
    const obj_string = try object.ObjString.copy(chars.ptr, chars.len);
    // const obj_string = try object.ObjString.copy(parser.previous.start + 1, parser.previous.length - 2);
    const obj: *object.Obj = @ptrCast(obj_string);
    compiler.emitConstant(Value.makeObj(obj)) catch {};
}

fn variable(compiler: *Compiler, can_assign: bool) !void {
    try namedVariable(compiler, parser.previous, can_assign);
}

fn super(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    if (compiler.current_class == null) {
        compiler.error_("Can't use 'super' outside of a class.") catch {};
    } else if (!compiler.current_class.?.hasSuperclass) {
        compiler.error_("Can't use 'super' in a class with no superclass.") catch {};
    }
    compiler.consume(TokenType.dot, "Expect '.' after 'super'.") catch {};
    compiler.consume(TokenType.identifier, "Expect superclass method name.") catch {};
    const name = try compiler.identifierConstant(&parser.previous);
    try namedVariable(compiler, compiler.syntheticToken("self", 4), false);
    if (compiler.match(TokenType.left_paren)) {
        const arg_count = compiler.argumentList();
        try namedVariable(compiler, compiler.syntheticToken("super", 5), false);
        compiler.emitInstruction(OpCode.SuperInvoke);
        compiler.emitShort(name);
        compiler.emitByte(arg_count);
    } else {
        try namedVariable(compiler, compiler.syntheticToken("super", 5), false);
        compiler.emitInstruction(OpCode.GetSuper);
        compiler.emitShort(name);
    }
}

fn self_(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign; // autofix
    if (compiler.current_class == null) {
        compiler.error_("Can't use 'self' outside of a class.") catch {};
        return;
    }
    try variable(compiler, false);
}

fn namedVariable(compiler: *Compiler, name: Token, can_assign: bool) !void {
    var arg: i32 = compiler.resolveLocal(compiler, &name);
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
        arg = compiler.resolveUpvalue(compiler, &name);

        if (arg != -1) {
            get_op = OpCode.GetUpvalue;
            set_op = OpCode.SetUpvalue;
        } else {
            arg = try compiler.identifierConstant(&name);

            if (arg < 256) {
                get_op = OpCode.GetGlobal;
                set_op = OpCode.SetGlobal;
            } else {
                get_op = OpCode.GetGlobal_16;
                set_op = OpCode.SetGlobal_16;
            }
        }
    }

    const index: u16 = @intCast(arg);
    if (can_assign and compiler.match(TokenType.equal)) {
        try compiler.expression();
        if (index < 256) {
            compiler.emitInstruction(set_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(set_op);
            compiler.emitShort(index);
        }
    } else if (can_assign and compiler.match(TokenType.plus_equal)) {
        if (index < 256) {
            compiler.emitInstruction(get_op);
            compiler.emitByte(@truncate(index));
            try compiler.expression();
            compiler.emitInstruction(OpCode.Add);
            compiler.emitInstruction(set_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(get_op);
            compiler.emitShort(index);
            try compiler.expression();
            compiler.emitInstruction(OpCode.Add);
            compiler.emitInstruction(set_op);
            compiler.emitShort(index);
        }
    } else if (can_assign and compiler.match(TokenType.minus_equal)) {
        if (index < 256) {
            compiler.emitInstruction(get_op);
            compiler.emitByte(@truncate(index));
            try compiler.expression();
            compiler.emitInstruction(OpCode.Subtract);
            compiler.emitInstruction(set_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(get_op);
            compiler.emitShort(index);
            try compiler.expression();
            compiler.emitInstruction(OpCode.Subtract);
            compiler.emitInstruction(set_op);
            compiler.emitShort(index);
        }
    } else if (can_assign and compiler.match(TokenType.star_equal)) {
        if (index < 256) {
            compiler.emitInstruction(get_op);
            compiler.emitByte(@truncate(index));
            try compiler.expression();
            compiler.emitInstruction(OpCode.Multiply);
            compiler.emitInstruction(set_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(get_op);
            compiler.emitShort(index);
            try compiler.expression();
            compiler.emitInstruction(OpCode.Multiply);
            compiler.emitInstruction(set_op);
            compiler.emitShort(index);
        }
    } else if (can_assign and compiler.match(TokenType.slash_equal)) {
        if (index < 256) {
            compiler.emitInstruction(get_op);
            compiler.emitByte(@truncate(index));
            try compiler.expression();
            compiler.emitInstruction(OpCode.Divide);
            compiler.emitInstruction(set_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(get_op);
            compiler.emitShort(index);
            try compiler.expression();
            compiler.emitInstruction(OpCode.Divide);
            compiler.emitInstruction(set_op);
            compiler.emitShort(index);
        }
    } else if (can_assign and compiler.match(TokenType.modulo_equal)) {
        if (index < 256) {
            compiler.emitInstruction(get_op);
            compiler.emitByte(@truncate(index));
            try compiler.expression();
            compiler.emitInstruction(OpCode.Modulo);
            compiler.emitInstruction(set_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(get_op);
            compiler.emitShort(index);
            try compiler.expression();
            compiler.emitInstruction(OpCode.Modulo);
            compiler.emitInstruction(set_op);
            compiler.emitShort(index);
        }
    } else {
        if (index < 256) {
            compiler.emitInstruction(get_op);
            compiler.emitByte(@truncate(index));
        } else {
            compiler.emitInstruction(get_op);
            compiler.emitShort(index);
        }
    }
}

fn and_(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    const end_jump = compiler.emitJump(OpCode.JumpIfFalse);

    compiler.emitInstruction(OpCode.Pop);
    compiler.parsePrecedence(Precedence.and_) catch {};

    compiler.patchJump(end_jump);
}

fn or_(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    const else_jump = compiler.emitJump(OpCode.JumpIfFalse);
    const end_jump = compiler.emitJump(OpCode.Jump);

    compiler.patchJump(else_jump);
    compiler.emitInstruction(OpCode.Pop);

    compiler.parsePrecedence(Precedence.or_) catch {};
    compiler.patchJump(end_jump);
}

fn call(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign; // autofix
    const arg_count: u8 = compiler.argumentList();
    compiler.emitBytes(@intFromEnum(OpCode.Call), arg_count);
}

fn dot(compiler: *Compiler, can_assign: bool) !void {
    compiler.consume(TokenType.identifier, "Expect property name after '.'.") catch {};
    const name = try compiler.identifierConstant(&parser.previous);

    if (can_assign and compiler.match(TokenType.equal)) {
        compiler.expression() catch {};
        compiler.emitInstruction(OpCode.SetProperty);
        compiler.emitShort(name);
    } else if (compiler.match(TokenType.left_paren)) {
        const arg_count = compiler.argumentList();
        compiler.emitInstruction(OpCode.Invoke);
        compiler.emitShort(name);
        compiler.emitByte(arg_count);
    } else {
        compiler.emitInstruction(OpCode.GetProperty);
        compiler.emitShort(name);
    }
}

fn list(compiler: *Compiler, can_assign: bool) !void {
    _ = can_assign;
    var item_count: u8 = 0;
    if (!compiler.check(TokenType.right_bracket)) {
        try compiler.parsePrecedence(Precedence.or_);
        if (item_count == 255) {
            compiler.error_("Cannot have more than 256 items in a list.") catch {};
        }
        item_count += 1;
        while (compiler.match(TokenType.comma)) {
            if (compiler.check(TokenType.right_bracket)) {
                break;
            }
            try compiler.parsePrecedence(Precedence.or_);
            if (item_count == 255) {
                compiler.error_("Cannot have more than 256 items in a list.") catch {};
            }
            item_count += 1;
        }
    }
    compiler.consume(TokenType.right_bracket, "Expect']' after list items.") catch {};
    compiler.emitInstruction(OpCode.BuildList);
    compiler.emitByte(item_count);
}

fn subscript(compiler: *Compiler, can_assign: bool) !void {
    try compiler.parsePrecedence(Precedence.or_);
    compiler.consume(TokenType.right_bracket, "Expect ']' after index.") catch {};

    if (can_assign and compiler.match(TokenType.equal)) {
        compiler.expression() catch {};
        compiler.emitInstruction(OpCode.StoreSubscr);
    } else {
        compiler.emitInstruction(OpCode.IndexSubscr);
    }
}
