# Z-BIGINT

[![Zig Version](https://img.shields.io/badge/zig-0.16%20%7C%200.17-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Arbitrary-precision integers compatible with Zig **0.16.0 and 0.17.0**, backed by `std.math.big.int.Managed`, with the arithmetic and bitwise semantics needed by JavaScript BigInt. The library has no engine or `JSValue` dependency.

## API documentation and Zig compatibility

[Browse the generated Zig API documentation](https://carlos-sweb.github.io/z-bigint/).

Both Zig 0.16.0 and 0.17.0 are supported. CI tests both versions on x86_64 and x86 Linux in Debug and ReleaseFast. The package keeps `minimum_zig_version = "0.16.0"`; the local `mise.toml` selects Zig 0.17.0.

Generate the native Zig documentation with either supported compiler:

```bash
zig build docs
```

The output is in `zig-out/docs/`. Serve it over HTTP to load the generated WebAssembly and source archive:

```bash
python3 -m http.server 8000 --directory zig-out/docs
```

Open <http://localhost:8000/>. GitHub Pages publishes the same generated API, built with Zig 0.17.0 after tests pass on pushes to `master`. No generated documentation or benchmark results are committed.

## Construction and conversion

- `fromDigitText(allocator, raw)` is a **generic** parser: optional `+`/`-`, decimal or `0x`/`0o`/`0b` prefixes, and underscores anywhere in the digit run. At least one actual digit is required; embedded or repeated signs are rejected. It does not validate JS literal syntax.
- `fromLiteralText(allocator, token)` validates a complete JS BigInt literal including trailing `n`, separator positions and decimal leading-zero restrictions. Unary signs are expression operators, not part of a literal token.
- `fromEcmaString(allocator, text)` implements the integer-string grammar used by `BigInt(string)` on UTF-8 text: ECMAScript whitespace is trimmed, empty input means zero, separators are rejected, and a sign is permitted only for decimal input.
- `fromInt(allocator, n: i64)` constructs an exact native integer.
- `fromI128(allocator, n: i128)` constructs an exact signed 128-bit integer; `toI128()` extracts one or returns `ResultTooLarge` if the value does not fit. Neither conversion uses floating point.
- `fromFloat(allocator, number: f64)` rejects nonfinite input and truncates finite fractions toward zero. Capacity is calculated for the target's limb width, including 32-bit targets.
- `fromNumber(allocator, number: f64)` additionally rejects fractions, for the numeric conversion used by `BigInt(number)`.
- `toFloat()` rounds to the nearest representable `f64`, ties to even; it can lose precision or overflow to infinity. Zero converts to positive `0.0`.
- `toString(allocator, radix)` returns an owned lowercase digit string at radix 2–36. `stringSizeUpperBound(radix)` and `toStringInto(output, radix, workspace)` support reusable caller-owned buffers. The latter returns a slice borrowing `output`; provision the advertised upper bound, which can exceed the actual length for non-power-of-two bases.

## Operations

`add`, `sub`, `mul`, `divTrunc`, `remTrunc`, `pow`, `bitAnd`, `bitOr`, `bitXor`, `not`, `shiftLeft` and `shiftRight` return independent owned values. Binary operations take `(allocator, a, b)`; the shifts take a `usize` count. `negate()` copies using the source allocator.

Division truncates toward zero, and the remainder has the dividend's sign. `divRemTrunc(allocator, a, b)` calculates both in one pass and returns a `DivRem` owning `quotient` and `remainder`; call its `deinit()` to free both.

Powers accept arbitrary BigInt exponents for bases `0`, `1` and `-1`. Negative exponents are rejected. Other exponents must fit `u32`; capacity arithmetic is checked and reports `ResultTooLarge` on overflow. Zero to the zeroth power is one.

Bitwise operations use infinite two's-complement semantics. Right shifts are arithmetic. `shiftLeftBigInt` and `shiftRightBigInt` accept a BigInt count: negative counts reverse direction, and arbitrarily large right shifts saturate to zero or minus one. Huge nonzero left shifts report a size or allocation error. There is no unsigned right shift; an integrating JS engine must reject `>>>` with TypeError.

`eql`, `cmp`, `hash`, `isZero` and `isNegative` inspect values. All wrapper-produced zero results have positive sign. Hashes are not stable identifiers across platforms or std versions; no cache is maintained because the public `value` field is mutable.

## Reusing storage

Create a destination with `fromInt(allocator, 0)` and a `Workspace.init(allocator)`. Both own their allocations and must be deinitialized. A workspace retains scratch capacity and OR temporaries across calls; it is not thread-safe.

- `addInto`, `subInto`, `bitAndInto`, `bitXorInto` take `(destination, a_ptr, b_ptr)` through method syntax.
- `mulInto` and `bitOrInto` additionally take `workspace`.
- `notInto(a_ptr)`, `shiftLeftInto(a_ptr, count)` and `shiftRightInto(a_ptr, count)` reuse the destination; `negateInPlace()` changes it directly.
- `powInto(base_ptr, exponent_ptr, workspace)` reuses output and scratch but rejects an output aliasing either input.
- `ZBigInt.divRemTruncInto(q_ptr, r_ptr, a_ptr, b_ptr, workspace)` reuses both outputs and scratch. Outputs must be distinct and must not alias inputs.

Except for the explicit restrictions above, an operand may be the **same destination object**. Distinct shallow copies sharing its limbs are not supported as destinations/operands in these calls. Multiplication scratch retains alias copies; std's optional internal acceleration can still allocate additional working memory for large operands.

On a fallible Into operation, allocation failure leaves the destination owned and valid, but does not guarantee its old value is preserved. Output strings, scratch and workspace internal temporaries must not overlap operand storage. Use separate workspaces for concurrent operations.

## Ownership

`ZBigInt` owns its `Managed`. Ordinary assignment is a shallow copy, not a new owner; never deinitialize both copies. Use `clone()` or `cloneWithAllocator(allocator)` for independent storage. Keep allocators alive until their values are freed. When accessing `value` directly, maintain normalized limbs and valid metadata; normalized zero has one zero limb. Library methods canonicalize zero's sign.

```zig
const zbigint = @import("zbigint");
const ZBigInt = zbigint.ZBigInt;

var a = try ZBigInt.fromDigitText(allocator, "123456789012345678901234567890");
defer a.deinit();
var b = try ZBigInt.fromInt(allocator, 2);
defer b.deinit();
var product = try ZBigInt.fromInt(allocator, 0);
defer product.deinit();
var workspace = zbigint.Workspace.init(allocator);
defer workspace.deinit();
try product.mulInto(&a, &b, &workspace);
const s = try product.toString(allocator, 10);
defer allocator.free(s);
```

## Errors and integration

`BigIntError` includes `InvalidDigits`, `InvalidRadix`, `InvalidFloat`, `NonIntegralFloat`, `DivisionByZero`, `NegativeExponent`, `ExponentTooLarge`, `ResultTooLarge`, `BufferTooSmall`, `InvalidAlias` and `OutOfMemory`. Allocation failures preserve their classification. An engine must map these to appropriate JS exceptions and implement coercion, Number/BigInt mixing rules and prototype behavior itself.

Fixed-width `asIntN`/`asUintN`, `sqrt` and `gcd` remain outside this wrapper's scope. This numerical library is not a complete ECMAScript runtime.

## Zig std workarounds and tests

Std 0.16's mixed-sign `bitOr` can omit high limbs of a negative operand even with sufficient capacity. The wrapper uses its direct path for nonnegative operands and De Morgan for negative operands; it retains the mixed-sign regression. Increasing capacity alone does not fix the std bug.

Std's power-of-two formatter groups each limb independently, producing wrong base-8/base-32 strings across limb boundaries. This wrapper extracts digits by global bit position and joins adjacent limbs when necessary.

Run `zig build test` with Zig 0.16.0 or 0.17.0. Tests include the original cases, all-radix round trips at limb boundaries, zero normalization, float extremes, parsing adapters, large exponents and shifts, destination aliasing, scratch reuse and allocation failures. CI runs both compiler versions in Debug and ReleaseFast on x86_64 and x86 Linux. The filtered package includes the test sources.
