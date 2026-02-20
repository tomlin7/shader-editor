const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "shader-editor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // We assume libs are placed in `lib/` directory, 
    // and headers in `include/` directory.
    exe.addIncludePath(b.path("include"));
    exe.addIncludePath(b.path("include/webgpu"));
    
    // Check OS
    if (target.result.os.tag == .windows) {
        exe.addLibraryPath(b.path("lib/windows"));
        exe.addLibraryPath(b.path("lib"));
        exe.linkSystemLibrary("wgpu_native");
        exe.linkSystemLibrary("glfw3");
        exe.linkSystemLibrary("user32");
        exe.linkSystemLibrary("gdi32");
        exe.linkSystemLibrary("shell32");
        exe.linkSystemLibrary("ws2_32");
        exe.linkSystemLibrary("bcrypt");
        exe.linkSystemLibrary("advapi32");
        exe.linkSystemLibrary("userenv");
        exe.linkSystemLibrary("ntdll");

        b.installBinFile("lib/windows/glfw3.dll", "glfw3.dll");
        b.installBinFile("lib/windows/wgpu_native.dll", "wgpu_native.dll");
    } else if (target.result.os.tag == .macos) {
        exe.addLibraryPath(b.path("lib/macos"));
        exe.addLibraryPath(b.path("lib"));
        exe.linkSystemLibrary("wgpu_native");
        exe.linkSystemLibrary("glfw"); 
        exe.linkFramework("Cocoa");
        exe.linkFramework("CoreVideo");
        exe.linkFramework("IOKit");
        exe.linkFramework("QuartzCore");
        exe.linkFramework("Metal");
    } else {
        // linux
        exe.addLibraryPath(b.path("lib/linux"));
        exe.addLibraryPath(b.path("lib"));
        exe.linkSystemLibrary("wgpu_native");
        // Often on linux, glfw is provided system-wide
        exe.linkSystemLibrary("glfw");
        exe.linkSystemLibrary("dl");
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("X11");
    }

    exe.linkLibC();
    
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    // Allow passing args to the executable, optional 
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
