# Changelog

## 0.1.1

- Add exact `i128` construction and checked extraction for integrations that store signed 128-bit integer values.
- Return `ResultTooLarge` when an arbitrary-precision value does not fit in `i128`; neither conversion uses floating point.

## 0.1.0

- Support Zig 0.16.0 and 0.17.0, with Debug/ReleaseFast tests on 32-bit and 64-bit Linux targets.
- Provide exact arbitrary-precision arithmetic, truncating division/remainder and infinite-two's-complement bitwise operations.
- Normalize zero's sign, fix base-8/base-32 formatting across limb boundaries, and size float-conversion storage for the target's limb width.
- Add ECMAScript literal, string, Number and signed BigInt-shift adapters, with distinct input/domain/allocation errors.
- Preallocate output storage, optimize trivial powers/division and scalar NOT, and preserve the mixed-sign OR workaround.
- Add reusable Into operations, Workspace scratch, combined division/remainder and cloning with a chosen allocator.
- Generate API documentation with `zig build docs` and publish it to GitHub Pages after the test matrix passes.

API reference: <https://carlos-sweb.github.io/z-bigint/>.

This library provides the numerical BigInt core and explicit adapters; engine coercions, JS exceptions and fixed-width `asIntN`/`asUintN` remain outside its scope.
