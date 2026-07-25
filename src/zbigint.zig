//! A thin, general-purpose wrapper over Zig 0.16's own arbitrary-precision
//! integer (`std.math.big.int.Managed`), giving it the specific operation
//! set and semantics JS's `BigInt` needs -- but nothing JS-specific lives
//! here (no `JSValue`, no engine coupling): this is a plain sibling
//! library, reusable anywhere an arbitrary-precision integer is useful.
//!
//! Scope: construction from digit text (decimal, or `0x`/`0o`/`0b`-prefixed,
//! `_` separators allowed) or a native integer; stringify at any radix
//! 2-36; add/sub/mul/truncating-div-and-rem/pow(non-negative exponent)/
//! negate; bitwise and/or/xor/not/shl/shr (arithmetic, sign-preserving --
//! no unsigned right shift, matching the fact that JS BigInt has none
//! either); value-based compare/eql/hash (NOT identity -- two
//! independently-parsed equal BigInts must compare and hash equal).
//!
//! Deliberately NOT included (out of scope for v1): `asIntN`/`asUintN`
//! fixed-width wrapping helpers, `sqrt`/`gcd` (std exposes them on
//! `Managed` directly if a caller needs them -- no need to re-wrap).

const std = @import("std");
const Allocator = std.mem.Allocator;
const big = std.math.big.int;

pub const BigIntError = error{
    /// The digit text (after stripping a `0x`/`0o`/`0b` prefix, if any)
    /// contains a character invalid for its radix, or is empty.
    InvalidDigits,
    DivisionByZero,
    /// `BigInt.prototype ** exponent` with exponent < 0 is a real JS
    /// RangeError -- there is no fractional BigInt to represent it.
    NegativeExponent,
    OutOfMemory,
};

pub const ZBigInt = struct {
    value: big.Managed,

    pub fn deinit(self: *ZBigInt) void {
        self.value.deinit();
    }

    /// Parses the EXACT raw text a lexer captures for a JS BigInt literal
    /// (`123n`, `0x1Fn`, `1_000n`) with the trailing `n` already stripped
    /// by the caller: an optional `0x`/`0o`/`0b` radix prefix, decimal
    /// digits otherwise, and `_` digit separators anywhere in the digit
    /// run (`std.math.big.int.Mutable.setString` already skips `_`
    /// internally -- confirmed by reading its source -- so only the radix
    /// prefix needs stripping here). A leading `-` is also accepted
    /// (`setString`'s own contract), for general-purpose callers that
    /// aren't JS literals (JS BigInt literals themselves never carry a
    /// sign; unary minus is applied separately at the JS layer).
    pub fn fromDigitText(allocator: Allocator, raw: []const u8) BigIntError!ZBigInt {
        var negative = false;
        var rest = raw;
        if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
            negative = rest[0] == '-';
            rest = rest[1..];
        }
        var radix: u8 = 10;
        var digits = rest;
        if (rest.len > 2 and rest[0] == '0') {
            switch (rest[1]) {
                'x', 'X' => {
                    radix = 16;
                    digits = rest[2..];
                },
                'o', 'O' => {
                    radix = 8;
                    digits = rest[2..];
                },
                'b', 'B' => {
                    radix = 2;
                    digits = rest[2..];
                },
                else => {},
            }
        }
        if (digits.len == 0) return BigIntError.InvalidDigits;
        // The sign was already stripped above, so setString (which also
        // understands a leading '-') never sees one here -- negation is
        // applied explicitly afterward instead, uniformly across every
        // radix (setString takes `base` as an explicit parameter and has
        // no notion of a `0x`/`0o`/`0b` prefix itself).
        var v = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer v.deinit();
        v.setString(radix, digits) catch return BigIntError.InvalidDigits;
        if (negative and !v.eqlZero()) v.negate();
        return .{ .value = v };
    }

    pub fn fromInt(allocator: Allocator, n: i64) BigIntError!ZBigInt {
        return .{ .value = big.Managed.initSet(allocator, n) catch return BigIntError.OutOfMemory };
    }

    pub fn clone(self: ZBigInt) BigIntError!ZBigInt {
        return .{ .value = self.value.clone() catch return BigIntError.OutOfMemory };
    }

    /// `radix` must be 2-36, matching `BigInt.prototype.toString([radix])`.
    pub fn toString(self: ZBigInt, allocator: Allocator, radix: u8) BigIntError![]u8 {
        return self.value.toString(allocator, radix, .lower) catch BigIntError.OutOfMemory;
    }

    pub fn isZero(self: ZBigInt) bool {
        return self.value.eqlZero();
    }

    /// Lossy for magnitudes beyond f64's 53-bit mantissa -- matches real
    /// JS `Number(bigint)`, which is explicitly allowed to lose precision.
    pub fn toFloat(self: ZBigInt) f64 {
        const result = self.value.toFloat(f64, .nearest_even);
        return result[0];
    }

    pub fn isNegative(self: ZBigInt) bool {
        return !self.value.isPositive() and !self.isZero();
    }

    /// Value equality (NOT identity) -- `1n` parsed twice must be `eql`.
    pub fn eql(self: ZBigInt, other: ZBigInt) bool {
        return self.value.eql(other.value);
    }

    pub fn cmp(self: ZBigInt, other: ZBigInt) std.math.Order {
        return self.value.order(other.value);
    }

    /// Value-based hash (NOT pointer/identity-based) -- must agree with
    /// `eql`: two values that compare equal must hash equal. `0n` and
    /// `-0n` (if ever constructed) both normalize to sign=positive at the
    /// std.math.big.int layer when magnitude is zero (confirmed via
    /// `eqlZero`'s own use elsewhere in this file), so hashing a
    /// zero-magnitude value's sign bit would be inconsistent with `eql`
    /// only if that normalization were false -- guarded here explicitly
    /// rather than assumed.
    pub fn hash(self: ZBigInt) u64 {
        if (self.isZero()) return 0;
        var h = std.hash.Wyhash.init(if (self.value.isPositive()) 1 else 0);
        h.update(std.mem.sliceAsBytes(self.value.toConst().limbs));
        return h.final();
    }

    pub fn negate(self: ZBigInt) BigIntError!ZBigInt {
        var r = try self.clone();
        r.value.negate();
        return r;
    }

    pub fn add(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.add(&a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    pub fn sub(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.sub(&a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    pub fn mul(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.mul(&a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    /// Truncating division (toward zero) -- JS BigInt `/` truncates,
    /// unlike e.g. Python's floor division.
    pub fn divTrunc(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        if (b.isZero()) return BigIntError.DivisionByZero;
        var q = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer q.deinit();
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        defer r.deinit();
        big.Managed.divTrunc(&q, &r, &a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = q };
    }

    /// Truncating remainder -- matches JS BigInt `%` (sign follows the
    /// dividend, same family as `divTrunc`).
    pub fn remTrunc(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        if (b.isZero()) return BigIntError.DivisionByZero;
        var q = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        defer q.deinit();
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        big.Managed.divTrunc(&q, &r, &a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    /// `exponent` must be non-negative (real JS RangeError otherwise) and
    /// small enough to fit `u32` (matching `std.math.big.int`'s own
    /// `pow` signature) -- a fractional/negative-exponent BigInt has no
    /// representation, and an exponent needing more than 4 billion
    /// multiplications isn't a realistic input either way.
    pub fn pow(allocator: Allocator, a: ZBigInt, exponent: ZBigInt) BigIntError!ZBigInt {
        if (exponent.isNegative()) return BigIntError.NegativeExponent;
        const exp_u32 = exponent.value.toInt(u32) catch return BigIntError.NegativeExponent;
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        big.Managed.pow(&r, &a.value, exp_u32) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    pub fn bitAnd(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.bitAnd(&a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    /// NOT implemented via `std.math.big.int.Managed.bitOr` directly --
    /// confirmed (via a fuzz probe cross-checked against real Node
    /// BigInt) that std's own `bitOr` under-reserves capacity when the
    /// two operands' signs differ (unlike its `bitAnd`/`bitXor` siblings,
    /// which both explicitly add a headroom limb for that case -- this
    /// one doesn't), silently producing a garbage result rather than an
    /// error. Implemented instead via De Morgan's law (`a | b == ~(~a &
    /// ~b)`), routing through `bitAnd` (verified correct for mixed
    /// signs) and `not` (this module's own, correct by construction)
    /// instead of the buggy path.
    pub fn bitOr(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var not_a = try ZBigInt.not(allocator, a);
        defer not_a.deinit();
        var not_b = try ZBigInt.not(allocator, b);
        defer not_b.deinit();
        var anded = try ZBigInt.bitAnd(allocator, not_a, not_b);
        defer anded.deinit();
        return ZBigInt.not(allocator, anded);
    }

    pub fn bitXor(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.bitXor(&a.value, &b.value) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    /// Per the JS BigInt spec, `~a` is defined mathematically as
    /// `-(a + 1)`, NOT a fixed-width bit-flip (there's no fixed width to
    /// flip for an arbitrary-precision integer) -- implemented directly
    /// from that identity rather than via `std.math.big.int`'s
    /// `bitNotWrap` (which needs a `bit_count` and wraps, the wrong shape
    /// entirely for this).
    pub fn not(allocator: Allocator, a: ZBigInt) BigIntError!ZBigInt {
        var one = big.Managed.initSet(allocator, @as(i64, 1)) catch return BigIntError.OutOfMemory;
        defer one.deinit();
        var sum = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer sum.deinit();
        sum.add(&a.value, &one) catch return BigIntError.OutOfMemory;
        sum.negate();
        return .{ .value = sum };
    }

    pub fn shiftLeft(allocator: Allocator, a: ZBigInt, shift: usize) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.shiftLeft(&a.value, shift) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }

    /// Arithmetic (sign-preserving) right shift -- matches JS BigInt `>>`.
    /// There is no `>>>` for BigInt (no unsigned representation exists);
    /// callers must reject that operator before reaching here.
    pub fn shiftRight(allocator: Allocator, a: ZBigInt, shift: usize) BigIntError!ZBigInt {
        var r = big.Managed.init(allocator) catch return BigIntError.OutOfMemory;
        errdefer r.deinit();
        r.shiftRight(&a.value, shift) catch return BigIntError.OutOfMemory;
        return .{ .value = r };
    }
};
