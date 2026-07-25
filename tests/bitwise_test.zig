//! Zig's std.math.big.int.Managed already implements true
//! infinite-two's-complement bitwise semantics for negative operands
//! (confirmed by a standalone probe cross-checked against both Python and
//! real Node BigInt, byte for byte, before writing this file) -- no
//! special negative-number handling was needed in zbigint.zig itself.
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

test "bitAnd/bitOr/bitXor on negative operands match infinite two's-complement" {
    const a = testing.allocator;
    var neg5 = try parse(a, "-5");
    defer neg5.deinit();
    var three = try parse(a, "3");
    defer three.deinit();

    var r_and = try ZBigInt.bitAnd(a, neg5, three);
    defer r_and.deinit();
    try expectDecimal(a, r_and, "3");

    var neg5b = try parse(a, "-5");
    defer neg5b.deinit();
    var threeb = try parse(a, "3");
    defer threeb.deinit();
    var r_or = try ZBigInt.bitOr(a, neg5b, threeb);
    defer r_or.deinit();
    try expectDecimal(a, r_or, "-5");

    var neg5c = try parse(a, "-5");
    defer neg5c.deinit();
    var threec = try parse(a, "3");
    defer threec.deinit();
    var r_xor = try ZBigInt.bitXor(a, neg5c, threec);
    defer r_xor.deinit();
    try expectDecimal(a, r_xor, "-8");
}

test "bitOr on mixed-sign, differently-sized operands (regression: std.math.big.int.Managed.bitOr under-reserves capacity here and silently produces garbage -- see zbigint.zig's bitOr doc comment)" {
    const a = testing.allocator;
    var x = try parse(a, "-703966251306250785764847364386");
    defer x.deinit();
    var y = try parse(a, "667837491686765");
    defer y.deinit();
    var r = try ZBigInt.bitOr(a, x, y);
    defer r.deinit();
    try expectDecimal(a, r, "-703966251306250772566407512065");
}

test "not: ~a == -(a+1), matching the JS BigInt spec identity exactly" {
    const a = testing.allocator;
    var five = try parse(a, "5");
    defer five.deinit();
    var r = try ZBigInt.not(a, five);
    defer r.deinit();
    try expectDecimal(a, r, "-6");

    var neg_one = try parse(a, "-1");
    defer neg_one.deinit();
    var r2 = try ZBigInt.not(a, neg_one);
    defer r2.deinit();
    try expectDecimal(a, r2, "0");
}

test "shiftLeft/shiftRight are arithmetic (sign-preserving)" {
    const a = testing.allocator;
    var eight = try parse(a, "8");
    defer eight.deinit();
    var shl = try ZBigInt.shiftLeft(a, eight, 2);
    defer shl.deinit();
    try expectDecimal(a, shl, "32");

    var neg5 = try parse(a, "-5");
    defer neg5.deinit();
    var shr = try ZBigInt.shiftRight(a, neg5, 1);
    defer shr.deinit();
    try expectDecimal(a, shr, "-3");
}
