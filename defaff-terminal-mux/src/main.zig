//! 'nix Terminal Multiplexer sans the faff.

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

const max_pool = 256; // Maximum number of child processes.
const io_buf_sz = 4096; // Internal IO buffer size.

// Input buffer.
var ibuf: [io_buf_sz]u8 = undefined;
var ibufi: usize = 0;
var ibufc: usize = 0;

/// Manages a group of child pty processes, and an input stream to interact with them.
/// There is a maximum (max_pool) limit to number of children.
/// The last entry of polls is always ithe input stream, and polls is one longer than pids.
var pool = Pool.init(in.handle);
const Pool = struct {
    const Self = @This();
    pids: BoundedArray(os.pid_t, max_pool), // Process ids for children.
    polls: BoundedArray(os.pollfd, max_pool + 1), // IO children and input (last entry).

    /// Initialise an empty Pool with the given input stream.
    fn init(input: os.fd_t) Pool {
        var p = Self{
            .pids = BoundedArray(os.pid_t, max_pool).init(0) catch unreachable,
            .polls = BoundedArray(os.pollfd, max_pool + 1).init(1) catch unreachable,
        };
        // Add input as last entry for polls.
        p.polls.set(0, .{ .fd = input, .events = os.POLL.IN, .revents = 0 });
        return p;
    }

    /// Execute a new pseudo terminal command in a new window.
    /// `args` specifies the executable and arguments to launch.
    /// The environment inherits from the current process.
    /// `cols` and `rows` specifies the width and height of the pseudo terminal.
    /// Returns Overflow error if capacity would be exceeded.
    /// Errors on SystemResources or NotATerminal.
    fn append(self: *Self, args: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) !void {
        var fd: os.fd_t = undefined;
        const pid = try self.pids.addOne();
        pid.* = try pty_child(&fd, args, cols, rows);
        _ = try os.fcntl(fd, os.F.SETFL, os.O.NONBLOCK);
        try self.polls.insert(self.polls.len - 1, .{ .fd = fd, .events = os.POLL.IN, .revents = 0 });
    }

    /// Wait (with minimal resource use) for data from any child, or the input.
    /// Registered signal handlers will also exit this function.
    fn wait(self: *Self) void {
        // Wait as long as possible for any data.
        var p = self.polls.slice();
        const len = std.math.cast(os.nfds_t, p.len) orelse unreachable;
        while (true) {
            const rc = os.system.poll(p.ptr, len, std.math.maxInt(i32));
            switch (os.errno(rc)) {
                .SUCCESS, .AGAIN, .INTR, .NOMEM => break,
                else => unreachable,
            }
        }
    }

    /// Returns an optional for reading at the given index, if it has buffered data ready.
    /// Call `wait` to prepare the cache for this function.
    fn ready(self: *Self, i: usize) ?os.fd_t {
        const p = self.polls.constSlice()[i];
        if (p.revents & os.POLL.IN == 0) return null;
        return p.fd;
    }

    /// Clean up any ended processes, and return the process pid.
    /// Removes the entries from `pty` and `poll` and swaps the last entry into the gap.
    fn popKilled(self: *Self) ?os.pid_t {
        const pid = waitpid(-1, null, std.c.W.NOHANG);
        if (pid <= 0) return null;
        for (self.pids.constSlice(), 0..) |p, i| {
            if (p == pid) {
                _ = self.polls.swapRemove(i);
                return self.pids.swapRemove(i);
            }
        }
        return null;
    }

    /// XXX TODO test and doc and rename?
    fn waitAndReap(self: *Self, out: *const File) !void {
        // TODO fix

        // TODO: manage selected window
        const sel = 0; // TODO: when no process.
        var buf: [io_buf_sz]u8 = undefined;
        self.wait();
        const ps = self.polls.constSlice();
        // Handle data from children
        for (0..ps.len - 1) |i| {
            const f = self.ready(i) orelse continue;
            std.debug.print("<", .{});
            const rlen = os.read(f, &buf) catch continue;
            _ = try out.writeAll(&buf); // TODO XXX pass to buffers
            std.debug.print("|{d}", .{rlen});
        }
        // Buffer input
        if (self.ready(ps.len - 1)) |f| ibufc += os.read(f, ibuf[ibufi..]) catch 0; // TODO XXX wraparound buffering
        // Write buffered input
        if (ibufi < ibufc) ibufi += os.write(ps[sel].fd, ibuf[ibufi..ibufc]) catch 0;
        // Reset input buffer
        if (ibufi == ibufc) {
            ibufi = 0;
            ibufc = 0;
        }

        // Cleanup finished processes
        while (self.popKilled() != null) {}
    }
};
test "Pool waitAndReap" {
    try pool.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    try pool.waitAndReap(&std.io.getStdOut());
    // TODO XXX finish
    //var stdob = std.io.bufferedWriter(std.io.getStdOut().writer());
    //const stdo = stdob.writer();
    //try stdob.flush();
    while (pool.popKilled() != null or pool.pids.len > 0) {}
}
test "Pool fake stdin" {
    var fd: File = undefined;
    _ = try pty_child(&fd.handle, &([_:null]?[*:0]const u8{"cat"}), 0, 0);
    var pool2 = Pool.init(fd.handle);
    try tst.expect(pool2.polls.get(0).fd == fd.handle);
    try fd.writeAll("hi\n");
    pool2.wait();
    try tst.expect(pool2.ready(0).? == pool2.polls.constSlice()[0].fd);
    const exp = "hi\r\n";
    var buf: [exp.len]u8 = undefined;
    var f: File = .{ .handle = pool2.polls.get(0).fd };
    try tst.expectEqual(buf.len, try f.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    fd.close();
}
test "Pool popKilled" {
    try tst.expect(pool.popKilled() == null);
    try pool.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    try pool.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    _ = try os.fcntl(pool.polls.get(0).fd, os.F.SETFL, 0);
    _ = try os.fcntl(pool.polls.get(1).fd, os.F.SETFL, 0);
    try tst.expect(pool.polls.len == 3);
    var buf: [io_buf_sz]u8 = undefined;
    _ = os.read(pool.polls.get(0).fd, &buf) catch 0;
    _ = os.read(pool.polls.get(1).fd, &buf) catch 0;
    os.close(pool.polls.get(0).fd);
    os.close(pool.polls.get(1).fd);
    try tst.expect(pool.popKilled() orelse 0 != 0);
    try tst.expect(pool.popKilled() orelse 0 != 0);
    try tst.expect(pool.popKilled() == null);
    try pool.append(&([_:null]?[*:0]const u8{ "cat", "/dev/null" }), 0, 0);
    _ = try os.fcntl(pool.polls.get(0).fd, os.F.SETFL, 0);
    _ = os.read(pool.polls.get(0).fd, &buf) catch 0;
    os.close(pool.polls.get(0).fd);
    try tst.expectEqual(pool.pids.get(0), pool.popKilled().?);
    try tst.expect(pool.polls.len == 1);
    while (pool.popKilled() != null or pool.pids.len > 0) {}
}
test "Pool popKilled no hang" {
    const start = std.time.milliTimestamp();
    try pool.append(&([_:null]?[*:0]const u8{ "sleep", "2" }), 0, 0);
    try tst.expect(pool.popKilled() == null);
    try tst.expect(std.time.milliTimestamp() < start + 100);
    try pool.append(&([_:null]?[*:0]const u8{ "sleep", "0.001" }), 0, 0); // TODO XXX remove this line
    os.close(pool.polls.get(0).fd);
    while (pool.popKilled() != null or pool.pids.len > 0) {}
    try tst.expect(std.time.milliTimestamp() < start + 100);
}
test "Pool wait interrupted by sigchild" {
    const start = std.time.milliTimestamp();
    try pool.append(&([_:null]?[*:0]const u8{ "sleep", "2" }), 0, 0);
    try pool.append(&([_:null]?[*:0]const u8{ "sleep", "0.001" }), 0, 0);
    pool.wait();
    try tst.expect(std.time.milliTimestamp() < start + 100);
    os.close(pool.polls.get(0).fd);
    os.close(pool.polls.get(1).fd);
    while (pool.popKilled() != null or pool.pids.len > 0) {}
}
test "Pool wait interrupted by sigint" {
    const start = std.time.milliTimestamp();
    try pool.append(&([_:null]?[*:0]const u8{
        "sh", "-c",
        \\sleep 0.001; kill -s=INT `ps -o ppid= -p $$` > /dev/null; sleep 2
    }), 0, 0);
    pool.wait();
    try tst.expect(std.time.milliTimestamp() < start + 100);
    os.close(pool.polls.get(0).fd);
    while (pool.popKilled() != null or pool.pids.len > 0) {}
}
test "Pool append and read" {
    try pool.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    try pool.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    _ = try os.fcntl(pool.polls.get(0).fd, os.F.SETFL, 0);
    _ = try os.fcntl(pool.polls.get(1).fd, os.F.SETFL, 0);
    const exp = "ping\r\npong\r\n";
    var buf: [exp.len]u8 = undefined;
    for (1..9) |i| {
        var f: File = .{ .handle = pool.polls.get(i % 2).fd };
        try f.writeAll("ping\n");
        try tst.expectEqual(buf.len, try f.readAll(&buf));
        try tst.expectEqualStrings(exp, &buf);
    }
    os.close(pool.polls.get(0).fd);
    os.close(pool.polls.get(1).fd);
    while (pool.popKilled() != null or pool.pids.len > 0) {}
}
test "Pool wait and ready" {
    try pool.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    try pool.append(&([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    const exp = "ping\r\npong\r\n";
    var buf: [exp.len]u8 = undefined;
    // Communicate with second process
    var f: File = .{ .handle = pool.polls.get(1).fd };
    try f.writeAll("ping\n");
    pool.wait();
    try tst.expect(pool.ready(0) == null);
    try tst.expect(pool.ready(1).? == pool.polls.get(1).fd);
    _ = try os.fcntl(pool.polls.get(1).fd, os.F.SETFL, 0);
    try tst.expectEqual(buf.len, try f.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    // Communicate with first process
    f = .{ .handle = pool.polls.get(0).fd };
    try f.writeAll("ping\n");
    pool.wait();
    try tst.expect(pool.ready(0).? == pool.polls.get(0).fd);
    try tst.expect(pool.ready(1) == null);
    _ = try os.fcntl(pool.polls.get(0).fd, os.F.SETFL, 0);
    try tst.expectEqual(buf.len, try f.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    os.close(pool.polls.get(0).fd);
    os.close(pool.polls.get(1).fd);
    while (pool.popKilled() != null or pool.pids.len > 0) {}
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
fn pty_child(fd: *os.fd_t, args: [*:null]const ?[*:0]const u8, cols: u16, rows: u16) !os.pid_t {
    const ws = WinSize{ .ws_col = cols, .ws_row = rows, .ws_xpixel = 0, .ws_ypixel = 0 };
    // Terminal settings
    var tm = try os.tcgetattr(in.handle);
    tm.oflag = ctermios.OPOST | ctermios.ONLCR;
    tm.iflag = ctermios.BRKINT | ctermios.IXON | ctermios.IXANY;
    tm.cflag = ctermios.CS8 | ctermios.CREAD | ctermios.HUPCL;
    tm.lflag = ctermios.ISIG | ctermios.ECHO;
    // Fork off child pty process
    const pid: os.pid_t = forkpty(fd, null, &tm, &ws);
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
    var fd: File = .{ .handle = 0 };
    _ = try pty_child(&fd.handle, &([_:null]?[*:0]const u8{ "sed", "-e", "s/ping/pong/" }), 0, 0);
    const exp = "ping\r\npong\r\n";
    var buf: [exp.len]u8 = undefined;
    for (1..9) |_| {
        try fd.writeAll("ping\n");
        try tst.expectEqual(buf.len, try fd.readAll(&buf));
        try tst.expectEqualStrings(exp, &buf);
    }
    fd.close();
}
test "pty_child hello world" {
    var fd: File = .{ .handle = 0 };
    _ = try pty_child(&fd.handle, &([_:null]?[*:0]const u8{ "echo", "hello" }), 0, 0);
    try fd.writeAll("hi\n");
    const exp = "hi\r\nhello\r\n";
    var buf: [exp.len]u8 = undefined;
    try tst.expectEqual(buf.len, try fd.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    fd.close();
}
test "pty_child win size set" {
    var fd: File = .{ .handle = 0 };
    _ = try pty_child(&fd.handle, &([_:null]?[*:0]const u8{ "tput", "cols", "lines" }), 11, 22);
    const exp = "11\r\n22\r\n";
    var buf: [exp.len]u8 = undefined;
    try tst.expectEqual(buf.len, try fd.readAll(&buf));
    try tst.expectEqualStrings(exp, &buf);
    fd.close();
}
test "pty_child start stop" {
    var fd: File = .{ .handle = 0 };
    const start = std.time.milliTimestamp();

    const pid = try pty_child(&fd.handle, &([_:null]?[*:0]const u8{"cat"}), 0, 0);
    // Ensure process is active
    try fd.writeAll("x");
    var bufc = [_]u8{ 0, 0 };
    _ = try fd.readAll(&bufc);
    // Check termination
    fd.close();
    while (pid != waitpid(-1, null, std.c.W.NOHANG)) {}
    try tst.expect(std.time.milliTimestamp() < start + 100);
}
// TODO XXX Handle Ctrl+c

/// Setup signal handlers for proxying SIGINT and responding to SIGCHLD.
/// After registering, SIGINTS will interupt.
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
// TODO XXX send Ctrl c to active subprocess on sigint.

pub fn main() !void {
    // TODO XXX whoops, go back to signal handlers since this can't be allowed to change the stdin as it may be used after the program ends.
    // MAYBE ?????? XXX XXX XXX
    // Set up stdin for proxying // TODO XXX test this be pushing to a separate function.
    var tm = try os.tcgetattr(in.handle);
    // Ensure we don't capture things like ^C -> SIGINT
    //tm.cflag = 0;
    //tm.oflag = 0; XXX TODO
    tm.iflag = 0;
    tm.lflag = 0;
    try os.tcsetattr(in.handle, std.c.TCSA.NOW, tm);

    //var gmem = std.heap.GeneralPurposeAllocator(.{}){};
    //const gpa = gmem.allocator();

    const out = std.io.getStdOut();

    // XXX TODO handle tab chars send recieve behavior
    try pool.append(&([_:null]?[*:0]const u8{"sh"}), 80, 40);
    while (pool.pids.len > 0) {
        std.debug.print("|\n___________________________________________________________________\n", .{});
        try pool.waitAndReap(&out);
    }
}

// TODO: Multiple input connections and detaching -> IO through named pipes connected to std IO for other processes to access and let the kernel handle the rest.
