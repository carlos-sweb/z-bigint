# Z-BIGINT

[![Zig Version](https://img.shields.io/badge/zig-0.16-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A thin, general-purpose wrapper over Zig 0.16's own arbitrary-precision integer (`std.math.big.int.Managed`), giving it the specific operation set and semantics JS's `BigInt` needs — part of the [z-*](https://github.com/carlos-sweb) micro-library ecosystem. Nothing JS-specific lives here (no `JSValue`, no engine coupling): a plain sibling library, reusable anywhere an arbitrary-precision integer is useful.

## Scope

**Supported:**
- Construction from digit text: decimal, or `0x`/`0o`/`0b`-prefixed, `_` digit separators allowed anywhere in the run, optional leading `-`/`+` sign — or from a native `i64`.
- Stringify at any radix 2-36.
- Arithmetic: add, sub, mul, **truncating** div and rem (matches JS BigInt's `/`/`%` — truncates toward zero, NOT floor division), pow (non-negative exponent only), negate.
- Bitwise: and, or, xor, not, shl, shr — all arithmetic/sign-preserving, matching JS BigInt's own infinite-two's-complement semantics for negative operands. **No unsigned right shift** (`>>>`): there's no unsigned BigInt representation, matching real JS (`1n >>> 1n` is a TypeError there too).
- Compare (`cmp`) and equality/hash (`eql`/`hash`) — **value-based, not identity-based**: two independently-parsed equal values compare and hash equal (`123n === 123n` is `true` in JS even across distinct allocations).

**Explicitly NOT included** (out of scope for v1): `asIntN`/`asUintN` fixed-width wrapping helpers, `sqrt`/`gcd` (call `std.math.big.int.Managed`'s own methods directly if needed — no reason to re-wrap them).

## A real std.math.big.int bug this library works around

`std.math.big.int.Managed.bitOr` (Zig 0.16) under-reserves capacity when its two operands have different signs — unlike its `bitAnd`/`bitXor` siblings, which both explicitly add a headroom limb for that case, `bitOr`'s capacity calculation doesn't, and it silently produces a **wrong result**, not an error. Found via a fuzz probe cross-checked against real Node BigInt (15 random large mixed-sign pairs, 3 mismatched). `ZBigInt.bitOr` is implemented via De Morgan's law (`a | b == ~(~a & ~b)`) instead, routing through the verified-correct `bitAnd`/`not` path. Covered by a permanent regression test (`tests/bitwise_test.zig`).

## Design

- `fromDigitText(allocator, raw) BigIntError!ZBigInt` / `fromInt(allocator, n: i64) BigIntError!ZBigInt`
- `toString(self, allocator, radix: u8) BigIntError![]u8`
- `add`/`sub`/`mul`/`divTrunc`/`remTrunc`/`pow` — all `fn(allocator, a, b) BigIntError!ZBigInt`; `negate(self) BigIntError!ZBigInt`
- `bitAnd`/`bitOr`/`bitXor`/`shiftLeft`/`shiftRight` — `fn(allocator, a, b/shift) BigIntError!ZBigInt`; `not(allocator, a) BigIntError!ZBigInt`
- `eql`/`cmp`/`hash`/`isZero`/`isNegative`/`clone`/`deinit`
- `BigIntError`: `InvalidDigits`, `DivisionByZero`, `NegativeExponent`, `OutOfMemory`

## Usage

```zig
const zbigint = @import("zbigint");
const ZBigInt = zbigint.ZBigInt;

var a = try ZBigInt.fromDigitText(allocator, "123456789012345678901234567890");
defer a.deinit();
var b = try ZBigInt.fromInt(allocator, 2);
defer b.deinit();

var product = try ZBigInt.mul(allocator, a, b);
defer product.deinit();
const s = try product.toString(allocator, 10);
defer allocator.free(s);
```
