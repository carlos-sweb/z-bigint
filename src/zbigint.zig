//! Arbitrary-precision integer operations backed by Zig's std.math.big.int.
//! Results own their storage: assignment is a shallow copy, not a clone.
//! Keep allocators alive until deinit, and preserve normalized limbs when
//! accessing `value` directly. Wrapper operations canonicalize zero's sign.
const std = @import("std");
const Allocator = std.mem.Allocator;
const big = std.math.big.int;
const Limb = std.math.big.Limb;
const limb_bits = @bitSizeOf(Limb);

/// Input validation, domain/size limits, buffer/alias errors, and allocation
/// failures. A JS engine must map these errors to the appropriate exceptions.
pub const BigIntError = error{
    InvalidDigits,
    InvalidRadix,
    InvalidFloat,
    NonIntegralFloat,
    DivisionByZero,
    NegativeExponent,
    ExponentTooLarge,
    ResultTooLarge,
    BufferTooSmall,
    InvalidAlias,
    OutOfMemory,
};

/// Reusable scratch for division, multiplication aliases, powers, bitwise OR
/// and formatting. Not thread-safe. Do not use its temporary integers as
/// operation inputs or outputs. It owns memory but never owns caller operands.
pub const Workspace = struct {
    /// Allocator used for retained scratch and OR temporaries.
    allocator: Allocator,
    /// Internal scratch; do not alias caller data with this storage.
    limbs: std.ArrayList(Limb) = .empty,
    /// Internal OR temporary, never an operation input or output.
    or_a: ?ZBigInt = null,
    /// Internal OR temporary, never an operation input or output.
    or_b: ?ZBigInt = null,

    /// Create an empty workspace; storage is allocated lazily on demand.
    pub fn init(allocator: Allocator) Workspace {
        return .{ .allocator = allocator };
    }

    /// Release all retained scratch and temporaries; this workspace becomes invalid.
    pub fn deinit(self: *Workspace) void {
        if (self.or_a) |*v| v.deinit();
        if (self.or_b) |*v| v.deinit();
        self.limbs.deinit(self.allocator);
        self.* = undefined;
    }

    fn scratch(self: *Workspace, len: usize) BigIntError![]Limb {
        _ = try checkedMul(len, @sizeOf(Limb));
        try self.limbs.ensureTotalCapacityPrecise(self.allocator, len);
        self.limbs.items.len = len;
        return self.limbs.items;
    }
};

/// Owned quotient and remainder from a single truncating division.
pub const DivRem = struct {
    /// Quotient truncated toward zero.
    quotient: ZBigInt,
    /// Remainder with the dividend's sign; zero is positive.
    remainder: ZBigInt,

    /// Release both owned results; do not also deinitialize their shallow copies.
    pub fn deinit(self: *DivRem) void {
        self.quotient.deinit();
        self.remainder.deinit();
    }
};

fn checkedAdd(a: usize, b: usize) BigIntError!usize {
    return std.math.add(usize, a, b) catch error.ResultTooLarge;
}

fn checkedMul(a: usize, b: usize) BigIntError!usize {
    return std.math.mul(usize, a, b) catch error.ResultTooLarge;
}

fn radixValid(radix: u8) BigIntError!void {
    if (radix < 2 or radix > 36) return error.InvalidRadix;
}

fn whitespace(cp: u21) bool {
    return switch (cp) {
        0x9...0xd, 0x20, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}

fn trimEcma(text: []const u8) BigIntError![]const u8 {
    var first: ?usize = null;
    var end: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return error.InvalidDigits;
        if (text.len - i < len) return error.InvalidDigits;
        const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return error.InvalidDigits;
        if (!whitespace(cp)) {
            if (first == null) first = i;
            end = i + len;
        }
        i += len;
    }
    return text[first orelse text.len .. if (first == null) text.len else end];
}

/// An owned, normalized arbitrary-precision integer. Assignment copies the
/// descriptor, not its ownership; use clone for independent storage.
pub const ZBigInt = struct {
    /// Backing storage. Direct mutations must preserve normalized limbs and
    /// metadata; its allocator must outlive this integer.
    value: big.Managed,

    /// Release owned storage; this integer becomes invalid.
    pub fn deinit(self: *ZBigInt) void {
        self.value.deinit();
        self.* = undefined;
    }

    fn initCapacity(allocator: Allocator, capacity: usize) BigIntError!ZBigInt {
        // Also check byte size before std's allocator arithmetic.
        _ = try checkedMul(@max(big.Managed.default_capacity, capacity), @sizeOf(Limb));
        return .{ .value = try big.Managed.initCapacity(allocator, capacity) };
    }

    fn canonicalize(self: *ZBigInt) void {
        if (self.isZero()) self.value.setSign(true);
    }

    fn isUnit(self: ZBigInt) bool {
        return self.value.len() == 1 and self.value.limbs[0] == 1;
    }

    /// Generic digit parser: optional sign, radix prefix, and underscores
    /// anywhere among the digits. Requires at least one real digit. This is
    /// not StringToBigInt or literal validation; use the explicit adapters.
    pub fn fromDigitText(allocator: Allocator, raw: []const u8) BigIntError!ZBigInt {
        var rest = raw;
        var negative = false;
        if (rest.len > 0 and (rest[0] == '-' or rest[0] == '+')) {
            negative = rest[0] == '-';
            rest = rest[1..];
        }
        var radix: u8 = 10;
        if (rest.len >= 2 and rest[0] == '0') {
            radix = switch (rest[1]) {
                'x', 'X' => 16,
                'o', 'O' => 8,
                'b', 'B' => 2,
                else => 10,
            };
            if (radix != 10) rest = rest[2..];
        }
        var count: usize = 0;
        for (rest) |ch| {
            if (ch == '_') continue;
            if (radix == 10) {
                if (ch < '0' or ch > '9') return error.InvalidDigits;
            } else {
                _ = std.fmt.charToDigit(ch, radix) catch return error.InvalidDigits;
            }
            count += 1;
        }
        if (count == 0) return error.InvalidDigits;
        const digit_bits: usize = std.math.log2_int_ceil(u8, radix);
        const bits = try checkedMul(count, digit_bits);
        const capacity = try checkedAdd(bits / limb_bits, 2);
        var r = try initCapacity(allocator, capacity);
        errdefer r.deinit();
        var m = r.value.toMutable();
        m.setString(radix, rest) catch return error.InvalidDigits;
        r.value.setMetadata(!negative or m.eqlZero(), m.len);
        return r;
    }

    /// ECMAScript StringToBigInt on UTF-8 text. No numeric separators, and
    /// signs are allowed only for decimal input. Empty/whitespace means zero.
    pub fn fromEcmaString(allocator: Allocator, text: []const u8) BigIntError!ZBigInt {
        const raw = try trimEcma(text);
        if (raw.len == 0) return fromInt(allocator, 0);
        for (raw) |ch| if (ch == '_') return error.InvalidDigits;
        if ((raw[0] == '+' or raw[0] == '-') and raw.len >= 3 and raw[1] == '0') {
            switch (raw[2]) {
                'x', 'X', 'o', 'O', 'b', 'B' => return error.InvalidDigits,
                else => {},
            }
        }
        return fromDigitText(allocator, raw);
    }

    /// Complete JS BigInt literal token including its trailing `n`.
    /// Unary signs belong to expressions and are not accepted here.
    pub fn fromLiteralText(allocator: Allocator, token: []const u8) BigIntError!ZBigInt {
        if (token.len < 2 or token[token.len - 1] != 'n') return error.InvalidDigits;
        const raw = token[0 .. token.len - 1];
        if (raw[0] == '+' or raw[0] == '-') return error.InvalidDigits;
        const prefixed = raw.len >= 2 and raw[0] == '0' and switch (raw[1]) {
            'x', 'X', 'o', 'O', 'b', 'B' => true,
            else => false,
        };
        const digits = if (prefixed) raw[2..] else raw;
        if (digits.len == 0 or digits[0] == '_' or digits[digits.len - 1] == '_') return error.InvalidDigits;
        if (!prefixed and raw.len > 1 and raw[0] == '0') return error.InvalidDigits;
        var previous_separator = false;
        for (digits) |ch| {
            if (ch == '_' and previous_separator) return error.InvalidDigits;
            previous_separator = ch == '_';
        }
        return fromDigitText(allocator, raw);
    }

    /// Construct an exact i64 using allocator; returns owned storage or OutOfMemory.
    pub fn fromInt(allocator: Allocator, n: i64) BigIntError!ZBigInt {
        return .{ .value = try big.Managed.initSet(allocator, n) };
    }

    /// Finite float conversion truncating fractions toward zero.
    pub fn fromFloat(allocator: Allocator, number: f64) BigIntError!ZBigInt {
        if (!std.math.isFinite(number)) return error.InvalidFloat;
        var r = try initCapacity(allocator, big.calcLimbLen(number));
        errdefer r.deinit();
        var m = r.value.toMutable();
        _ = m.setFloat(number, .trunc);
        r.value.setMetadata(m.positive, m.len);
        r.canonicalize();
        return r;
    }

    /// ECMAScript NumberToBigInt: accepts only finite integral f64 values.
    pub fn fromNumber(allocator: Allocator, number: f64) BigIntError!ZBigInt {
        if (!std.math.isFinite(number)) return error.InvalidFloat;
        if (@trunc(number) != number) return error.NonIntegralFloat;
        return fromFloat(allocator, number);
    }

    /// Deep-copy this integer with its original allocator; returns OutOfMemory on failure.
    pub fn clone(self: ZBigInt) BigIntError!ZBigInt {
        return self.cloneWithAllocator(self.value.allocator);
    }

    /// Return an independent copy owned by allocator; failure is OutOfMemory.
    pub fn cloneWithAllocator(self: ZBigInt, allocator: Allocator) BigIntError!ZBigInt {
        var r: ZBigInt = .{ .value = try self.value.cloneWithDifferentAllocator(allocator) };
        r.canonicalize();
        return r;
    }

    /// Upper bound for caller-owned output. Includes '-' when necessary.
    pub fn stringSizeUpperBound(self: ZBigInt, radix: u8) BigIntError!usize {
        try radixValid(radix);
        if (self.isZero()) return 1;
        if (std.math.isPowerOfTwo(radix)) {
            const step: usize = std.math.log2_int(u8, radix);
            const digits = (try checkedAdd(self.value.bitCountAbs(), step - 1)) / step;
            return checkedAdd(digits, @intFromBool(self.isNegative()));
        }
        return self.value.toConst().sizeInBaseUpperBound(radix);
    }

    /// Writes into caller-owned output with reusable scratch. Neither output
    /// nor scratch may overlap this value's limbs. The returned slice borrows
    /// `output`; a too-small output is an error, not an assertion.
    pub fn toStringInto(self: ZBigInt, output: []u8, radix: u8, workspace: *Workspace) BigIntError![]u8 {
        const needed = try self.stringSizeUpperBound(radix);
        if (output.len < needed) return error.BufferTooSmall;
        if (self.isZero()) {
            output[0] = '0';
            return output[0..1];
        }
        switch (radix) {
            2 => return self.formatPowerOfTwo(output[0..needed], 1),
            4 => return self.formatPowerOfTwo(output[0..needed], 2),
            8 => return self.formatPowerOfTwo(output[0..needed], 3),
            16 => return self.formatPowerOfTwo(output[0..needed], 4),
            32 => return self.formatPowerOfTwo(output[0..needed], 5),
            else => {},
        }
        const scratch = try workspace.scratch(big.calcToStringLimbsBufferLen(self.value.len(), radix));
        const len = self.value.toConst().toString(output, radix, .lower, scratch);
        return output[0..len];
    }

    fn formatPowerOfTwo(self: ZBigInt, output: []u8, comptime step: usize) []u8 {
        const sign: usize = @intFromBool(self.isNegative());
        const digits = output.len - sign;
        if (sign != 0) output[0] = '-';
        const limbs = self.value.toConst().limbs;
        for (0..digits) |i| {
            const bit = (digits - 1 - i) * step;
            const index = bit / limb_bits;
            const offset = bit % limb_bits;
            var digit = limbs[index] >> @as(std.math.Log2Int(Limb), @intCast(offset));
            if (comptime limb_bits % step != 0) {
                if (offset + step > limb_bits and index + 1 < limbs.len) {
                    digit |= limbs[index + 1] << @as(std.math.Log2Int(Limb), @intCast(limb_bits - offset));
                }
            }
            output[sign + i] = "0123456789abcdefghijklmnopqrstuv"[digit & ((1 << step) - 1)];
        }
        return output;
    }

    /// Return an owned lowercase string at radix 2-36, using allocator.
    /// The caller frees the returned slice. Invalid bases are InvalidRadix;
    /// allocation failures are OutOfMemory.
    pub fn toString(self: ZBigInt, allocator: Allocator, radix: u8) BigIntError![]u8 {
        const output = try allocator.alloc(u8, try self.stringSizeUpperBound(radix));
        errdefer allocator.free(output);
        if (self.isZero()) {
            output[0] = '0';
            return output;
        }
        switch (radix) {
            2 => return self.formatPowerOfTwo(output, 1),
            4 => return self.formatPowerOfTwo(output, 2),
            8 => return self.formatPowerOfTwo(output, 3),
            16 => return self.formatPowerOfTwo(output, 4),
            32 => return self.formatPowerOfTwo(output, 5),
            else => {},
        }
        var workspace = Workspace.init(allocator);
        defer workspace.deinit();
        const scratch = try workspace.scratch(big.calcToStringLimbsBufferLen(self.value.len(), radix));
        const len = self.value.toConst().toString(output, radix, .lower, scratch);
        const result = output[0..len];
        if (result.len == output.len) return output;
        return allocator.realloc(output, result.len);
    }

    /// O(1); requires the normalized representation maintained by this API.
    pub fn isZero(self: ZBigInt) bool {
        return self.value.len() == 1 and self.value.limbs[0] == 0;
    }

    /// Round to nearest f64, ties to even, without heap allocation.
    /// Precision may be lost and large values overflow to infinity. Zero is +0.0.
    pub fn toFloat(self: ZBigInt) f64 {
        if (self.isZero()) return 0.0;
        return self.value.toFloat(f64, .nearest_even)[0];
    }

    /// True for a negative nonzero value; both signs of zero are false.
    pub fn isNegative(self: ZBigInt) bool {
        return !self.value.isPositive() and !self.isZero();
    }

    /// Compare two integers by mathematical value, without allocating.
    pub fn eql(self: ZBigInt, other: ZBigInt) bool {
        return self.value.eql(other.value);
    }

    /// Return exact numeric order against other, without allocating.
    pub fn cmp(self: ZBigInt, other: ZBigInt) std.math.Order {
        return self.value.order(other.value);
    }

    /// Value hash, not a stable serialized identifier. No cache is kept:
    /// `value` is publicly mutable, so a cached hash could become stale.
    pub fn hash(self: ZBigInt) u64 {
        if (self.isZero()) return 0;
        var h = std.hash.Wyhash.init(if (self.value.isPositive()) 1 else 0);
        h.update(std.mem.sliceAsBytes(self.value.toConst().limbs));
        return h.final();
    }

    /// Negate this owned integer without allocating; zero remains positive.
    pub fn negateInPlace(self: *ZBigInt) void {
        if (!self.isZero()) self.value.negate() else self.value.setSign(true);
    }

    /// Return an independently owned negation using this value's allocator.
    pub fn negate(self: ZBigInt) BigIntError!ZBigInt {
        var r = try self.clone();
        r.negateInPlace();
        return r;
    }

    /// Into methods retain destination capacity. Operands can be the SAME
    /// destination object, but must not be distinct shallow copies of it.
    /// On allocation failure the destination remains owned and valid, but
    /// its previous value is not guaranteed to be preserved.
    pub fn addInto(self: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt) BigIntError!void {
        try self.value.add(&a.value, &b.value);
        self.canonicalize();
    }

    /// Write a - b into this destination, reusing capacity; inputs may be this same object.
    pub fn subInto(self: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt) BigIntError!void {
        try self.value.sub(&a.value, &b.value);
        self.canonicalize();
    }

    /// Write a * b, retaining destination capacity and alias-copy scratch in workspace.
    /// The same destination may be an input; distinct shallow aliases are unsupported.
    pub fn mulInto(self: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt, workspace: *Workspace) BigIntError!void {
        const aliases: usize = @intFromBool(self == a) + @as(usize, @intFromBool(self == b));
        try self.value.ensureCapacity(try checkedAdd(try checkedAdd(a.value.len(), b.value.len()), 1));
        var m = self.value.toMutable();
        if (aliases == 0) {
            m.mulNoAlias(a.value.toConst(), b.value.toConst(), self.value.allocator);
        } else {
            const scratch = try workspace.scratch(big.calcMulLimbsBufferLen(a.value.len(), b.value.len(), aliases));
            m.mul(a.value.toConst(), b.value.toConst(), scratch, self.value.allocator);
        }
        self.value.setMetadata(m.positive, m.len);
        self.canonicalize();
    }

    /// Return owned a + b using allocator, preallocating the required output capacity.
    pub fn add(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = try initCapacity(allocator, try checkedAdd(@max(a.value.len(), b.value.len()), 1));
        errdefer r.deinit();
        try r.addInto(&a, &b);
        return r;
    }

    /// Return owned a - b using allocator, canonicalizing a zero result.
    pub fn sub(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = try initCapacity(allocator, try checkedAdd(@max(a.value.len(), b.value.len()), 1));
        errdefer r.deinit();
        try r.subInto(&a, &b);
        return r;
    }

    /// Return owned a * b using allocator and std's multiplication algorithms.
    pub fn mul(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = try initCapacity(allocator, try checkedAdd(try checkedAdd(a.value.len(), b.value.len()), 1));
        errdefer r.deinit();
        var workspace = Workspace.init(allocator);
        defer workspace.deinit();
        try r.mulInto(&a, &b, &workspace);
        return r;
    }

    /// Outputs must be distinct and must not alias either operand. Scratch
    /// is retained across calls, avoiding Managed.divTrunc's temporary alloc.
    pub fn divRemTruncInto(q: *ZBigInt, r: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt, workspace: *Workspace) BigIntError!void {
        if (b.isZero()) return error.DivisionByZero;
        if (q.value.limbs.ptr == r.value.limbs.ptr or q.value.limbs.ptr == a.value.limbs.ptr or
            q.value.limbs.ptr == b.value.limbs.ptr or r.value.limbs.ptr == a.value.limbs.ptr or r.value.limbs.ptr == b.value.limbs.ptr)
            return error.InvalidAlias;
        if (a.isZero() or b.isUnit() or a.value.orderAbs(b.value) == .lt) {
            if (a.isZero()) {
                try q.value.set(0);
                try r.value.set(0);
            } else if (b.isUnit()) {
                try q.value.copy(a.value.toConst());
                if (b.isNegative()) q.negateInPlace();
                try r.value.set(0);
            } else {
                try q.value.set(0);
                try r.value.copy(a.value.toConst());
            }
        } else {
            try q.value.ensureCapacity(a.value.len());
            try r.value.ensureCapacity(b.value.len());
            const scratch = try workspace.scratch(big.calcDivLimbsBufferLen(a.value.len(), b.value.len()));
            var mq = q.value.toMutable();
            var mr = r.value.toMutable();
            mq.divTrunc(&mr, a.value.toConst(), b.value.toConst(), scratch);
            q.value.setMetadata(mq.positive, mq.len);
            r.value.setMetadata(mr.positive, mr.len);
        }
        q.canonicalize();
        r.canonicalize();
    }

    /// Return an owned quotient/remainder pair; divisor zero is DivisionByZero.
    /// Division truncates toward zero; release both values with DivRem.deinit.
    pub fn divRemTrunc(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!DivRem {
        if (b.isZero()) return error.DivisionByZero;
        var q = try initCapacity(allocator, a.value.len());
        errdefer q.deinit();
        var r = try initCapacity(allocator, @min(a.value.len(), b.value.len()));
        errdefer r.deinit();
        var workspace = Workspace.init(allocator);
        defer workspace.deinit();
        try divRemTruncInto(&q, &r, &a, &b, &workspace);
        return .{ .quotient = q, .remainder = r };
    }

    /// Return owned a / b truncated toward zero; b == 0 is DivisionByZero.
    pub fn divTrunc(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        if (b.isZero()) return error.DivisionByZero;
        if (a.isZero() or a.value.orderAbs(b.value) == .lt) return fromInt(allocator, 0);
        if (b.isUnit()) {
            var q = try a.cloneWithAllocator(allocator);
            if (b.isNegative()) q.negateInPlace();
            return q;
        }
        var result = try divRemTrunc(allocator, a, b);
        result.remainder.deinit();
        return result.quotient;
    }

    /// Return owned a % b with a's sign; b == 0 is DivisionByZero.
    pub fn remTrunc(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        if (b.isZero()) return error.DivisionByZero;
        if (a.isZero() or b.isUnit()) return fromInt(allocator, 0);
        if (a.value.orderAbs(b.value) == .lt) return a.cloneWithAllocator(allocator);
        var result = try divRemTrunc(allocator, a, b);
        result.quotient.deinit();
        return result.remainder;
    }

    fn powerCapacity(a: ZBigInt, exp: u32) BigIntError!usize {
        const bits = try checkedMul(a.value.bitCountAbs(), exp);
        return checkedAdd(2, (try checkedAdd(bits, limb_bits - 1)) / limb_bits);
    }

    /// Retains output and exponentiation scratch; output must not alias base
    /// or exponent. Nontrivial exponents beyond u32 are reported separately.
    pub fn powInto(self: *ZBigInt, a: *const ZBigInt, exponent: *const ZBigInt, workspace: *Workspace) BigIntError!void {
        if (exponent.isNegative()) return error.NegativeExponent;
        if (self.value.limbs.ptr == a.value.limbs.ptr or self.value.limbs.ptr == exponent.value.limbs.ptr) return error.InvalidAlias;
        if (exponent.isZero()) {
            try self.value.set(1);
        } else if (a.isZero()) {
            try self.value.set(0);
        } else if (a.isUnit()) {
            const n: i64 = if (a.isNegative() and exponent.value.isOdd()) -1 else 1;
            try self.value.set(n);
        } else if (exponent.isUnit()) {
            try self.value.copy(a.value.toConst());
        } else {
            const exp = exponent.value.toInt(u32) catch return error.ExponentTooLarge;
            const capacity = try powerCapacity(a.*, exp);
            _ = try checkedMul(capacity, @sizeOf(Limb));
            try self.value.ensureCapacity(capacity);
            const scratch = try workspace.scratch(capacity);
            var m = self.value.toMutable();
            m.pow(a.value.toConst(), exp, scratch);
            self.value.setMetadata(m.positive, m.len);
        }
        self.canonicalize();
    }

    /// Return owned a raised to exponent. Negative exponents are NegativeExponent.
    /// Bases 0 and +/-1 support arbitrary nonnegative exponents; other exponents
    /// must fit u32 (ExponentTooLarge). Capacity overflow is ResultTooLarge.
    pub fn pow(allocator: Allocator, a: ZBigInt, exponent: ZBigInt) BigIntError!ZBigInt {
        if (exponent.isNegative()) return error.NegativeExponent;
        if (exponent.isZero()) return fromInt(allocator, 1);
        if (a.isZero()) return fromInt(allocator, 0);
        if (a.isUnit()) return fromInt(allocator, if (a.isNegative() and exponent.value.isOdd()) -1 else 1);
        if (exponent.isUnit()) return a.cloneWithAllocator(allocator);
        const exp = exponent.value.toInt(u32) catch return error.ExponentTooLarge;
        const capacity = try powerCapacity(a, exp);
        var r = try initCapacity(allocator, capacity);
        errdefer r.deinit();
        // One-shot calls need exact scratch, not a persistent workspace.
        const scratch = try allocator.alloc(Limb, capacity);
        defer allocator.free(scratch);
        var m = r.value.toMutable();
        m.pow(a.value.toConst(), exp, scratch);
        r.value.setMetadata(m.positive, m.len);
        // A nonzero base of magnitude >= 2 and a positive exponent cannot
        // produce zero. Trivial cases were handled before allocating.
        return r;
    }

    /// Write infinite-two's-complement a & b, retaining destination capacity.
    pub fn bitAndInto(self: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt) BigIntError!void {
        try self.value.bitAnd(&a.value, &b.value);
        self.canonicalize();
    }

    fn andCapacity(a: ZBigInt, b: ZBigInt) BigIntError!usize {
        if (a.isNegative() and b.isNegative()) return checkedAdd(@max(a.value.len(), b.value.len()), 1);
        if (a.isNegative()) return b.value.len();
        if (b.isNegative()) return a.value.len();
        return @min(a.value.len(), b.value.len());
    }

    /// Return owned infinite-two's-complement a & b using allocator.
    pub fn bitAnd(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = try initCapacity(allocator, try andCapacity(a, b));
        errdefer r.deinit();
        try r.bitAndInto(&a, &b);
        return r;
    }

    /// Std 0.16's mixed-sign OR can omit untouched high limbs even with ample
    /// capacity. Use its direct positive path, and De Morgan for negatives.
    pub fn bitOrInto(self: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt, workspace: *Workspace) BigIntError!void {
        if (a.isZero()) {
            if (self != b) try self.value.copy(b.value.toConst());
        } else if (b.isZero()) {
            if (self != a) try self.value.copy(a.value.toConst());
        } else if (!a.isNegative() and !b.isNegative()) {
            try self.value.bitOr(&a.value, &b.value);
        } else {
            if (workspace.or_a == null) workspace.or_a = try initCapacity(workspace.allocator, try checkedAdd(a.value.len(), 1));
            if (workspace.or_b == null) workspace.or_b = try initCapacity(workspace.allocator, try checkedAdd(b.value.len(), 1));
            const na = &workspace.or_a.?;
            const nb = &workspace.or_b.?;
            try na.notInto(a);
            try nb.notInto(b);
            try self.bitAndInto(na, nb);
            try self.notInto(self);
        }
        self.canonicalize();
    }

    /// Return owned infinite-two's-complement a | b; avoids std's mixed-sign OR bug.
    pub fn bitOr(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        var r = try initCapacity(allocator, try checkedAdd(@max(a.value.len(), b.value.len()), 1));
        errdefer r.deinit();
        var workspace = Workspace.init(allocator);
        defer workspace.deinit();
        try r.bitOrInto(&a, &b, &workspace);
        return r;
    }

    /// Write infinite-two's-complement a ^ b, retaining destination capacity.
    pub fn bitXorInto(self: *ZBigInt, a: *const ZBigInt, b: *const ZBigInt) BigIntError!void {
        try self.value.bitXor(&a.value, &b.value);
        self.canonicalize();
    }

    /// Return owned infinite-two's-complement a ^ b using allocator.
    pub fn bitXor(allocator: Allocator, a: ZBigInt, b: ZBigInt) BigIntError!ZBigInt {
        const capacity = try checkedAdd(@max(a.value.len(), b.value.len()), @intFromBool(a.isNegative() != b.isNegative()));
        var r = try initCapacity(allocator, capacity);
        errdefer r.deinit();
        try r.bitXorInto(&a, &b);
        return r;
    }

    /// Write -(a + 1) using scalar addition; supports the same object as input.
    pub fn notInto(self: *ZBigInt, a: *const ZBigInt) BigIntError!void {
        try self.value.addScalar(&a.value, @as(i64, 1));
        self.negateInPlace();
    }

    /// Return owned infinite-two's-complement ~a, using one result allocation.
    pub fn not(allocator: Allocator, a: ZBigInt) BigIntError!ZBigInt {
        var r = try initCapacity(allocator, try checkedAdd(a.value.len(), 1));
        errdefer r.deinit();
        try r.notInto(&a);
        return r;
    }

    /// Write a * 2^shift, retaining capacity; zero avoids enormous allocations.
    /// Capacity overflow is ResultTooLarge; allocation failure is OutOfMemory.
    pub fn shiftLeftInto(self: *ZBigInt, a: *const ZBigInt, shift: usize) BigIntError!void {
        if (a.isZero()) {
            try self.value.set(0);
            return;
        }
        _ = try checkedAdd(a.value.bitCountAbs(), shift);
        const capacity = try checkedAdd(try checkedAdd(a.value.len(), shift / limb_bits), 1);
        _ = try checkedMul(capacity, @sizeOf(Limb));
        try self.value.shiftLeft(&a.value, shift);
        self.canonicalize();
    }

    /// Return owned a * 2^shift for a nonnegative native shift count.
    pub fn shiftLeft(allocator: Allocator, a: ZBigInt, shift: usize) BigIntError!ZBigInt {
        if (a.isZero()) return fromInt(allocator, 0);
        _ = try checkedAdd(a.value.bitCountAbs(), shift);
        const capacity = try checkedAdd(try checkedAdd(a.value.len(), shift / limb_bits), 1);
        var r = try initCapacity(allocator, capacity);
        errdefer r.deinit();
        try r.shiftLeftInto(&a, shift);
        return r;
    }

    /// Write arithmetic a >> shift, retaining capacity; large shifts yield 0 or -1.
    pub fn shiftRightInto(self: *ZBigInt, a: *const ZBigInt, shift: usize) BigIntError!void {
        if (a.isZero() or shift >= a.value.bitCountAbs()) {
            try self.value.set(@as(i64, if (a.isNegative()) -1 else 0));
            return;
        }
        try self.value.shiftRight(&a.value, shift);
        self.canonicalize();
    }

    /// Return owned arithmetic a >> shift for a nonnegative native count.
    pub fn shiftRight(allocator: Allocator, a: ZBigInt, shift: usize) BigIntError!ZBigInt {
        if (a.isZero() or shift >= a.value.bitCountAbs()) return fromInt(allocator, if (a.isNegative()) -1 else 0);
        var r = try initCapacity(allocator, a.value.len() - shift / limb_bits);
        errdefer r.deinit();
        try r.shiftRightInto(&a, shift);
        return r;
    }

    /// ECMAScript shift counter, including negative and arbitrarily large
    /// counts. A negative count reverses the direction.
    pub fn shiftLeftBigInt(allocator: Allocator, a: ZBigInt, shift: ZBigInt) BigIntError!ZBigInt {
        return shiftBigInt(allocator, a, shift, true);
    }

    /// Return arithmetic a >> shift for an arbitrary BigInt count.
    /// Negative counts reverse direction; huge right shifts yield 0 or -1.
    pub fn shiftRightBigInt(allocator: Allocator, a: ZBigInt, shift: ZBigInt) BigIntError!ZBigInt {
        return shiftBigInt(allocator, a, shift, false);
    }

    fn shiftBigInt(allocator: Allocator, a: ZBigInt, shift: ZBigInt, left: bool) BigIntError!ZBigInt {
        if (a.isZero()) return fromInt(allocator, 0);
        var magnitude = shift.value.toConst();
        magnitude.positive = true;
        const count = magnitude.toInt(usize) catch {
            if (left != shift.isNegative()) return error.ResultTooLarge;
            return fromInt(allocator, if (a.isNegative()) -1 else 0);
        };
        if (left != shift.isNegative()) return shiftLeft(allocator, a, count);
        return shiftRight(allocator, a, count);
    }
};
