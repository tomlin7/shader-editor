const std = @import("std");
const platform = @import("platform.zig");
const gpu = @import("gpu.zig");
const shader_manager = @import("shader_manager.zig");
const c = gpu.c;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window = try platform.Window.init(800, 600, "shader editor");
    defer window.deinit();

    const gpu_state = try gpu.init(&window);

    // Default valid pipeline state
    var current_pipeline: ?c.WGPURenderPipeline = null;

    var watcher = shader_manager.ShaderWatcher.init(allocator, "shader.wgsl");

    const format = c.WGPUTextureFormat_BGRA8Unorm;

    const initial_pipeline = shader_manager.loadPipeline(allocator, gpu_state.device, gpu_state.bind_group_layout, "shader.wgsl", format) catch null;
    if (initial_pipeline) |pl| {
        current_pipeline = pl;
        std.debug.print("Initial shader loaded successfully.\n", .{});
    } else {
        std.debug.print("Failed to load initial shader. Fix it and save to reload.\n", .{});
    }

    const start_time = std.time.milliTimestamp();

    while (!window.shouldClose()) {
        window.pollEvents();

        // Hot reload loop
        if (watcher.checkModified()) {
            std.debug.print("Shader modified! Recompiling...\n", .{});

            // Recompile
            const new_pipeline = shader_manager.loadPipeline(allocator, gpu_state.device, gpu_state.bind_group_layout, "shader.wgsl", format) catch null;

            // if success, swap
            if (new_pipeline) |pl| {
                if (current_pipeline) |old_pl| {
                    c.wgpuRenderPipelineRelease(old_pl);
                }
                current_pipeline = pl;
                std.debug.print("Recompiled successfully. Pipeline swapped.\n", .{});
            } else {
                std.debug.print("Compilation failed. Keeping old pipeline rendering.\n", .{});
            }
        }

        // Setup passing uniforms
        const current_time = std.time.milliTimestamp();
        const t = @as(f32, @floatFromInt(current_time - start_time)) / 1000.0;

        var w: i32 = 0;
        var h: i32 = 0;
        c.glfwGetFramebufferSize(window.handle, &w, &h);

        const uniforms = gpu.Uniforms{
            .time = t,
            .resolution = .{ @as(f32, @floatFromInt(w)), @as(f32, @floatFromInt(h)) },
        };

        c.wgpuQueueWriteBuffer(gpu_state.queue, gpu_state.uniform_buf, 0, &uniforms, @sizeOf(gpu.Uniforms));

        // Render pass
        var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
        c.wgpuSurfaceGetCurrentTexture(gpu_state.surface, &surface_texture);
        if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_Success or surface_texture.texture == null) {
            std.Thread.sleep(16_000_000); // Backoff a bit if minimized or failed
            continue;
        }

        const next_tex_view = c.wgpuTextureCreateView(surface_texture.texture, null);
        if (next_tex_view == null) {
            continue;
        }

        var encoder_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
        const encoder = c.wgpuDeviceCreateCommandEncoder(gpu_state.device, &encoder_desc);

        var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        color_attachment.view = next_tex_view;
        color_attachment.loadOp = c.WGPULoadOp_Clear;
        color_attachment.storeOp = c.WGPUStoreOp_Store;
        color_attachment.clearValue = c.WGPUColor{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 };

        var pass_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        pass_desc.colorAttachmentCount = 1;
        pass_desc.colorAttachments = &color_attachment;

        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &pass_desc);

        if (current_pipeline) |pl| {
            c.wgpuRenderPassEncoderSetPipeline(pass, pl);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, gpu_state.bind_group, 0, null);
            // Draw fullscreen triangle (3 vertices, 1 instance)
            c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        var cmd_buf_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
        const cmd_buf = c.wgpuCommandEncoderFinish(encoder, &cmd_buf_desc);

        c.wgpuQueueSubmit(gpu_state.queue, 1, &cmd_buf);
        c.wgpuCommandBufferRelease(cmd_buf);
        c.wgpuCommandEncoderRelease(encoder);

        c.wgpuSurfacePresent(gpu_state.surface);
        c.wgpuTextureViewRelease(next_tex_view);
        c.wgpuTextureRelease(surface_texture.texture);
    }
}
