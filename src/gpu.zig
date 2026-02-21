const std = @import("std");

pub const c = @cImport({
    @cInclude("webgpu.h");
    @cInclude("wgpu.h");

    @cInclude("GLFW/glfw3.h");

    if (@import("builtin").os.tag == .windows) {
        @cDefine("GLFW_EXPOSE_NATIVE_WIN32", "1");
        @cInclude("GLFW/glfw3native.h");
        @cInclude("windows.h");
    } else if (@import("builtin").os.tag == .macos) {
        @cDefine("GLFW_EXPOSE_NATIVE_COCOA", "1");
        @cInclude("GLFW/glfw3native.h");
        @cInclude("objc/message.h");
    } else {
        @cDefine("GLFW_EXPOSE_NATIVE_X11", "1");
        @cDefine("GLFW_EXPOSE_NATIVE_WAYLAND", "1");
        @cInclude("GLFW/glfw3native.h");
    }
});

pub const Uniforms = extern struct {
    time: f32,
    padding: f32 = 0,
    resolution: [2]f32,
};

pub const GpuState = struct {
    instance: c.WGPUInstance,
    surface: c.WGPUSurface,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    config: c.WGPUSurfaceConfiguration,
    uniform_buf: c.WGPUBuffer,
    bind_group_layout: c.WGPUBindGroupLayout,
    bind_group: c.WGPUBindGroup,

    pub fn reconfigureSurface(self: *GpuState, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        self.config.width = width;
        self.config.height = height;
        c.wgpuSurfaceConfigure(self.surface, &self.config);
    }
};

fn onAdapterRequest(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = message; _ = status;
    const ptr = @as(*c.WGPUAdapter, @ptrCast(@alignCast(userdata.?)));
    ptr.* = adapter;
}

fn onDeviceRequest(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: [*c]const u8, userdata: ?*anyopaque) callconv(.c) void {
    _ = message; _ = status;
    const ptr = @as(*c.WGPUDevice, @ptrCast(@alignCast(userdata.?)));
    ptr.* = device;
}

pub fn init(window: *const @import("platform.zig").Window) !GpuState {
    var instance_desc = std.mem.zeroes(c.WGPUInstanceDescriptor);
    instance_desc.nextInChain = null;
    const instance = c.wgpuCreateInstance(&instance_desc) orelse return error.WgpuInstanceFailed;

    const surface = try window.createSurface(instance);

    var req_adapter_opts = std.mem.zeroes(c.WGPURequestAdapterOptions);
    req_adapter_opts.compatibleSurface = surface;

    var adapter: c.WGPUAdapter = null;
    c.wgpuInstanceRequestAdapter(instance, &req_adapter_opts, onAdapterRequest, @ptrCast(&adapter));
    if (adapter == null) return error.NoAdapter;

    var req_device_opts = std.mem.zeroes(c.WGPUDeviceDescriptor);
    var device: c.WGPUDevice = null;
    c.wgpuAdapterRequestDevice(adapter, &req_device_opts, onDeviceRequest, @ptrCast(&device));
    if (device == null) return error.NoDevice;

    c.wgpuDeviceSetUncapturedErrorCallback(device, @import("shader_manager.zig").globalDeviceErrorCb, null);

    const queue = c.wgpuDeviceGetQueue(device);

    var buf_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
    buf_desc.usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst;
    buf_desc.size = @sizeOf(Uniforms);
    buf_desc.mappedAtCreation = 0;
    const uniform_buf = c.wgpuDeviceCreateBuffer(device, &buf_desc);

    var bgl_entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
    bgl_entry.binding = 0;
    bgl_entry.visibility = c.WGPUShaderStage_Fragment | c.WGPUShaderStage_Vertex;
    bgl_entry.buffer.type = c.WGPUBufferBindingType_Uniform;
    bgl_entry.buffer.minBindingSize = @sizeOf(Uniforms);

    var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
    bgl_desc.entryCount = 1;
    bgl_desc.entries = &bgl_entry;
    const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc);

    var bg_entry = std.mem.zeroes(c.WGPUBindGroupEntry);
    bg_entry.binding = 0;
    bg_entry.buffer = uniform_buf;
    bg_entry.size = @sizeOf(Uniforms);
    bg_entry.offset = 0;

    var bg_desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
    bg_desc.layout = bind_group_layout;
    bg_desc.entryCount = 1;
    bg_desc.entries = &bg_entry;
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bg_desc);

    var width: i32 = 0;
    var height: i32 = 0;
    c.glfwGetFramebufferSize(window.handle, &width, &height);

    var config = std.mem.zeroes(c.WGPUSurfaceConfiguration);
    config.device = device;
    config.usage = c.WGPUTextureUsage_RenderAttachment;
    config.format = c.WGPUTextureFormat_BGRA8Unorm; // Safe default format
    config.width = @as(u32, @intCast(width));
    config.height = @as(u32, @intCast(height));
    config.presentMode = c.WGPUPresentMode_Fifo; // VSync
    config.alphaMode = c.WGPUCompositeAlphaMode_Auto;

    c.wgpuSurfaceConfigure(surface, &config);

    return GpuState{
        .instance = instance,
        .surface = surface,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .config = config,
        .uniform_buf = uniform_buf,
        .bind_group_layout = bind_group_layout,
        .bind_group = bind_group,
    };
}
