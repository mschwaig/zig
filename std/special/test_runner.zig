const os = @import("../os.zig");
const std = @import("std");
const io = std.io;
const builtin = @import("builtin");
const fork_executor = @import("fork_executor.zig");
const test_fn_list = builtin.test_functions;
const warn = std.debug.warn;

const Result =  enum {
        Ok,
};

fn processTest (test_fn_idx: usize) anyerror!Result {
    const test_fn = test_fn_list[test_fn_idx];
    if (test_fn.func()) |_| {
        return .Ok;
    } else |err| return err;
}
var forkRunner = fork_executor.ForkExecutor(usize, Result, anyerror, processTest){};

pub fn main() !void {
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    if (builtin.os == builtin.Os.linux) {
        // it is not possible to pass test_fn_list to forkRunner directly :(
        var indices = [_]usize{0} ** test_fn_list.len;
        for (indices) |*index, i| {
            index.* = i;
        }
        var frame = async forkRunner.execute(indices[0..], 4);
        for (test_fn_list) |test_fn, i| {
            warn("{} {}/{} {}...", builtin.os, i + 1, test_fn_list.len, test_fn.name);

            if (forkRunner.getNextResult()) |_| {
                ok_count += 1;
                warn("OK\n");
            } else |err| switch (err) {
                error.SkipZigTest => {
                    skip_count += 1;
                    warn("SKIP\n");
                },
                else => return err,
            }
        }
    } else {
        for (test_fn_list) |test_fn, i| {
            warn("{} {}/{} {}...", builtin.os, i + 1, test_fn_list.len, test_fn.name);

            if (test_fn.func()) |_| {
                ok_count += 1;
                warn("OK\n");
            } else |err| switch (err) {
                error.SkipZigTest => {
                    skip_count += 1;
                    warn("SKIP\n");
                },
                else => return err,
            }
        }
    }
    if (ok_count == test_fn_list.len) {
        warn("All tests passed.\n");
    } else {
        warn("{} passed; {} skipped.\n", ok_count, skip_count);
    }
}
