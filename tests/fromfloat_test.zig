const std = @import("std");
const testing = std.testing;
const zbigint = @import("zbigint");
const ZBigInt = zbigint.ZBigInt;

test "fromFloat converts integer-valued floats exactly, including beyond f64's 53-bit mantissa" {
    const allocator = testing.allocator;
    const cases = [_]struct { f: f64, s: []const u8 }{
        .{ .f = 5.0, .s = "5" },
        .{ .f = -5.0, .s = "-5" },
        .{ .f = 0.0, .s = "0" },
        .{ .f = 1e21, .s = "1000000000000000000000" },
        .{ .f = 9007199254740992.0, .s = "9007199254740992" },
    };
    for (cases) |c| {
        var v = try ZBigInt.fromFloat(allocator, c.f);
        defer v.deinit();
        const s = try v.toString(allocator, 10);
        defer allocator.free(s);
        try testing.expectEqualStrings(c.s, s);
    }
}

test "fromFloat truncates a fractional value toward zero" {
    const allocator = testing.allocator;
    var v = try ZBigInt.fromFloat(allocator, 5.9);
    defer v.deinit();
    const s = try v.toString(allocator, 10);
    defer allocator.free(s);
    try testing.expectEqualStrings("5", s);
}
