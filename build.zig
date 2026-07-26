const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zbigint_module = b.addModule("zbigint", .{
        .root_source_file = b.path("src/zbigint.zig"),
    });

    const test_step = b.step("test", "Run all tests");

    const test_files = [_][]const u8{
        "tests/parse_test.zig",
        "tests/arithmetic_test.zig",
        "tests/bitwise_test.zig",
        "tests/compare_test.zig",
        "tests/fromfloat_test.zig",
    };

    inline for (test_files) |test_file| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(test_file),
                .target = target,
                .optimize = optimize,
            }),
        });
        unit_tests.root_module.addImport("zbigint", zbigint_module);
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    const src_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zbigint.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_src_tests = b.addRunArtifact(src_tests);
    test_step.dependOn(&run_src_tests.step);

    b.default_step = test_step;
}
