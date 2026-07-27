const n64 = @import("n64");
const testing = @import("assert.zig");

pub const TestFn = *const fn () anyerror!void;

pub const Test = struct {
    name: []const u8,
    run: TestFn,
};

pub const Result = struct {
    name: []const u8,
    failure: ?Failure,
};

pub const Failure = struct {
    err: anyerror,
    diagnostic: ?testing.Diagnostic,
};

pub const Summary = struct {
    passed: usize,
    failed: usize,
};

pub fn run(tests: []const Test, results: []Result) Summary {
    var summary: Summary = .{ .passed = 0, .failed = 0 };

    for (tests, results) |test_case, *result| {
        n64.debug.print("[ RUN  ] {s}\n", .{test_case.name});
        testing.reset();

        test_case.run() catch |err| {
            const diagnostic = testing.failure();
            result.* = .{
                .name = test_case.name,
                .failure = .{
                    .err = err,
                    .diagnostic = diagnostic,
                },
            };
            summary.failed += 1;
            n64.debug.print("[ FAIL ] {s}: {s}\n", .{
                test_case.name,
                @errorName(err),
            });
            if (diagnostic) |details| {
                n64.debug.print("         {s}\n", .{details.messageSlice()});
                if (!n64.debug.srcmap.printLineInfo(0, details.address)) {
                    n64.debug.print("         at 0x{x:0>8}\n", .{details.address});
                }
            }
            continue;
        };

        result.* = .{ .name = test_case.name, .failure = null };
        summary.passed += 1;
        n64.debug.print("[ PASS ] {s}\n", .{test_case.name});
    }

    n64.debug.print("\n{d} passed, {d} failed\n", .{
        summary.passed,
        summary.failed,
    });
    n64.debug.print(
        "@@LIBPTERO_TEST_END@@ {{\"passed\":{d},\"failed\":{d}}}\n",
        .{ summary.passed, summary.failed },
    );
    return summary;
}
