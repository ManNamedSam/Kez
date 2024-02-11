const std = @import("std");

pub const Scanner = struct {
    source: []const u8 = undefined,
    start: [*]const u8 = undefined,
    current: [*]const u8 = undefined,
    line: u32 = undefined,

    pub fn init(self: *Scanner, source: []const u8) void {
        // scanner = Scanner{
        self.source = source;
        self.start = source.ptr;
        self.current = source.ptr;
        self.line = 1;
        // };
    }

    pub fn scanToken(self: *Scanner) Token {
        self.skipWhiteSpace();
        self.start = self.current;

        if (self.isAtEnd()) return self.makeToken(TokenType.eof);

        const c = self.advance();
        if (isDigit(c)) return self.number();
        if (isAlpha(c)) return self.identifier();

        switch (c) {
            '(' => return self.makeToken(TokenType.left_paren),
            ')' => return self.makeToken(TokenType.right_paren),
            '{' => return self.makeToken(TokenType.left_brace),
            '}' => return self.makeToken(TokenType.right_brace),
            '[' => return self.makeToken(TokenType.left_bracket),
            ']' => return self.makeToken(TokenType.right_bracket),
            ';' => return self.makeToken(TokenType.semicolon),
            ':' => return self.makeToken(TokenType.colon),
            ',' => return self.makeToken(TokenType.comma),
            '.' => return self.makeToken(TokenType.dot),
            '+' => return self.makeToken(if (self.match('=')) TokenType.plus_equal else TokenType.plus),
            '-' => return self.makeToken(if (self.match('=')) TokenType.minus_equal else TokenType.minus),
            '/' => return self.makeToken(if (self.match('=')) TokenType.slash_equal else TokenType.slash),
            '*' => return self.makeToken(if (self.match('=')) TokenType.star_equal else TokenType.star),
            '%' => return self.makeToken(if (self.match('=')) TokenType.modulo_equal else TokenType.modulo),
            '!' => return self.makeToken(if (self.match('=')) TokenType.bang_equal else TokenType.bang),
            '=' => return self.makeToken(if (self.match('=')) TokenType.equal_equal else TokenType.equal),
            '<' => return self.makeToken(if (self.match('=')) TokenType.less_equal else TokenType.less),
            '>' => return self.makeToken(if (self.match('=')) TokenType.greater_equal else TokenType.greater),
            '"' => return self.string(),
            else => return self.errorToken("Unexpected character."),
        }

        // return errorToken("Unexpected character.");
    }

    fn isAtEnd(self: *Scanner) bool {
        const position = @intFromPtr(self.current) - @intFromPtr(self.source.ptr);
        return position >= self.source.len;
    }

    fn advance(self: *Scanner) u8 {
        const result = self.current[0];
        self.current += 1;
        return result;
    }

    fn peek(self: *Scanner) u8 {
        return self.current[0];
    }

    fn peekNext(self: *Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.current[1];
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.current[0] != expected) return false;
        self.current += 1;
        return true;
    }

    fn makeToken(self: *Scanner, token_type: TokenType) Token {
        return Token{
            .type = token_type,
            .start = self.start,
            .length = @intFromPtr(self.current) - @intFromPtr(self.start),
            .line = self.line,
        };
    }

    fn errorToken(self: *Scanner, message: []const u8) Token {
        return Token{
            .type = TokenType.error_,
            .start = message.ptr,
            .length = message.len,
            .line = self.line,
        };
    }

    fn skipWhiteSpace(self: *Scanner) void {
        while (true) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => {
                    _ = self.advance();
                },
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() == '/') {
                        while (self.peek() != '\n' and !self.isAtEnd()) _ = self.advance();
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn checkKeyword(self: *Scanner, start: usize, length: usize, rest: [*]const u8, token_type: TokenType) TokenType {
        if (@intFromPtr(self.current) - @intFromPtr(self.start) == start + length and std.mem.eql(u8, self.start[start..(start + length)], rest[0..length])) {
            return token_type;
        }

        return TokenType.identifier;
    }

    fn number(self: *Scanner) Token {
        while (isDigit(self.peek())) _ = self.advance();

        if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance();
            while (isDigit(self.peek())) _ = self.advance();
        }

        return self.makeToken(TokenType.number);
    }

    fn string(self: *Scanner) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            if (self.peek() == '\\') {
                _ = self.advance();
            }
            _ = self.advance();
        }

        if (self.isAtEnd()) return self.errorToken("Unterminated string.");

        _ = self.advance();
        return self.makeToken(TokenType.string);
    }

    fn identifier(self: *Scanner) Token {
        while (isAlpha(self.peek()) or isDigit(self.peek())) _ = self.advance();
        return self.makeToken(self.identifierType());
    }

    fn identifierType(self: *Scanner) TokenType {
        switch (self.start[0]) {
            'a' => return self.checkKeyword(1, 2, "nd", TokenType.and_keyword),
            'c' => return self.checkKeyword(1, 4, "lass", TokenType.class_keyword),
            'e' => return self.checkKeyword(1, 3, "lse", TokenType.else_keyword),
            'f' => {
                if (@intFromPtr(self.current) - @intFromPtr(self.start) > 1) {
                    switch (self.start[1]) {
                        'a' => return self.checkKeyword(2, 3, "lse", TokenType.false_keyword),
                        'o' => return self.checkKeyword(2, 1, "r", TokenType.for_keyword),
                        'n' => return self.checkKeyword(2, 0, "", TokenType.fn_keyword),
                        else => {},
                    }
                }
            },
            'i' => return self.checkKeyword(1, 1, "f", TokenType.if_keyword),
            'n' => return self.checkKeyword(1, 3, "ull", TokenType.null_keyword),
            'o' => return self.checkKeyword(1, 1, "r", TokenType.or_keyword),
            'p' => return self.checkKeyword(1, 4, "rint", TokenType.print_keyword),
            'r' => return self.checkKeyword(1, 5, "eturn", TokenType.return_keyword),
            's' => {
                if (@intFromPtr(self.current) - @intFromPtr(self.start) > 1) {
                    switch (self.start[1]) {
                        'e' => return self.checkKeyword(2, 2, "lf", TokenType.self_keyword),
                        'u' => return self.checkKeyword(2, 3, "per", TokenType.super_keyword),
                        else => {},
                    }
                }
            },
            't' => return self.checkKeyword(1, 3, "rue", TokenType.true_keyword),
            'v' => return self.checkKeyword(1, 2, "ar", TokenType.var_keyword),
            'w' => return self.checkKeyword(1, 4, "hile", TokenType.while_keyword),
            else => {},
        }
        return TokenType.identifier;
    }
};

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

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
    colon,
    semicolon,
    //One or two character tokens.
    minus,
    minus_equal,
    plus,
    plus_equal,
    slash,
    slash_equal,
    star,
    star_equal,
    modulo,
    modulo_equal,
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

// var scanner: Scanner = undefined;

// pub fn initScanner(source: []const u8) void {
//     scanner = Scanner{
//         .source = source,
//         .start = source.ptr,
//         .current = source.ptr,
//         .line = 1,
//     };
// }
