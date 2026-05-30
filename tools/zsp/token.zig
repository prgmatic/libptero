pub const Tag = enum {
    eof,
    ident,
    string,
    number,
    register,
    at,
    colon,
    comma,
    equal,
    plus_equal,
    less,
    type_start,
    type_end,
    l_paren,
    r_paren,
    l_brace,
    r_brace,
    semicolon,
};

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    line: usize,
    column: usize,
};
