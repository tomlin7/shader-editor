const std = @import("std");
const c = @import("gpu.zig").c;

// Global error tracking for WebGPU
pub var global_compile_err = false;
pub var global_error_msg: [1024]u8 = undefined;
pub var global_error_len: usize = 0;

pub fn globalDeviceErrorCb(typ: c.WGPUErrorType, msg: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    _ = typ;
    global_compile_err = true;
    // Capture error message
    if (msg != null) {
        const s: [*c]const u8 = msg;
        var len: usize = 0;
        while (s[len] != 0 and len < global_error_msg.len - 1) : (len += 1) {}
        @memcpy(global_error_msg[0..len], s[0..len]);
        global_error_len = len;
    } else {
        const fallback = "Unknown Error";
        @memcpy(global_error_msg[0..fallback.len], fallback);
        global_error_len = fallback.len;
    }
    std.debug.print("\n=== WebGPU Compilation Error ===\n{s}\n================================\n", .{global_error_msg[0..global_error_len]});
}

pub const CompileResult = struct {
    pipeline: ?c.WGPURenderPipeline,
    error_msg: ?[]const u8,
};

fn buildPipeline(device: c.WGPUDevice, bind_group_layout: c.WGPUBindGroupLayout, z_source: [:0]const u8, format: c.WGPUTextureFormat) CompileResult {
    var wgsl_desc = std.mem.zeroes(c.WGPUShaderModuleWGSLDescriptor);
    wgsl_desc.chain.next = null;
    wgsl_desc.chain.sType = c.WGPUSType_ShaderModuleWGSLDescriptor;
    wgsl_desc.code = @ptrCast(z_source.ptr);

    var sm_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
    sm_desc.nextInChain = &wgsl_desc.chain;

    global_compile_err = false;
    global_error_len = 0;

    const shader_module = c.wgpuDeviceCreateShaderModule(device, &sm_desc);

    if (global_compile_err or shader_module == null) {
        if (shader_module != null) c.wgpuShaderModuleRelease(shader_module);
        return .{
            .pipeline = null,
            .error_msg = if (global_error_len > 0) global_error_msg[0..global_error_len] else "Unknown compilation error",
        };
    }
    defer c.wgpuShaderModuleRelease(shader_module);

    var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
    pl_desc.bindGroupLayoutCount = 1;
    pl_desc.bindGroupLayouts = &bind_group_layout;
    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pl_desc);
    defer c.wgpuPipelineLayoutRelease(pipeline_layout);

    var rp_desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    rp_desc.layout = pipeline_layout;
    rp_desc.vertex.module = shader_module;
    rp_desc.vertex.entryPoint = "vs_main";
    rp_desc.vertex.bufferCount = 0;

    rp_desc.primitive.topology = c.WGPUPrimitiveTopology_TriangleList;
    rp_desc.primitive.frontFace = c.WGPUFrontFace_CCW;
    rp_desc.primitive.cullMode = c.WGPUCullMode_None;

    rp_desc.multisample.count = 1;
    rp_desc.multisample.mask = 0xFFFFFFFF;
    rp_desc.multisample.alphaToCoverageEnabled = 0;

    var blend = std.mem.zeroes(c.WGPUBlendState);
    blend.color.operation = c.WGPUBlendOperation_Add;
    blend.color.srcFactor = c.WGPUBlendFactor_One;
    blend.color.dstFactor = c.WGPUBlendFactor_Zero;
    blend.alpha.operation = c.WGPUBlendOperation_Add;
    blend.alpha.srcFactor = c.WGPUBlendFactor_One;
    blend.alpha.dstFactor = c.WGPUBlendFactor_Zero;

    var target = std.mem.zeroes(c.WGPUColorTargetState);
    target.format = format;
    target.blend = &blend;
    target.writeMask = c.WGPUColorWriteMask_All;

    var frag = std.mem.zeroes(c.WGPUFragmentState);
    frag.module = shader_module;
    frag.entryPoint = "fs_main";
    frag.targetCount = 1;
    frag.targets = &target;
    rp_desc.fragment = &frag;

    const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &rp_desc);

    if (global_compile_err or pipeline == null) {
        if (pipeline != null) c.wgpuRenderPipelineRelease(pipeline);
        return .{
            .pipeline = null,
            .error_msg = if (global_error_len > 0) global_error_msg[0..global_error_len] else "Pipeline creation failed",
        };
    }

    return .{ .pipeline = pipeline, .error_msg = null };
}

pub fn compileFromSource(allocator: std.mem.Allocator, device: c.WGPUDevice, bind_group_layout: c.WGPUBindGroupLayout, source: []const u8, format: c.WGPUTextureFormat) CompileResult {
    const z_source = allocator.dupeZ(u8, source) catch return .{ .pipeline = null, .error_msg = "Out of memory" };
    defer allocator.free(z_source);
    return buildPipeline(device, bind_group_layout, z_source, format);
}

pub fn loadPipeline(allocator: std.mem.Allocator, device: c.WGPUDevice, bind_group_layout: c.WGPUBindGroupLayout, path: []const u8, format: c.WGPUTextureFormat) !?c.WGPURenderPipeline {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Failed to open shader file: {any}\n", .{err});
        return null;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    const result = compileFromSource(allocator, device, bind_group_layout, content, format);
    return result.pipeline;
}

pub const ShaderWatcher = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    last_mtime: i128 = 0,
    last_check_time: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) ShaderWatcher {
        const initial_stat = std.fs.cwd().statFile(path) catch null;
        return ShaderWatcher{
            .allocator = allocator,
            .path = path,
            .last_mtime = if (initial_stat != null) initial_stat.?.mtime else 0,
            .last_check_time = std.time.milliTimestamp(),
        };
    }

    pub fn checkModified(self: *ShaderWatcher) bool {
        const now = std.time.milliTimestamp();
        if (now - self.last_check_time < 200) return false;

        self.last_check_time = now;
        const stat = std.fs.cwd().statFile(self.path) catch return false;

        if (stat.mtime > self.last_mtime) {
            self.last_mtime = stat.mtime;
            return true;
        }
        return false;
    }
};
