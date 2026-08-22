const n64 = @import("n64");
const testing = @import("assert.zig");

pub const TestFn = *const fn () anyerror!void;

pub const Test = struct {
    name: []const u8,
    run: TestFn,
};

pub const Summary = struct {
    passed: usize,
    failed: usize,
};

pub fn run(tests: []const Test) Summary {
    var summary: Summary = .{ .passed = 0, .failed = 0 };

    if (tests.len > 0) n64.debug.print("[Run] {s}", .{tests[0].name});

    for (tests, 0..) |test_case, test_index| {
        testing.reset();

        test_case.run() catch |err| {
            const diagnostic = testing.failure();
            summary.failed += 1;
            if (err == error.RspTimeout) {
                n64.debug.print(" [Timeout ⏱️]\n", .{});
            } else {
                n64.debug.print(" [Fail ❌]\n", .{});
                n64.debug.print("      {s}\n", .{@errorName(err)});
            }
            if (diagnostic) |details| {
                n64.debug.print("      {s}\n", .{details.messageSlice()});
                if (!n64.debug.srcmap.printLineInfo(0, details.address)) {
                    n64.debug.print("      at 0x{x:0>8}\n", .{details.address});
                }
            }
            if (test_index + 1 < tests.len) {
                n64.debug.print("[Run] {s}", .{tests[test_index + 1].name});
            }
            continue;
        };

        summary.passed += 1;
        if (test_index + 1 < tests.len) {
            n64.debug.print(" [Pass ✅]\n[Run] {s}", .{tests[test_index + 1].name});
        } else {
            n64.debug.print(" [Pass ✅]\n", .{});
        }
    }

    n64.debug.print(
        "\n{d} passed, {d} failed\n" ++
            "@@LIBPTERO_TEST_END@@ {{\"passed\":{d},\"failed\":{d}}}\n",
        .{ summary.passed, summary.failed, summary.passed, summary.failed },
    );
    return summary;
}
