const std = @import("std");
const c = @import("gpu.zig").c;

// Global error tracking for WebGPU
pub var global_compile_err = false;

pub fn globalDeviceErrorCb(typ: c.WGPUErrorType, msg: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata; _ = typ;
    global_compile_err = true;
    std.debug.print("\n=== WebGPU Compilation Error ===\n{s}\n================================\n", .{if(msg != null) msg else @as([*c]const u8, "Unknown Error")});
}

pub fn loadPipeline(allocator: std.mem.Allocator, device: c.WGPUDevice, bind_group_layout: c.WGPUBindGroupLayout, path: []const u8, fallback_format: c.WGPUTextureFormat) !?c.WGPURenderPipeline {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Failed to open shader file: {any}\n", .{err});
        return null; 
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
    defer allocator.free(content);

    // Provide a valid null-terminated string using standard methods or allocate
    const z_content = try allocator.dupeZ(u8, content);
    defer allocator.free(z_content);

    var wgsl_desc = std.mem.zeroes(c.WGPUShaderModuleWGSLDescriptor);
    wgsl_desc.chain.next = null;
    wgsl_desc.chain.sType = c.WGPUSType_ShaderModuleWGSLDescriptor;
    wgsl_desc.code = @ptrCast(z_content.ptr);

    var sm_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
    sm_desc.nextInChain = &wgsl_desc.chain;

    global_compile_err = false;

    const shader_module = c.wgpuDeviceCreateShaderModule(device, &sm_desc);
    
    // Check if error callback fired during module creation
    if (global_compile_err or shader_module == null) {
        if (shader_module != null) c.wgpuShaderModuleRelease(shader_module);
        return null;
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
    target.format = fallback_format;
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
        if (pipeline != null) {
            c.wgpuRenderPipelineRelease(pipeline);
        }
        return null;
    }

    return pipeline;
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
        // 200ms debounce
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
