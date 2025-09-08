const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});
    const serial = b.dependency("serial", .{}).module("serial");
    const ESPAT = b.dependency("ESPAT", .{}).module("ESPAT");

    const exe = b.addExecutable(.{
        .name = "ESP_AT",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("serial", serial);
    exe.root_module.addImport("ESPAT", ESPAT);

    b.installArtifact(exe);
}
