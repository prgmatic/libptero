const std = @import("std");
const token = @import("token.zig");

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: usize = 1,
    column: usize = 1,

    pub fn next(self: *Lexer) !token.Token {
        try self.skipWhitespaceAndComments();
        const start_line = self.line;
        const start_column = self.column;
        if (self.index >= self.source.len) {
            return .{ .tag = .eof, .text = "", .line = start_line, .column = start_column };
        }
        const start = self.index;
        const c = self.advance();
        if (c == '"') return self.string(start, start_line, start_column);
        const tag = self.punctuation(start) orelse try self.word(c);
        return self.makeToken(tag, start, start_line, start_column);
    }

    fn punctuation(self: *Lexer, start: usize) ?token.Tag {
        for (punctuation_tokens) |entry| {
            if (!std.mem.startsWith(u8, self.source[start..], entry.text)) continue;
            for (1..entry.text.len) |_| _ = self.advance();
            return entry.tag;
        }
        return null;
    }

    fn word(self: *Lexer, first: u8) !token.Tag {
        const tag: token.Tag = if (first == '$') .register else if (std.ascii.isDigit(first)) .number else if (isIdentStart(first)) .ident else return error.UnexpectedCharacter;
        while (self.wordContinues(tag)) _ = self.advance();
        return tag;
    }

    fn wordContinues(self: *const Lexer, tag: token.Tag) bool {
        if (self.index == self.source.len) return false;
        if (tag == .number) return isNumberContinue(self.source[self.index]);
        return isIdentContinue(self.source[self.index]);
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

    fn skipWhitespaceAndComments(self: *Lexer) !void {
        while (self.index < self.source.len) {
            if (std.ascii.isWhitespace(self.source[self.index])) {
                _ = self.advance();
                continue;
            }
            if (!try self.skipComment()) return;
        }
    }

    fn skipComment(self: *Lexer) !bool {
        const remaining = self.source[self.index..];
        if (std.mem.startsWith(u8, remaining, "//")) {
            while (self.index < self.source.len and self.source[self.index] != '\n') _ = self.advance();
            return true;
        }
        if (!std.mem.startsWith(u8, remaining, "/*")) return false;
        _ = self.advance();
        _ = self.advance();
        try self.skipBlockComment();
        return true;
    }

    fn skipBlockComment(self: *Lexer) !void {
        while (self.index < self.source.len) {
            if (std.mem.startsWith(u8, self.source[self.index..], "*/")) {
                _ = self.advance();
                _ = self.advance();
                return;
            }
            _ = self.advance();
        }
        return error.UnterminatedComment;
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

// Longest spellings precede their prefixes so operators use maximal munch.
const punctuation_tokens = [_]struct { text: []const u8, tag: token.Tag }{
    .{ .text = ">>>=", .tag = .logical_shift_right_equal },
    .{ .text = ">>>", .tag = .logical_shift_right },
    .{ .text = ">>=", .tag = .shift_right_equal },
    .{ .text = "<<=", .tag = .shift_left_equal },
    .{ .text = "+%=", .tag = .plus_percent_equal },
    .{ .text = "-%=", .tag = .minus_percent_equal },
    .{ .text = "~|=", .tag = .nor_equal },
    .{ .text = ">>", .tag = .shift_right },
    .{ .text = "<<", .tag = .shift_left },
    .{ .text = ">=", .tag = .greater_equal },
    .{ .text = "<=", .tag = .less_equal },
    .{ .text = "==", .tag = .equal_equal },
    .{ .text = "!=", .tag = .not_equal },
    .{ .text = "+%", .tag = .plus_percent },
    .{ .text = "-%", .tag = .minus_percent },
    .{ .text = "~|", .tag = .nor },
    .{ .text = "+=", .tag = .plus_equal },
    .{ .text = "-=", .tag = .minus_equal },
    .{ .text = "*=", .tag = .star_equal },
    .{ .text = "/=", .tag = .slash_equal },
    .{ .text = "&=", .tag = .ampersand_equal },
    .{ .text = "|=", .tag = .pipe_equal },
    .{ .text = "^=", .tag = .caret_equal },
    .{ .text = "@", .tag = .at },
    .{ .text = "..", .tag = .dot_dot },
    .{ .text = ".", .tag = .dot },
    .{ .text = ":", .tag = .colon },
    .{ .text = ",", .tag = .comma },
    .{ .text = "<", .tag = .less },
    .{ .text = ">", .tag = .greater },
    .{ .text = "=", .tag = .equal },
    .{ .text = "+", .tag = .plus },
    .{ .text = "-", .tag = .minus },
    .{ .text = "*", .tag = .star },
    .{ .text = "/", .tag = .slash },
    .{ .text = "&", .tag = .ampersand },
    .{ .text = "|", .tag = .pipe },
    .{ .text = "^", .tag = .caret },
    .{ .text = "~", .tag = .tilde },
    .{ .text = "(", .tag = .l_paren },
    .{ .text = ")", .tag = .r_paren },
    .{ .text = "[", .tag = .l_bracket },
    .{ .text = "]", .tag = .r_bracket },
    .{ .text = "{", .tag = .l_brace },
    .{ .text = "}", .tag = .r_brace },
    .{ .text = ";", .tag = .semicolon },
};

test "lexer selects longest operators and tracks positions across comments" {
    var lexer = Lexer{ .source = "// header\n/* block */ reg $t0 >>>= 2; +%= -% ~|= != 0..4" };
    const expected = [_]token.Tag{ .ident, .register, .logical_shift_right_equal, .number, .semicolon, .plus_percent_equal, .minus_percent, .nor_equal, .not_equal, .number, .dot_dot, .number, .eof };
    for (expected, 0..) |tag, index| {
        const actual = try lexer.next();
        try std.testing.expectEqual(tag, actual.tag);
        if (index == 0) {
            try std.testing.expectEqual(@as(usize, 2), actual.line);
            try std.testing.expectEqual(@as(usize, 13), actual.column);
        }
    }
}

test "lexer rejects incomplete comments strings and invalid punctuation" {
    var comment = Lexer{ .source = "/* unfinished" };
    try std.testing.expectError(error.UnterminatedComment, comment.next());
    var string_lexer = Lexer{ .source = "\"unfinished" };
    try std.testing.expectError(error.UnterminatedString, string_lexer.next());
    var invalid = Lexer{ .source = "!" };
    try std.testing.expectError(error.UnexpectedCharacter, invalid.next());
}
