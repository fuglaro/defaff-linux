const std = @import("std");
const testing = std.testing;
const alc = std.mem.Allocator;

// Layout information for all the windows
const Stack = ArrayList(Window).init(alc);
const Window = struct {
    x: u16 = 0, // horizontal position (from left)
    y: u16 = 0, // vertial position (from top)
    w: u16 = 256, // width (when drawn to screen)
    h: u16 = 256, // height (when drawn to screen)
    ws: u4 = 0, // workspace number
    
}

// Full data for each window
// Same length as stack, and 
const details

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try testing.expect(add(3, 7) == 10);
}
