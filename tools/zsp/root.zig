//! Programmatic ZSP compilation. Callers own source and AST lifetimes; results
//! own their assembly bytes and can outlive the parsed program.
pub const Loader = @import("modules.zig").Loader;
pub const Program = @import("source.zig").Program;
pub const ParseDiagnostic = @import("parser.zig").Diagnostic;
pub const ast = @import("ast.zig");
pub const Diagnostic = @import("asm_writer.zig").Diagnostic;
pub const ExplainReport = @import("asm_writer.zig").ExplainReport;
pub const Options = @import("compiler.zig").Options;
pub const Result = @import("compiler.zig").Result;
pub const compile = @import("compiler.zig").compile;
pub const writeInterface = @import("asm_writer.zig").writeInterface;
