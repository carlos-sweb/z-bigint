//! Every case here was cross-checked against real Node BigInt
//! (`node -e "console.log(a op b)"`) before being written down, not
//! derived from reading the spec -- see the session that added this file.
const std = @import("std");
const testing = std.testing;
const zbigint = @import("zbigint");
const ZBigInt = zbigint.ZBigInt;

fn parse(allocator: std.mem.Allocator, raw: []const u8) !ZBigInt {
    return ZBigInt.fromDigitText(allocator, raw);
}

fn expectDecimal(allocator: std.mem.Allocator, v: ZBigInt, expected: []const u8) !void {
    const s = try v.toString(allocator, 10);
    defer allocator.free(s);
    try testing.expectEqualStrings(expected, s);
}

test "add: positive, negative, and mixed-sign operands" {
    const a = testing.allocator;
    var x = try parse(a, "123456789012345678901234567890");
    defer x.deinit();
    var y = try parse(a, "1");
    defer y.deinit();
    var r = try ZBigInt.add(a, x, y);
    defer r.deinit();
    try expectDecimal(a, r, "123456789012345678901234567891");

    var neg = try parse(a, "-5");
    defer neg.deinit();
    var five = try parse(a, "5");
    defer five.deinit();
    var zero = try ZBigInt.add(a, neg, five);
    defer zero.deinit();
    try testing.expect(zero.isZero());
}

test "sub" {
    const a = testing.allocator;
    var x = try parse(a, "1000000000000000000000");
    defer x.deinit();
    var y = try parse(a, "1");
    defer y.deinit();
    var r = try ZBigInt.sub(a, x, y);
    defer r.deinit();
    try expectDecimal(a, r, "999999999999999999999");
}

test "mul: a value that overflows i64/f64 exactly" {
    const a = testing.allocator;
    var x = try parse(a, "123456789012345678901234567890");
    defer x.deinit();
    var y = try parse(a, "2");
    defer y.deinit();
    var r = try ZBigInt.mul(a, x, y);
    defer r.deinit();
    try expectDecimal(a, r, "246913578024691357802469135780");
}

test "divTrunc and remTrunc match Node's truncating (not floor) semantics" {
    const a = testing.allocator;
    const cases = [_]struct { x: []const u8, y: []const u8, q: []const u8, r: []const u8 }{
        .{ .x = "7", .y = "2", .q = "3", .r = "1" },
        .{ .x = "-7", .y = "2", .q = "-3", .r = "-1" },
        .{ .x = "7", .y = "-2", .q = "-3", .r = "1" },
        .{ .x = "-7", .y = "-2", .q = "3", .r = "-1" },
    };
    for (cases) |c| {
        var x = try parse(a, c.x);
        defer x.deinit();
        var y = try parse(a, c.y);
        defer y.deinit();
        var q = try ZBigInt.divTrunc(a, x, y);
        defer q.deinit();
        try expectDecimal(a, q, c.q);
        var x2 = try parse(a, c.x);
        defer x2.deinit();
        var y2 = try parse(a, c.y);
        defer y2.deinit();
        var r = try ZBigInt.remTrunc(a, x2, y2);
        defer r.deinit();
        try expectDecimal(a, r, c.r);
    }
}

test "division by zero is a catchable error" {
    const a = testing.allocator;
    var x = try parse(a, "1");
    defer x.deinit();
    var zero = try parse(a, "0");
    defer zero.deinit();
    try testing.expectError(zbigint.BigIntError.DivisionByZero, ZBigInt.divTrunc(a, x, zero));
}

test "pow: non-negative exponent, and RangeError-equivalent for negative" {
    const a = testing.allocator;
    var base = try parse(a, "2");
    defer base.deinit();
    var exp = try parse(a, "100");
    defer exp.deinit();
    var r = try ZBigInt.pow(a, base, exp);
    defer r.deinit();
    try expectDecimal(a, r, "1267650600228229401496703205376");

    var neg_exp = try parse(a, "-1");
    defer neg_exp.deinit();
    try testing.expectError(zbigint.BigIntError.NegativeExponent, ZBigInt.pow(a, base, neg_exp));
}

test "negate and isNegative/isZero" {
    const a = testing.allocator;
    var five = try parse(a, "5");
    defer five.deinit();
    var neg_five = try five.negate();
    defer neg_five.deinit();
    try testing.expect(neg_five.isNegative());
    try expectDecimal(a, neg_five, "-5");

    var zero = try parse(a, "0");
    defer zero.deinit();
    try testing.expect(zero.isZero());
    try testing.expect(!zero.isNegative());
}
