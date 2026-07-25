const std = @import("std");
const testing = std.testing;
const zbigint = @import("zbigint");
const ZBigInt = zbigint.ZBigInt;

fn parse(allocator: std.mem.Allocator, raw: []const u8) !ZBigInt {
    return ZBigInt.fromDigitText(allocator, raw);
}

test "eql is value equality, not identity: two independently-parsed equal values are eql" {
    const a = testing.allocator;
    var x = try parse(a, "123456789012345678901234567890");
    defer x.deinit();
    var y = try parse(a, "123456789012345678901234567890");
    defer y.deinit();
    try testing.expect(x.eql(y));

    var z = try parse(a, "0xFF");
    defer z.deinit();
    var w = try parse(a, "255");
    defer w.deinit();
    try testing.expect(z.eql(w));
}

test "eql distinguishes sign" {
    const a = testing.allocator;
    var pos = try parse(a, "5");
    defer pos.deinit();
    var neg = try parse(a, "-5");
    defer neg.deinit();
    try testing.expect(!pos.eql(neg));
}

test "hash agrees with eql: equal values hash equal" {
    const a = testing.allocator;
    var x = try parse(a, "999999999999999999999999999999");
    defer x.deinit();
    var y = try parse(a, "999999999999999999999999999999");
    defer y.deinit();
    try testing.expect(x.eql(y));
    try testing.expectEqual(x.hash(), y.hash());
}

test "cmp orders correctly, including across sign" {
    const a = testing.allocator;
    var neg = try parse(a, "-100");
    defer neg.deinit();
    var pos = try parse(a, "1");
    defer pos.deinit();
    try testing.expectEqual(std.math.Order.lt, neg.cmp(pos));
    try testing.expectEqual(std.math.Order.gt, pos.cmp(neg));

    var a1 = try parse(a, "123456789012345678901234567890");
    defer a1.deinit();
    var a2 = try parse(a, "123456789012345678901234567891");
    defer a2.deinit();
    try testing.expectEqual(std.math.Order.lt, a1.cmp(a2));
    try testing.expectEqual(std.math.Order.eq, a1.cmp(a1));
}
