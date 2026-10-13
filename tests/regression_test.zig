const std = @import("std");
const z = @import("zbigint");
const Z = z.ZBigInt;
const t = std.testing;
const alloc = t.allocator;

fn decimal(v: Z, expected: []const u8) !void {
    const s = try v.toString(alloc, 10);
    defer alloc.free(s);
    try t.expectEqualStrings(expected, s);
}

fn canonical(v: Z) !void {
    try t.expect(v.isZero());
    try t.expect(v.value.isPositive());
    try t.expectEqual(@as(u64, 0), @as(u64, @bitCast(v.toFloat())));
}

test "zero stays positive through unary, division, remainder and bitwise results" {
    var zero = try Z.fromInt(alloc, 0);
    defer zero.deinit();
    var one = try Z.fromInt(alloc, 1);
    defer one.deinit();
    var neg = try Z.fromInt(alloc, -1);
    defer neg.deinit();
    var a = try zero.negate();
    defer a.deinit();
    try canonical(a);
    var b = try Z.not(alloc, neg);
    defer b.deinit();
    try canonical(b);
    var c = try Z.divTrunc(alloc, one, neg);
    defer c.deinit();
    var d = try Z.remTrunc(alloc, neg, one);
    defer d.deinit();
    try canonical(d);
    var e = try Z.bitXor(alloc, neg, neg);
    defer e.deinit();
    try canonical(e);
    var f = try Z.bitAnd(alloc, one, zero);
    defer f.deinit();
    try canonical(f);
    var g = try Z.bitOr(alloc, zero, zero);
    defer g.deinit();
    try canonical(g);
    // Defensive handling even for a zero manually signed through public Managed.
    zero.value.setSign(false);
    var shifted = try Z.shiftRight(alloc, zero, std.math.maxInt(usize));
    defer shifted.deinit();
    try canonical(shifted);
    var left = try Z.shiftLeft(alloc, zero, std.math.maxInt(usize));
    defer left.deinit();
    try canonical(left);
    var n = try zero.negate();
    defer n.deinit();
    try canonical(n);
}

test "all radices round-trip around limb boundaries, including negative values" {
    for ([_]usize{ 31, 32, 33, 63, 64, 65, 127, 128, 129, 255, 256, 257 }) |bits| {
        var one = try Z.fromInt(alloc, 1);
        defer one.deinit();
        var power = try Z.shiftLeft(alloc, one, bits);
        defer power.deinit();
        var below = try Z.sub(alloc, power, one);
        defer below.deinit();
        var above = try Z.add(alloc, power, one);
        defer above.deinit();
        for ([_]Z{ power, below, above }) |v| {
            var negative = try v.negate();
            defer negative.deinit();
            for ([_]Z{ v, negative }) |number| {
                for (2..37) |base| {
                    const radix: u8 = @intCast(base);
                    const s = try number.toString(alloc, radix);
                    defer alloc.free(s);
                    var reference = try std.math.big.int.Managed.init(alloc);
                    defer reference.deinit();
                    try reference.setString(radix, s);
                    try t.expect(number.value.eql(reference));
                }
            }
        }
    }
    var v = try Z.fromDigitText(alloc, "18446744073709551616");
    defer v.deinit();
    const oct = try v.toString(alloc, 8);
    defer alloc.free(oct);
    try t.expectEqualStrings("2000000000000000000000", oct);
    const base32 = try v.toString(alloc, 32);
    defer alloc.free(base32);
    try t.expectEqualStrings("g000000000000", base32);
    try t.expectError(error.InvalidRadix, v.toString(alloc, 1));
    try t.expectError(error.InvalidRadix, v.toString(alloc, 37));
}

test "float maximum, fractions, nonfinite and NumberToBigInt" {
    var max = try Z.fromFloat(alloc, std.math.floatMax(f64));
    defer max.deinit();
    try t.expectEqual(@as(usize, 1024), max.value.bitCountAbs());
    try t.expectEqual(std.math.floatMax(f64), max.toFloat());
    var fraction = try Z.fromFloat(alloc, -5.9);
    defer fraction.deinit();
    try decimal(fraction, "-5");
    var nz = try Z.fromNumber(alloc, -0.0);
    defer nz.deinit();
    try canonical(nz);
    var tiny = try Z.fromFloat(alloc, std.math.floatTrueMin(f64));
    defer tiny.deinit();
    try canonical(tiny);
    try t.expectError(error.InvalidFloat, Z.fromFloat(alloc, std.math.inf(f64)));
    try t.expectError(error.InvalidFloat, Z.fromNumber(alloc, std.math.nan(f64)));
    try t.expectError(error.NonIntegralFloat, Z.fromNumber(alloc, 5.9));
}

test "generic parsing rejects residual signs and separator-only runs" {
    for ([_][]const u8{ "--1", "+-1", "0x-1", "_", "0x_", "+", "0b2" }) |raw|
        try t.expectError(error.InvalidDigits, Z.fromDigitText(alloc, raw));
    var v = try Z.fromDigitText(alloc, "-0x2_a");
    defer v.deinit();
    try decimal(v, "-42");
}

test "literal and StringToBigInt adapters have independent grammar" {
    for ([_][]const u8{ "", " \t\n", "\xc2\xa0\xef\xbb\xbf" }) |raw| {
        var v = try Z.fromEcmaString(alloc, raw);
        defer v.deinit();
        try canonical(v);
    }
    var v = try Z.fromEcmaString(alloc, "\xe3\x80\x80+0042\xe2\x80\xa8");
    defer v.deinit();
    try decimal(v, "42");
    for ([_][]const u8{ "1_000", "-0x1", "+0b1", "--1", "0x-1", "\xc2\x8542", "4 2", "\xff" }) |raw|
        try t.expectError(error.InvalidDigits, Z.fromEcmaString(alloc, raw));
    for ([_][]const u8{ "00n", "01n", "0_0n", "1__2n", "1_n", "0x_1n", "-1n", "1", "0xn" }) |raw|
        try t.expectError(error.InvalidDigits, Z.fromLiteralText(alloc, raw));
    for ([_][]const u8{ "42n", "4_2n", "0x2an", "0b101010n", "0o52n" }) |raw| {
        var number = try Z.fromLiteralText(alloc, raw);
        defer number.deinit();
        try decimal(number, "42");
    }
}

test "huge trivial powers, zero power, and checked capacity errors" {
    var huge = try Z.fromDigitText(alloc, "18446744073709551617");
    defer huge.deinit();
    var zero = try Z.fromInt(alloc, 0);
    defer zero.deinit();
    var one = try Z.fromInt(alloc, 1);
    defer one.deinit();
    var neg = try Z.fromInt(alloc, -1);
    defer neg.deinit();
    var two = try Z.fromInt(alloc, 2);
    defer two.deinit();
    var p = try Z.pow(alloc, neg, huge);
    defer p.deinit();
    try decimal(p, "-1");
    var q = try Z.pow(alloc, one, huge);
    defer q.deinit();
    try decimal(q, "1");
    var r = try Z.pow(alloc, zero, huge);
    defer r.deinit();
    try canonical(r);
    var s = try Z.pow(alloc, zero, zero);
    defer s.deinit();
    try decimal(s, "1");
    try t.expectError(error.ExponentTooLarge, Z.pow(alloc, two, huge));
    try t.expectError(error.NegativeExponent, Z.pow(alloc, one, neg));
    try t.expectError(error.ResultTooLarge, Z.shiftLeft(alloc, one, std.math.maxInt(usize)));
    if (@bitSizeOf(usize) == 32) {
        var exp = try Z.fromDigitText(alloc, "4294967295");
        defer exp.deinit();
        try t.expectError(error.ResultTooLarge, Z.pow(alloc, two, exp));
    }
}

test "negative and huge BigInt shift counts" {
    var eight = try Z.fromInt(alloc, 8);
    defer eight.deinit();
    var neg = try Z.fromInt(alloc, -1);
    defer neg.deinit();
    var huge = try Z.fromDigitText(alloc, "184467440737095516160000");
    defer huge.deinit();
    var nhuge = try huge.negate();
    defer nhuge.deinit();
    var left = try Z.shiftLeftBigInt(alloc, eight, neg);
    defer left.deinit();
    try decimal(left, "4");
    var right = try Z.shiftRightBigInt(alloc, eight, neg);
    defer right.deinit();
    try decimal(right, "16");
    var saturated = try Z.shiftRightBigInt(alloc, neg, huge);
    defer saturated.deinit();
    try decimal(saturated, "-1");
    var reversed = try Z.shiftLeftBigInt(alloc, eight, nhuge);
    defer reversed.deinit();
    try canonical(reversed);
    try t.expectError(error.ResultTooLarge, Z.shiftLeftBigInt(alloc, eight, huge));
}

test "destination reuse, in-place growth and scratch reuse" {
    var workspace = z.Workspace.init(alloc);
    defer workspace.deinit();
    var a = try Z.fromInt(alloc, 3);
    defer a.deinit();
    var b = try Z.fromInt(alloc, -5);
    defer b.deinit();
    var result = try Z.fromInt(alloc, 0);
    defer result.deinit();
    try result.addInto(&a, &b);
    try decimal(result, "-2");
    try result.subInto(&result, &b);
    try decimal(result, "3");
    try result.mulInto(&result, &result, &workspace);
    try decimal(result, "9");
    try result.notInto(&result);
    try decimal(result, "-10");
    try result.bitOrInto(&result, &a, &workspace);
    try decimal(result, "-9");
    try result.bitAndInto(&result, &a);
    try decimal(result, "3");
    try result.bitXorInto(&result, &b);
    try decimal(result, "-8");
    try result.shiftLeftInto(&result, 1024);
    try result.shiftRightInto(&result, 1024);
    try decimal(result, "-8");
    result.negateInPlace();
    try decimal(result, "8");
    var exp = try Z.fromInt(alloc, 3);
    defer exp.deinit();
    try result.powInto(&a, &exp, &workspace);
    try decimal(result, "27");
    var rem = try Z.fromInt(alloc, 0);
    defer rem.deinit();
    try Z.divRemTruncInto(&result, &rem, &b, &a, &workspace);
    try decimal(result, "-1");
    try decimal(rem, "-2");
    try t.expectError(error.InvalidAlias, Z.divRemTruncInto(&a, &rem, &a, &b, &workspace));
    try t.expectError(error.InvalidAlias, a.powInto(&a, &exp, &workspace));
    // Multiplication must copy aliased inputs after the destination grows.
    try a.shiftLeftInto(&a, 512);
    var expected = try Z.mul(alloc, a, a);
    defer expected.deinit();
    try a.mulInto(&a, &a, &workspace);
    try t.expect(a.eql(expected));
    var copy = try a.cloneWithAllocator(alloc);
    defer copy.deinit();
    try t.expect(a.eql(copy));
    var output: [2048]u8 = undefined;
    const text = try a.toStringInto(&output, 10, &workspace);
    const owned = try a.toString(alloc, 10);
    defer alloc.free(owned);
    try t.expectEqualStrings(owned, text);
    try t.expectError(error.BufferTooSmall, a.toStringInto(output[0..1], 10, &workspace));
}

test "combined division obeys a == q*b+r and remainder sign for all small inputs" {
    var ai: i64 = -20;
    while (ai <= 20) : (ai += 1) {
        var bi: i64 = -7;
        while (bi <= 7) : (bi += 1) {
            if (bi == 0) continue;
            var a = try Z.fromInt(alloc, ai);
            defer a.deinit();
            var b = try Z.fromInt(alloc, bi);
            defer b.deinit();
            var result = try Z.divRemTrunc(alloc, a, b);
            defer result.deinit();
            try t.expectEqual(@divTrunc(ai, bi), try result.quotient.value.toInt(i64));
            try t.expectEqual(@rem(ai, bi), try result.remainder.value.toInt(i64));
            if (result.quotient.isZero()) try canonical(result.quotient);
            if (result.remainder.isZero()) try canonical(result.remainder);
        }
    }
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var a = try Z.fromDigitText(allocator, "-703966251306250785764847364386");
    defer a.deinit();
    var b = try Z.fromDigitText(allocator, "667837491686765");
    defer b.deinit();
    var c = try Z.bitOr(allocator, a, b);
    defer c.deinit();
    var result = try Z.divRemTrunc(allocator, a, b);
    defer result.deinit();
    var exp = try Z.fromInt(allocator, 4);
    defer exp.deinit();
    var p = try Z.pow(allocator, b, exp);
    defer p.deinit();
    const s = try p.toString(allocator, 10);
    defer allocator.free(s);
    var f = try Z.fromFloat(allocator, std.math.floatMax(f64));
    defer f.deinit();
    var workspace = z.Workspace.init(allocator);
    defer workspace.deinit();
    var dest = try Z.fromInt(allocator, 0);
    defer dest.deinit();
    try dest.bitOrInto(&a, &b, &workspace);
    try dest.mulInto(&dest, &b, &workspace);
    try dest.powInto(&b, &exp, &workspace);
    try Z.divRemTruncInto(&dest, &f, &a, &b, &workspace);
}

test "allocation failures propagate OutOfMemory without leaks" {
    try t.checkAllAllocationFailures(alloc, allocationScenario, .{});
    // Force growth after the first successful allocation to distinguish OOM
    // from digit validation. FailingAllocator blocks resize as well.
    var failing = t.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    const digits: [1000]u8 = @splat('1');
    try t.expectError(error.OutOfMemory, Z.fromDigitText(failing.allocator(), &digits));
}
