const std = @import("std");

const Scanner = struct {
    source: []const u8,
    start: [*]const u8,
    current: [*]const u8,
    line: u32,
};

pub const Token = struct {
    type: TokenType,
    start: [*]const u8,
    length: usize,
    line: u32,
};

pub const TokenType = enum {
    //Single character tokens.
    left_paren,
    right_paren,
    left_brace,
    right_brace,
    left_bracket,
    right_bracket,
    comma,
    dot,
    minus,
    plus,
    semicolon,
    colon,
    slash,
    star,
    modulo,
    //One or two character tokens.
    bang,
    bang_equal,
    equal,
    equal_equal,
    greater,
    greater_equal,
    less,
    less_equal,
    //Literals
    identifier,
    string,
    number,
    //Keywords
    and_keyword,
    class_keyword,
    else_keyword,
    false_keyword,
    for_keyword,
    fn_keyword,
    if_keyword,
    null_keyword,
    or_keyword,
    print_keyword,
    return_keyword,
    self_keyword,
    super_keyword,
    true_keyword,
    var_keyword,
    while_keyword,
    //other
    error_,
    eof,
};

var scanner: Scanner = undefined;

pub fn initScanner(source: []const u8) void {
    scanner = Scanner{
        .source = source,
        .start = source.ptr,
        .current = source.ptr,
        .line = 1,
    };
}

pub fn scanToken() Token {
    skipWhiteSpace();
    scanner.start = scanner.current;

    if (isAtEnd()) return makeToken(TokenType.eof);

    const c = advance();
    if (isDigit(c)) return number();
    if (isAlpha(c)) return identifier();

    switch (c) {
        '(' => return makeToken(TokenType.left_paren),
        ')' => return makeToken(TokenType.right_paren),
        '{' => return makeToken(TokenType.left_brace),
        '}' => return makeToken(TokenType.right_brace),
        '[' => return makeToken(TokenType.left_bracket),
        ']' => return makeToken(TokenType.right_bracket),
        ';' => return makeToken(TokenType.semicolon),
        ':' => return makeToken(TokenType.colon),
        ',' => return makeToken(TokenType.comma),
        '.' => return makeToken(TokenType.dot),
        '+' => return makeToken(TokenType.plus),
        '-' => return makeToken(TokenType.minus),
        '/' => return makeToken(TokenType.slash),
        '*' => return makeToken(TokenType.star),
        '%' => return makeToken(TokenType.modulo),
        '!' => return makeToken(if (match('=')) TokenType.bang_equal else TokenType.bang),
        '=' => return makeToken(if (match('=')) TokenType.equal_equal else TokenType.equal),
        '<' => return makeToken(if (match('=')) TokenType.less_equal else TokenType.less),
        '>' => return makeToken(if (match('=')) TokenType.greater_equal else TokenType.greater),
        '"' => return string(),
        else => return errorToken("Unexpected character."),
    }

    // return errorToken("Unexpected character.");
}

fn isAtEnd() bool {
    const position = @intFromPtr(scanner.current) - @intFromPtr(scanner.source.ptr);
    return position >= scanner.source.len;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn advance() u8 {
    const result = scanner.current[0];
    scanner.current += 1;
    return result;
}

fn peek() u8 {
    return scanner.current[0];
}

fn peekNext() u8 {
    if (isAtEnd()) return 0;
    return scanner.current[1];
}

fn match(expected: u8) bool {
    if (isAtEnd()) return false;
    if (scanner.current[0] != expected) return false;
    scanner.current += 1;
    return true;
}

fn makeToken(token_type: TokenType) Token {
    return Token{
        .type = token_type,
        .start = scanner.start,
        .length = @intFromPtr(scanner.current) - @intFromPtr(scanner.start),
        .line = scanner.line,
    };
}

fn errorToken(message: []const u8) Token {
    return Token{
        .type = TokenType.error_,
        .start = message.ptr,
        .length = message.len,
        .line = scanner.line,
    };
}

fn skipWhiteSpace() void {
    while (true) {
        const c = peek();
        switch (c) {
            ' ', '\r', '\t' => {
                _ = advance();
            },
            '\n' => {
                scanner.line += 1;
                _ = advance();
            },
            '/' => {
                if (peekNext() == '/') {
                    while (peek() != '\n' and !isAtEnd()) _ = advance();
                } else {
                    return;
                }
            },
            else => return,
        }
    }
}

fn checkKeyword(start: usize, length: usize, rest: [*]const u8, token_type: TokenType) TokenType {
    if (@intFromPtr(scanner.current) - @intFromPtr(scanner.start) == start + length and std.mem.eql(u8, scanner.start[start..(start + length)], rest[0..length])) {
        return token_type;
    }

    return TokenType.identifier;
}

fn number() Token {
    while (isDigit(peek())) _ = advance();

    if (peek() == '.' and isDigit(peekNext())) {
        _ = advance();
        while (isDigit(peek())) _ = advance();
    }

    return makeToken(TokenType.number);
}

fn string() Token {
    while (peek() != '"' and !isAtEnd()) {
        if (peek() == '\n') scanner.line += 1;
        _ = advance();
    }

    if (isAtEnd()) return errorToken("Unterminated string.");

    _ = advance();
    return makeToken(TokenType.string);
}

fn identifier() Token {
    while (isAlpha(peek()) or isDigit(peek())) _ = advance();
    return makeToken(identifierType());
}

fn identifierType() TokenType {
    switch (scanner.start[0]) {
        'a' => return checkKeyword(1, 2, "nd", TokenType.and_keyword),
        'c' => return checkKeyword(1, 4, "lass", TokenType.class_keyword),
        'e' => return checkKeyword(1, 3, "lse", TokenType.else_keyword),
        'f' => {
            if (@intFromPtr(scanner.current) - @intFromPtr(scanner.start) > 1) {
                switch (scanner.start[1]) {
                    'a' => return checkKeyword(2, 3, "lse", TokenType.false_keyword),
                    'o' => return checkKeyword(2, 1, "r", TokenType.for_keyword),
                    'n' => return checkKeyword(2, 0, "", TokenType.fn_keyword),
                    else => {},
                }
            }
        },
        'i' => return checkKeyword(1, 1, "f", TokenType.if_keyword),
        'n' => return checkKeyword(1, 3, "ull", TokenType.null_keyword),
        'o' => return checkKeyword(1, 1, "r", TokenType.or_keyword),
        'p' => return checkKeyword(1, 4, "rint", TokenType.print_keyword),
        'r' => return checkKeyword(1, 5, "eturn", TokenType.return_keyword),
        's' => {
            if (@intFromPtr(scanner.current) - @intFromPtr(scanner.start) > 1) {
                switch (scanner.start[1]) {
                    'e' => return checkKeyword(2, 2, "lf", TokenType.self_keyword),
                    'u' => return checkKeyword(2, 3, "per", TokenType.super_keyword),
                    else => {},
                }
            }
        },
        't' => return checkKeyword(1, 3, "rue", TokenType.true_keyword),
        'v' => return checkKeyword(1, 2, "ar", TokenType.var_keyword),
        'w' => return checkKeyword(1, 4, "hile", TokenType.while_keyword),
        else => {},
    }
    return TokenType.identifier;
}
