const std = @import("std");
const os = std.os;
const io = std.io;
const builtin = @import("builtin");
const warn = std.debug.warn;

const assert = std.debug.assert;

pub fn ForkExecutor(comptime X: type, comptime Y: type, comptime ERR: type,
                comptime f: fn (X) ERR!Y) type {
    return struct {

        const Self = @This();

        execute_frame: anyframe = undefined,
        result_buffer: ResultOrFailed = undefined,

        const Faults = error {
            SegmentationFault,
        };

        const SafeErrorSet = ERR || Faults;

        const OkOrFailed = enum {
            Ok,
            Failed
        };

        const ResultOrFailed = union(OkOrFailed) {
            Ok: Y,
            Failed: SafeErrorSet,
        };

        const IndexedResult = struct {
            index: usize,
            result_or_failed: ResultOrFailed,

            fn lessThan(lhs: IndexedResult, rhs: IndexedResult) bool {
                return lhs.index < rhs.index;
            }
        };

        fn testWorker(input_list: []X, param_fd: i32, result_fd: i32) !void {
            while (true)
            {
                var index_bytes = [_]u8{0} ** @sizeOf(usize);
                switch(try os.read(param_fd, &index_bytes)) {
                    @sizeOf(@typeOf(index_bytes)) => {},
                    0 => {
                        return;
                    },
                    else => undefined,
                }
                const index: usize = @bytesToSlice(usize, index_bytes)[0];
                rt_panic = pipe_panic;
                fault_result_fd = result_fd;
                fault_index = index;
                const input = input_list[index];
                var result_or_failed =
                    if (f(input)) |y| ResultOrFailed { .Ok = y }
                    else | err | ResultOrFailed { .Failed = err };

                var indexed_result = IndexedResult {.index = index, .result_or_failed = result_or_failed};
                var indexed_result_slice = [_]IndexedResult{indexed_result};
                try os.write(result_fd, @sliceToBytes( indexed_result_slice[0..]));
            }
        }

        fn execute(self: *Self, input_list: []X, process_count: usize) !void {

            assert(process_count > 0);

            const result_fds = try os.pipe();
            const result_read = result_fds[0];
            const result_write = result_fds[1];
            const param_fds = try os.pipe();
            const param_read = param_fds[0];
            const param_write = param_fds[1];
            // write input parameters to pipe
            for (input_list) |_, i| {
                var idx = [_]usize{i};
                const bytes = @sliceToBytes(idx[0..]);
                try os.write(param_write, bytes);
            }

            var i: usize = 0;
            while (i < process_count) {
                const pid = try os.fork();
                if (pid == 0) {
                    os.close(param_write);
                    os.close(result_read);
                    try testWorker(input_list, param_read, result_write);
                    os.close(param_read);
                    os.close(result_write);
                    os.exit(0);
                }
            i = i + 1;
            }
            os.close(param_write);
            os.close(param_read);
            os.close(result_write);

            var list = std.SinglyLinkedList(IndexedResult).init();
            self.execute_frame = @frame();
            suspend;
            const allocator = std.debug.global_allocator;
            i = 0;
            while (i < input_list.len) {
                const first = list.peekFirst();
                if (first)|frst|{
                    if (frst.data.index == i) {
                        _ = list.popFirst();
                        self.result_buffer = frst.data.result_or_failed;
                        allocator.destroy(frst);
                        i = i + 1;
                        suspend;
                    }
                }
                var result_bytes = [_]u8{0} ** @sizeOf(IndexedResult);
                switch(try os.read(result_read, &result_bytes)) {
                    @sizeOf(@typeOf(result_bytes)) => {},
                    else => undefined,
                }
                const indexed_result: IndexedResult = @bytesToSlice(IndexedResult, result_bytes)[0];

                var node = try list.createNode(indexed_result, allocator);
                list.insertSorted(node, IndexedResult.lessThan);
            }
            os.close(result_read);
        }

        fn getNextResult(self: Self) SafeErrorSet!Y {
            resume self.execute_frame;
            return switch (self.result_buffer) {
                .Ok => |r| r,
                .Failed => |err| err,
            };
        }

        pub fn pipe_panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
            var faulted = ResultOrFailed { .Failed = Faults.SegmentationFault };

            var indexed_result = IndexedResult {.index = fault_index orelse unreachable, .result_or_failed = faulted};
            var indexed_result_slice = [_]IndexedResult{indexed_result};
            os.write(fault_result_fd orelse unreachable, @sliceToBytes( indexed_result_slice[0..])) catch unreachable;

            os.exit(0);
        }
    };
}

fn purify (x: i32) error{}!i32 { return x*2; }
var purefunction = ForkExecutor(i32, i32, error{}, purify){};

fn badstuff (x: i32) error{}!i32 {
    var ptr: ?*i32 = null;
    var b = ptr.?;
    return b.*;
}
var pureevilfunction = ForkExecutor(i32, i32, error{}, badstuff){};

test "should compute" {
    var input = [_]i32  {2, 4};
    var output = [_]i32 {1, 1};
    var frame = async purefunction.execute(input[0..], 1);
    assert(2 == input[0]);
    assert(4 ==  try purefunction.getNextResult());
    assert(8 ==  try purefunction.getNextResult());
}

test "should not segfault parent" {
    var input = [_]i32  {2, 4};
    var output = [_]i32 {1, 1};
    var frame = async pureevilfunction.execute(input[0..], 1);
    assert(2 == input[0]);
    std.testing.expectError(error.SegmentationFault, pureevilfunction.getNextResult());
}

var rt_panic: ?@typeOf(panic) = null;
var fault_result_fd: ?i32 = null;
var fault_index: ?usize = null;

pub fn panic(msg: []const u8, error_return_trace: ?*builtin.StackTrace) noreturn {
    @setCold(true);
    if (rt_panic) |p|{
      p(msg, error_return_trace);
    } else switch (builtin.os) {
        .freestanding => {
            while (true) {
                @breakpoint();
            }
        },
        .wasi => {
            std.debug.warn("{}", msg);
            _ = std.os.wasi.proc_raise(std.os.wasi.SIGABRT);
            unreachable;
        },
        .uefi => {
            // TODO look into using the debug info and logging helpful messages
            std.os.abort();
        },
        else => {
            const first_trace_addr = @returnAddress();
            std.debug.panicExtra(error_return_trace, first_trace_addr, "{}", msg);
        },
    }
}