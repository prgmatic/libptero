const std = @import("std");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn next(self: *Lexer) !token.Token {
        self.skipWhitespaceAndComments();

        const start_line = self.line;
        const start_column = self.column;
        if (self.index >= self.source.len) {
            return .{ .tag = .eof, .text = "", .line = start_line, .column = start_column };
        }

        const start = self.index;
        const c = self.advance();
        switch (c) {
            '@' => return self.makeToken(.at, start, start_line, start_column),
            ',' => return self.makeToken(.comma, start, start_line, start_column),
            '<' => return self.makeToken(.less, start, start_line, start_column),
            '>' => return self.makeToken(.type_end, start, start_line, start_column),
            '=' => return self.makeToken(.equal, start, start_line, start_column),
            '+' => {
                if (self.index < self.source.len and self.source[self.index] == '=') {
                    _ = self.advance();
                    return self.makeToken(.plus_equal, start, start_line, start_column);
                }
                return error.UnexpectedCharacter;
            },
            '(' => return self.makeToken(.l_paren, start, start_line, start_column),
            ')' => return self.makeToken(.r_paren, start, start_line, start_column),
            '{' => return self.makeToken(.l_brace, start, start_line, start_column),
            '}' => return self.makeToken(.r_brace, start, start_line, start_column),
            ';' => return self.makeToken(.semicolon, start, start_line, start_column),
            '"' => return self.string(start, start_line, start_column),
            '$' => {
                while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
                    _ = self.advance();
                }
                return self.makeToken(.register, start, start_line, start_column);
            },
            else => {
                if (std.ascii.isDigit(c)) {
                    while (self.index < self.source.len and isNumberContinue(self.source[self.index])) {
                        _ = self.advance();
                    }
                    return self.makeToken(.number, start, start_line, start_column);
                }
                if (!isIdentStart(c)) return error.UnexpectedCharacter;
                while (self.index < self.source.len and isIdentContinue(self.source[self.index])) {
                    _ = self.advance();
                }
                return self.makeToken(.ident, start, start_line, start_column);
            },
        }
    }

    fn makeToken(self: *Lexer, tag: token.Tag, start: usize, line: usize, column: usize) token.Token {
        return .{ .tag = tag, .text = self.source[start..self.index], .line = line, .column = column };
    }

    fn string(self: *Lexer, start: usize, line: usize, column: usize) !token.Token {
        while (self.index < self.source.len) {
            const ch = self.advance();
            if (ch == '\\') {
                if (self.index < self.source.len) _ = self.advance();
                continue;
            }
            if (ch == '"') {
                return .{
                    .tag = .string,
                    .text = self.source[start + 1 .. self.index - 1],
                    .line = line,
                    .column = column,
                };
            }
        }
        return error.UnterminatedString;
    }

    fn advance(self: *Lexer) u8 {
        const c = self.source[self.index];
        self.index += 1;
        if (c == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        return c;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (std.ascii.isWhitespace(c)) {
                _ = self.advance();
                continue;
            }
            if (c == '/' and self.index + 1 < self.source.len) {
                if (self.source[self.index + 1] == '/') {
                    while (self.index < self.source.len and self.source[self.index] != '\n') {
                        _ = self.advance();
                    }
                    continue;
                }
                if (self.source[self.index + 1] == '*') {
                    _ = self.advance();
                    _ = self.advance();
                    while (self.index + 1 < self.source.len) {
                        if (self.source[self.index] == '*' and self.source[self.index + 1] == '/') {
                            _ = self.advance();
                            _ = self.advance();
                            break;
                        }
                        _ = self.advance();
                    }
                    continue;
                }
            }
            break;
        }
    }
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isNumberContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '\'';
}
