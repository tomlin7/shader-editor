const std = @import("std");
const platform = @import("platform.zig");
const gpu = @import("gpu.zig");
const shader_manager = @import("shader_manager.zig");
const ui = @import("ui.zig");
const editor_mod = @import("editor.zig");
const c = gpu.c;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window = try platform.Window.init(1280, 720, "shader editor");
    defer window.deinit();

    var gpu_state = try gpu.init(&window);

    const format = c.WGPUTextureFormat_BGRA8Unorm;

    var ui_state = ui.UiState.init(allocator);
    defer ui_state.deinit();

    var ui_renderer = try ui.UiRenderer.init(gpu_state.device, format);

    // Load initial shader file content into editor
    const initial_source = std.fs.cwd().readFileAlloc(allocator, "shader.wgsl", 1024 * 1024) catch |err| blk: {
        std.debug.print("Could not read shader.wgsl: {any}\n", .{err});
        break :blk allocator.dupe(u8, "// Write your WGSL shader here\n") catch "";
    };
    defer allocator.free(initial_source);

    var editor = editor_mod.TextEditor.init(allocator, initial_source);
    defer editor.deinit();

    // Compile initial shader
    var current_pipeline: ?c.WGPURenderPipeline = null;
    const initial_result = shader_manager.compileFromSource(allocator, gpu_state.device, gpu_state.bind_group_layout, initial_source, format);
    if (initial_result.pipeline) |pl| {
        current_pipeline = pl;
        std.debug.print("Initial shader compiled successfully.\n", .{});
    } else {
        std.debug.print("Initial shader compilation failed.\n", .{});
    }

    // Error state
    var error_msg: [1024]u8 = undefined;
    var error_len: usize = 0;
    var show_success: bool = false;
    var status_time: i64 = 0;

    const start_time = std.time.milliTimestamp();

    var last_w: u32 = 1280;
    var last_h: u32 = 720;

    while (!window.shouldClose()) {
        window.pollEvents();

        const input = platform.consumeInput();

        // Feed input to editor
        editor.handleInput(input);

        // Ctrl+S: compile from editor buffer
        if (input.ctrl_s) {
            const source = editor.getContent(allocator) catch null;
            if (source) |src| {
                defer allocator.free(src);
                std.debug.print("Compiling shader ({d} bytes)...\n", .{src.len});

                const result = shader_manager.compileFromSource(allocator, gpu_state.device, gpu_state.bind_group_layout, src, format);
                if (result.pipeline) |pl| {
                    if (current_pipeline) |old_pl| {
                        c.wgpuRenderPipelineRelease(old_pl);
                    }
                    current_pipeline = pl;
                    error_len = 0;
                    show_success = true;
                    status_time = std.time.milliTimestamp();
                    std.debug.print("Shader compiled successfully.\n", .{});
                } else {
                    if (result.error_msg) |emsg| {
                        const copy_len = @min(emsg.len, error_msg.len);
                        @memcpy(error_msg[0..copy_len], emsg[0..copy_len]);
                        error_len = copy_len;
                    }
                    show_success = false;
                    status_time = std.time.milliTimestamp();
                    std.debug.print("Shader compilation failed.\n", .{});
                }
            }
        }

        // Time uniform
        const current_time = std.time.milliTimestamp();
        const t = @as(f32, @floatFromInt(current_time - start_time)) / 1000.0;

        var win_w: i32 = 0;
        var win_h: i32 = 0;
        c.glfwGetFramebufferSize(window.handle, &win_w, &win_h);
        if (win_w <= 0 or win_h <= 0) {
            std.Thread.sleep(16_000_000);
            continue;
        }
        const uw: u32 = @intCast(win_w);
        const uh: u32 = @intCast(win_h);

        // Reconfigure surface on resize
        if (uw != last_w or uh != last_h) {
            gpu_state.reconfigureSurface(uw, uh);
            last_w = uw;
            last_h = uh;
        }

        const fw: f32 = @floatFromInt(win_w);
        const fh: f32 = @floatFromInt(win_h);

        // Layout: left half = editor, right half = preview
        const split: f32 = @round(fw * 0.5);
        const error_panel_h: f32 = if (error_len > 0 or show_success) 40.0 else 0.0;
        const editor_h: f32 = fh - error_panel_h;

        // Build UI
        ui_state.beginFrame(&window);

        // Editor panel
        editor.render(&ui_state, 0, 0, split, editor_h);

        // Error / success panel
        if (error_len > 0) {
            ui_state.drawRect(0, editor_h, split, error_panel_h, .{ 0.15, 0.02, 0.02, 1.0 });
            ui_state.drawText(error_msg[0..error_len], 8.0, editor_h + 12.0, .{ 1.0, 0.3, 0.3, 1.0 });
        } else if (show_success) {
            // Auto-hide after 2 seconds
            if (current_time - status_time < 2000) {
                ui_state.drawRect(0, editor_h, split, error_panel_h, .{ 0.02, 0.12, 0.02, 1.0 });
                ui_state.drawText("Compiled OK!", 8.0, editor_h + 12.0, .{ 0.3, 1.0, 0.3, 1.0 });
            } else {
                show_success = false;
            }
        }

        // Status bar hint (rendered over shader preview area)
        ui_state.drawText("Ctrl+S to compile", split + 8.0, fh - 20.0, .{ 0.3, 0.3, 0.3, 1.0 });

        ui_state.endFrame();

        // Uniforms
        const uniforms = gpu.Uniforms{
            .time = t,
            .padding = 0,
            .resolution = .{ fw - split, fh },
        };
        c.wgpuQueueWriteBuffer(gpu_state.queue, gpu_state.uniform_buf, 0, &uniforms, @sizeOf(gpu.Uniforms));

        // === Render Pass ===
        var surface_texture = std.mem.zeroes(c.WGPUSurfaceTexture);
        c.wgpuSurfaceGetCurrentTexture(gpu_state.surface, &surface_texture);
        if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_Success or surface_texture.texture == null) {
            std.Thread.sleep(16_000_000);
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

        // Draw shader preview in right half using viewport
        if (current_pipeline) |pl| {
            const split_i: u32 = @intFromFloat(split);
            const right_w: u32 = @as(u32, @intCast(win_w)) - split_i;
            c.wgpuRenderPassEncoderSetViewport(pass, split, 0, @floatFromInt(right_w), fh, 0.0, 1.0);
            c.wgpuRenderPassEncoderSetScissorRect(pass, split_i, 0, right_w, @intCast(win_h));
            c.wgpuRenderPassEncoderSetPipeline(pass, pl);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, gpu_state.bind_group, 0, null);
            c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        }

        // Reset viewport to full window for UI overlay
        c.wgpuRenderPassEncoderSetViewport(pass, 0, 0, fw, fh, 0.0, 1.0);
        c.wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, @intCast(win_w), @intCast(win_h));

        // Draw UI (editor text, panels, etc.)
        ui_renderer.render(&ui_state, gpu_state.queue, pass, fw, fh);

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
