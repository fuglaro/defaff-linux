//! 'nix Terminal Multiplexer sans the faff.

const max_wins = 256;
const io_buf_sz = 4096;

const std = @import("std");
const os = std.os;
const termios = std.c.termios;
const File = std.fs.File;
const WinSize = std.c.winsize;
const BoundedArray = std.BoundedArray;
const tst = std.testing;
const in = std.io.getStdIn();
const ctermios = @cImport(@cInclude("termios.h"));

extern fn forkpty(*os.fd_t, ?[*:0]const u8, ?*const termios, ?*const WinSize) os.pid_t;
extern fn getpid() os.pid_t;
extern fn waitpid(os.pid_t, ?*c_int, c_int) os.pid_t;

/// Setup signal handlers for proxying SIGINT and responding to SIGCHLD.
/// After registering, SIGINTS will interupt
fn registerSigHandlers() !void {
    try os.sigaction(os.SIG.INT, &os.Sigaction{
        .handler = .{ .handler = handleSigInt },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);
}

/// Increments atomically on SIGINT.
var sigint: u32 = 0;
fn handleSigInt(_: c_int) callconv(.C) void {
    _ = @atomicRmw(u32, &sigint, .Add, 1, .SeqCst);
}
// TODO: try asking the tty to not sigint on Ctrl+C instead of worrying about signal handling. Then SigInt to this process can abort.

test "registerSigHandlers" {
    try registerSigHandlers();
    try tst.expect(sigint == 0);
    try os.raise(os.SIG.INT);
    try tst.expect(sigint == 1);
    try os.raise(os.SIG.INT);
    try os.raise(os.SIG.INT);
    try os.raise(os.SIG.INT);
    try os.raise(os.SIG.INT);
    try os.raise(os.SIG.INT);
    try tst.expect(sigint == 6);
}

/// Manages a group of child terminals (windows),
const WinPool = struct {
    const Self = @This();
    fd: BoundedArray(File, max_wins), // Pseudo terminal connections for children.
    pid: BoundedArray(os.pid_t, max_wins), // Process ids for children.
    poll: BoundedArray(os.pollfd, max_wins), // Handles for waiting on input.

    /// Initialise the Window Pool,
    /// with the first entry being passed in with `fd`.
    fn init(fd: File) WinPool {
        var w = WinPool{
            .fd = BoundedArray(File, max_wins).init(1) catch unreachable,
            .pid = BoundedArray(os.pid_t, max_wins).init(1) catch unreachable,
            .poll = BoundedArray(os.pollfd, max_wins).init(1) catch unreachable,
        };
        // Add stdin at index 0
        w.fd.set(0, fd);
        w.pid.set(0, 0);
        w.poll.set(0, .{ .fd = fd.handle, .events = os.POLL.IN, .revents = 0 });
        return w;
    }

    /// Execute a new pseudo terminal command in a new window.
    /// `args` specifies the executable and arguments to launch,
    /// the environment inherits from the current process,
    /// `cols` and `rows` specifies the width and height of the pseudo terminal.
    /// Returns Overflow error if capacity would be exceeded.
    /// Errors on SystemResources or NotATerminal.
    fn append(self: *Self, args: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) !void {
        var fd = try self.fd.addOne();
        const pid = try self.pid.addOne();
        pid.* = try pty_child(fd, args, cols, rows);
        var poll = try self.poll.addOne();
        poll.* = .{ .fd = fd.handle, .events = os.POLL.IN, .revents = 0 };
    }

    /// Wait (with minimal resource use) for data from any child, or this process' stdin.
    /// Registered signal handlers will also exit this function.
    fn wait(self: *Self) void {
        // Wait as long as possible for any data.
        var p = self.poll.slice();
        const len = std.math.cast(std.os.nfds_t, p.len) orelse unreachable;
        while (true) {
            const rc = std.os.system.poll(p.ptr, len, std.math.maxInt(i32));
            switch (os.errno(rc)) {
                .SUCCESS, .AGAIN, .INTR, .NOMEM => break,
                else => unreachable,
            }
        }
    }

    /// Returns an optional for reading at the given index, if it has buffered data ready.
    /// Call `wait` to ready this function.
    fn ready(self: *Self, i: usize) ?*const File {
        if (self.poll.constSlice()[i].revents & os.POLL.IN == 0) return null;
        return &self.fd.constSlice()[i];
    }

    // Clean up any ended processes, and return the process pid.
    // Removes the entries from `pty` and `poll` and swaps the last entry into the gap.
    fn popKilled(self: *Self) ?os.pid_t {
        const pid = waitpid(-1, null, std.c.W.NOHANG);
        if (pid <= 0) return null;
        for (self.pid.constSlice(), 0..) |p, i| {
            if (p == pid) {
                _ = self.poll.swapRemove(i);
                _ = self.fd.swapRemove(i);
                return self.pid.swapRemove(i);
            }
        }
        return null;
    }

    // TODO XXX handle when cant write all bytes.
    //TODO XXX fix waiting on all file descriptors and add test waitAndHandlePending? (see run currently)
    fn waitAndHandlePending(self: *Self, out: *const File) !void {
        var buf: [io_buf_sz]u8 = undefined;
        std.debug.print("1\n", .{});
        self.wait();
        std.debug.print("2\n", .{});
        const fds = self.fd.slice();
        for (0..fds.len) |i| {
            std.debug.print("    >\n", .{});
            const f = self.ready(i) orelse continue;
            const n = f.read(&buf) catch continue; // TODO XXX partial read / write?
            if (i == 0) {
                // Handle input.
                // TODO: manage selected window.
                const sel = fds[1]; // TODO: if empty?
                std.debug.print("    3 >>>{s}<<<\n", .{buf});
                _ = try sel.writeAll(&buf);
                std.debug.print("    4\n", .{});
                continue;
            }
            // Handle data from children.

            std.debug.print("  __{d} {d} [[[[[{s}]]]]]\n", .{ i, n, buf });
            _ = try out.writeAll(&buf);
        }
        // Cleanup finished processes.
        std.debug.print("8\n", .{});
        while (self.popKilled() != null) {}
        std.debug.print("9\n", .{});
    }
};

test "WinPool waitAndHandlePending" {
    var wins = WinPool.init(in);
    try wins.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    try wins.waitAndHandlePending(&std.io.getStdOut());
    // TODO XXX finish
    //var stdob = std.io.bufferedWriter(std.io.getStdOut().writer());
    //const stdo = stdob.writer();
    //try stdob.flush();
}

test "WinPool fake stdin" {
    var fd: File = undefined;
    _ = try pty_child(&fd, &([_:null]?[*:0]const u8{"cat"}), 0, 0);
    var wins = WinPool.init(fd);
    try tst.expect(wins.fd.get(0).handle == fd.handle);
    try tst.expect(wins.pid.get(0) == 0);
    try fd.writeAll("hi\n");
    wins.wait();
    try tst.expect(wins.ready(0).? == &wins.fd.constSlice()[0]);
    const exp = "hi\r\n";
    var buf: [exp.len]u8 = undefined;
    try tst.expectEqual(buf.len, try wins.fd.get(0).readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    fd.close();
}

test "WinPool popKilled" {
    var wins = WinPool.init(in);
    try tst.expect(wins.popKilled() == null);
    try wins.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    try wins.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    try tst.expect(wins.fd.len == 3);
    var buf: [io_buf_sz]u8 = undefined;
    _ = try wins.fd.get(1).read(&buf);
    try tst.expect(wins.popKilled().? != 0);
    _ = try wins.fd.get(1).read(&buf);
    try tst.expect(wins.popKilled().? != 0); // TODO XXX this is stil sometimes null...
    try tst.expect(wins.popKilled() == null);
    try wins.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    _ = try wins.fd.get(1).read(&buf);
    try tst.expectEqual(wins.pid.get(1), wins.popKilled().?);
    try tst.expect(wins.fd.len == 1);
}

test "WinPool popKilled no hang" {
    var wins = WinPool.init(in);
    const start = std.time.milliTimestamp();
    try wins.append(&([_:null]?[*:0]const u8{ "sleep", "2" }), 0, 0);
    try tst.expect(wins.popKilled() == null);
    try tst.expect(std.time.milliTimestamp() < start + 100);
    wins.fd.get(1).close();
}

test "WinPool wait interrupted by sigchild" {
    var wins = WinPool.init(in);
    const start = std.time.milliTimestamp();
    try wins.append(&([_:null]?[*:0]const u8{ "sleep", "2" }), 0, 0);
    try wins.append(&([_:null]?[*:0]const u8{ "sleep", "0.001" }), 0, 0);
    wins.wait();
    try tst.expect(std.time.milliTimestamp() < start + 100);
    wins.fd.get(1).close();
    wins.fd.get(2).close();
}
test "WinPool wait interrupted by sigint" {
    var wins = WinPool.init(in);
    const start = std.time.milliTimestamp();
    try wins.append(&([_:null]?[*:0]const u8{
        "sh", "-c",
        \\sleep 0.001; kill -s=INT `ps -o ppid= -p $$` > /dev/null; sleep 2
    }), 0, 0);
    wins.wait();
    try tst.expect(std.time.milliTimestamp() < start + 100);
    wins.fd.get(1).close();
}

test "WinPool append and read" {
    var wins = WinPool.init(in);
    try wins.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    try wins.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    const exp = "pong\r\n";
    var buf: [exp.len]u8 = undefined;
    for (1..9) |i| {
        try wins.fd.get(i % 2 + 1).writeAll("ping\n");
        try tst.expectEqual(buf.len, try wins.fd.get(i % 2 + 1).readAll(&buf));
        try tst.expectEqualStrings(exp, &buf);
    }
    wins.fd.get(1).close();
    wins.fd.get(2).close();
}

test "WinPool wait and ready" {
    var wins = WinPool.init(in);
    try wins.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    try wins.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    const exp = "pong\r\n";
    var buf: [exp.len]u8 = undefined;
    // Communicate with first process
    try wins.fd.get(2).writeAll("ping\n");
    wins.wait();
    try tst.expect(wins.ready(1) == null);
    try tst.expect(wins.ready(2).? == &wins.fd.constSlice()[2]);
    try tst.expectEqual(buf.len, try wins.ready(2).?.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    // Communicate with second process
    try wins.fd.get(1).writeAll("ping\n");
    wins.wait();
    wins.wait();
    try tst.expect(wins.ready(1).? == &wins.fd.constSlice()[1]);
    try tst.expect(wins.ready(2) == null);
    try tst.expectEqual(buf.len, try wins.ready(1).?.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    wins.fd.get(1).close();
    wins.fd.get(2).close();
}

/// Launch a child process through a new pseudo terminal connection.
/// `args` specifies the executable and arguments to launch,
/// the environment inherits from the current process,
/// `cols` and `rows` specifies the width and height of the pseudo terminal.
/// The pseudo terminal IO handle is passed back via `fd` the process id is returned.
/// Options the pseudo terminal are selected best for multiplexed proxying:
/// - lflag: OPOST, ONLCP
/// - iflag: BRKINT, IXON, IXANY
/// - cflag: CS8, CREAD, HUPCL
/// - lflag: ISIG
/// Errors on SystemResources or NotATerminal.
fn pty_child(fd: *File, args: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) !os.pid_t {
    const ws = WinSize{ .ws_col = cols, .ws_row = rows, .ws_xpixel = 0, .ws_ypixel = 0 };
    // Terminal settings
    var tm = try std.os.tcgetattr(in.handle);
    tm.oflag = ctermios.OPOST | ctermios.ONLCR;
    tm.iflag = ctermios.BRKINT | ctermios.IXON | ctermios.IXANY;
    tm.cflag = ctermios.CS8 | ctermios.CREAD | ctermios.HUPCL;
    tm.lflag = ctermios.ISIG;
    // Fork off child pty process
    const pid: os.pid_t = forkpty(&fd.handle, null, &tm, &ws);
    switch (os.errno(pid)) { // Handle failure cases
        .SUCCESS => {},
        .NOENT, .NOMEM, .AGAIN => return error.SystemResources,
        else => unreachable,
    }
    // Handle child fork
    if (pid == 0) {
        _ = os.execvpeZ_expandArg0(.no_expand, args[0].?, args, std.c.environ) catch {};
        os.exit(1);
    }
    // Handle parent fork
    return pid;
}

test "pty_child repeat io" {
    var fd: File = undefined;
    _ = try pty_child(&fd, &([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    const exp = "pong\r\n";
    var buf: [exp.len]u8 = undefined;
    for (1..9) |_| {
        try fd.writeAll("ping\n");
        try tst.expectEqual(buf.len, try fd.readAll(&buf));
        try tst.expectEqualStrings(exp, &buf);
    }
    fd.close();
}

test "pty_child hello world" {
    var fd: File = undefined;
    _ = try pty_child(&fd, &([_:null]?[*:0]const u8{ "echo", "hello" }), 0, 0);
    try fd.writeAll("hi\n");
    const exp = "hello\r\n";
    var buf: [exp.len]u8 = undefined;
    try tst.expectEqual(buf.len, try fd.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    fd.close();
}

test "pty_child win size set" {
    var fd: File = undefined;
    _ = try pty_child(&fd, &([_:null]?[*:0]const u8{ "tput", "cols", "lines" }), 11, 22);
    const exp = "11\r\n22\r\n";
    var buf: [exp.len]u8 = undefined;
    try tst.expectEqual(buf.len, try fd.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    fd.close();
}

pub fn main() !void {
    // Set up stdin for proxying // TODO XXX test this be pushing to a separate function.
    var tm = try std.os.tcgetattr(in.handle);
    // Ensure we don't capture things like ^C -> SIGONT
    tm.iflag = 0;
    tm.lflag = 0;
    try std.os.tcsetattr(in.handle, std.c.TCSA.NOW, tm);

    // Set up Window Management
    var wins = WinPool.init(in);

    //var gmem = std.heap.GeneralPurposeAllocator(.{}){};
    //const gpa = gmem.allocator();

    const out = std.io.getStdOut();

    try wins.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/X/V/g" }), 80, 40);
    while (wins.fd.len > 1) {
        std.debug.print(".\n", .{});
        try wins.waitAndHandlePending(&out);
    }
}
