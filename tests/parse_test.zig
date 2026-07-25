const std = @import("std");
const testing = std.testing;
const zbigint = @import("zbigint");
const ZBigInt = zbigint.ZBigInt;

test "decimal parsing round-trips through toString" {
    const allocator = testing.allocator;
    var v = try ZBigInt.fromDigitText(allocator, "123456789012345678901234567890");
    defer v.deinit();
    const s = try v.toString(allocator, 10);
    defer allocator.free(s);
    try testing.expectEqualStrings("123456789012345678901234567890", s);
}

test "hex/octal/binary prefixes parse to the same decimal value" {
    const allocator = testing.allocator;
    var hex = try ZBigInt.fromDigitText(allocator, "0xFF");
    defer hex.deinit();
    var oct = try ZBigInt.fromDigitText(allocator, "0o377");
    defer oct.deinit();
    var bin = try ZBigInt.fromDigitText(allocator, "0b11111111");
    defer bin.deinit();
    for ([_]ZBigInt{ hex, oct, bin }) |v| {
        const s = try v.toString(allocator, 10);
        defer allocator.free(s);
        try testing.expectEqualStrings("255", s);
    }
}

test "underscore digit separators are stripped" {
    const allocator = testing.allocator;
    var v = try ZBigInt.fromDigitText(allocator, "1_000_000");
    defer v.deinit();
    const s = try v.toString(allocator, 10);
    defer allocator.free(s);
    try testing.expectEqualStrings("1000000", s);
}

test "a leading sign is honored across every radix" {
    const allocator = testing.allocator;
    var neg_dec = try ZBigInt.fromDigitText(allocator, "-42");
    defer neg_dec.deinit();
    var neg_hex = try ZBigInt.fromDigitText(allocator, "-0x2A");
    defer neg_hex.deinit();
    for ([_]ZBigInt{ neg_dec, neg_hex }) |v| {
        try testing.expect(v.isNegative());
        const s = try v.toString(allocator, 10);
        defer allocator.free(s);
        try testing.expectEqualStrings("-42", s);
    }
}

test "toString at an arbitrary radix" {
    const allocator = testing.allocator;
    var v = try ZBigInt.fromDigitText(allocator, "255");
    defer v.deinit();
    const hex = try v.toString(allocator, 16);
    defer allocator.free(hex);
    try testing.expectEqualStrings("ff", hex);
    const bin = try v.toString(allocator, 2);
    defer allocator.free(bin);
    try testing.expectEqualStrings("11111111", bin);
}

test "invalid digit text is a catchable error, not a crash" {
    const allocator = testing.allocator;
    try testing.expectError(zbigint.BigIntError.InvalidDigits, ZBigInt.fromDigitText(allocator, "12g4"));
    try testing.expectError(zbigint.BigIntError.InvalidDigits, ZBigInt.fromDigitText(allocator, ""));
    try testing.expectError(zbigint.BigIntError.InvalidDigits, ZBigInt.fromDigitText(allocator, "0x"));
}

test "fromInt matches fromDigitText for the same value" {
    const allocator = testing.allocator;
    var a = try ZBigInt.fromInt(allocator, -12345);
    defer a.deinit();
    var b = try ZBigInt.fromDigitText(allocator, "-12345");
    defer b.deinit();
    try testing.expect(a.eql(b));
}
