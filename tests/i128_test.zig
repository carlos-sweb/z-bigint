const std = @import("std");
const testing = std.testing;
const ZBigInt = @import("zbigint").ZBigInt;

test "i128 conversions preserve every bit across the signed range" {
    const cases = [_]i128{
        0,                        1,                             -1,
        9_007_199_254_740_991,    9_007_199_254_740_993,         957_270_896_987_654_321,
        -957_270_896_987_654_321, 8_640_000_000_000_000_000_000, -8_640_000_000_000_000_000_000,
        std.math.maxInt(i128),    std.math.minInt(i128),
    };
    for (cases) |n| {
        var value = try ZBigInt.fromI128(testing.allocator, n);
        defer value.deinit();
        try testing.expectEqual(n, try value.toI128());
    }
}

test "i128 extraction rejects both out-of-range signs" {
    for ([_][]const u8{
        "170141183460469231731687303715884105728",
        "-170141183460469231731687303715884105729",
    }) |text| {
        var value = try ZBigInt.fromDigitText(testing.allocator, text);
        defer value.deinit();
        try testing.expectError(error.ResultTooLarge, value.toI128());
    }
}
