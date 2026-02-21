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
    var file_menu_open: bool = false;
    var wants_compile: bool = false;
    var wants_open: bool = false;
    var open_path_buf: [256]u8 = undefined;
    var open_path_len: usize = 0;

    // Active file tracking
    var active_file: [256]u8 = undefined;
    var active_file_len: usize = "shader.wgsl".len;
    @memcpy(active_file[0..active_file_len], "shader.wgsl");
    var watcher = shader_manager.ShaderWatcher.init(allocator, active_file[0..active_file_len]);

    const start_time = std.time.milliTimestamp();

    var last_w: u32 = 1280;
    var last_h: u32 = 720;

    while (!window.shouldClose()) {
        window.pollEvents();

        const input = platform.consumeInput();

        // Feed input to editor (only when menu/dialog is closed)
        if (!file_menu_open and !wants_open) {
            editor.handleInput(input);
        }

        // Hot-reload from file watcher
        if (watcher.checkModified()) {
            std.debug.print("File changed on disk, reloading...\n", .{});
            const disk_src = std.fs.cwd().readFileAlloc(allocator, active_file[0..active_file_len], 1024 * 1024) catch null;
            if (disk_src) |src| {
                defer allocator.free(src);
                editor.deinit();
                editor = editor_mod.TextEditor.init(allocator, src);
                wants_compile = true;
            }
        }

        // Ctrl+S: compile from editor buffer
        if (input.ctrl_s or wants_compile) {
            wants_compile = false;
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
        const menubar_h: f32 = 30.0;
        const split: f32 = @round(fw * 0.5);
        const error_panel_h: f32 = if (error_len > 0 or show_success) 40.0 else 0.0;
        const editor_h: f32 = fh - menubar_h - error_panel_h;

        // Build UI
        ui_state.beginFrame(&window);

        // Menu bar background (full width)
        ui_state.drawRect(0, 0, fw, menubar_h, .{ 0.12, 0.12, 0.12, 1.0 });
        ui_state.drawRect(0, menubar_h - 1.0, fw, 1.0, .{ 0.25, 0.25, 0.25, 1.0 });

        // File menu button
        {
            const file_btn_w: f32 = 70.0;
            const hovered = ui_state.mouse_x >= 0 and ui_state.mouse_x <= file_btn_w and
                ui_state.mouse_y >= 0 and ui_state.mouse_y <= menubar_h;
            if (hovered or file_menu_open) {
                ui_state.drawRect(0, 0, file_btn_w, menubar_h, .{ 0.18, 0.18, 0.18, 1.0 });
            }
            if (hovered and ui_state.mouse_clicked) {
                file_menu_open = !file_menu_open;
            }
            ui_state.drawText("File", 12.0, 8.0, .{ 0.9, 0.9, 0.9, 1.0 });
        }

        // File indicator
        ui_state.drawText(active_file[0..active_file_len], 250.0, 8.0, .{ 0.5, 0.5, 0.5, 1.0 });
        // Shortcut hint
        ui_state.drawText("Ctrl+S compile", split + 8.0, 8.0, .{ 0.4, 0.4, 0.4, 1.0 });

        // Editor panel (below menubar)
        editor.render(&ui_state, 0, menubar_h, split, editor_h);

        // Error / success panel
        if (error_len > 0) {
            ui_state.drawRect(0, menubar_h + editor_h, split, error_panel_h, .{ 0.15, 0.02, 0.02, 1.0 });
            ui_state.drawText(error_msg[0..error_len], 8.0, menubar_h + editor_h + 12.0, .{ 1.0, 0.3, 0.3, 1.0 });
        } else if (show_success) {
            if (current_time - status_time < 2000) {
                ui_state.drawRect(0, menubar_h + editor_h, split, error_panel_h, .{ 0.02, 0.12, 0.02, 1.0 });
                ui_state.drawText("Compiled OK!", 8.0, menubar_h + editor_h + 12.0, .{ 0.3, 1.0, 0.3, 1.0 });
            } else {
                show_success = false;
            }
        }

        // File menu dropdown (rendered LAST so it appears on top)
        if (file_menu_open) {
            const menu_x: f32 = 0;
            const menu_y: f32 = menubar_h;
            const menu_w: f32 = 300.0;
            const item_h: f32 = 28.0;
            const items = [_][]const u8{ "New", "Open file...", "Save                 Ctrl+S", "Save to file..." };
            const menu_h: f32 = item_h * @as(f32, @floatFromInt(items.len)) + 4.0;

            // Shadow + background
            ui_state.drawRect(menu_x + 2, menu_y + 2, menu_w, menu_h, .{ 0.0, 0.0, 0.0, 0.4 });
            ui_state.drawRect(menu_x, menu_y, menu_w, menu_h, .{ 0.15, 0.15, 0.15, 1.0 });
            ui_state.drawRect(menu_x, menu_y, menu_w, 1.0, .{ 0.25, 0.25, 0.25, 1.0 });

            for (items, 0..) |label, i| {
                const iy = menu_y + 2.0 + @as(f32, @floatFromInt(i)) * item_h;
                const item_hovered = ui_state.mouse_x >= menu_x and ui_state.mouse_x <= menu_x + menu_w and
                    ui_state.mouse_y >= iy and ui_state.mouse_y <= iy + item_h;
                if (item_hovered) {
                    ui_state.drawRect(menu_x, iy, menu_w, item_h, .{ 0.25, 0.4, 0.7, 1.0 });
                }
                ui_state.drawText(label, menu_x + 12.0, iy + 6.0, .{ 0.9, 0.9, 0.9, 1.0 });

                if (item_hovered and ui_state.mouse_clicked) {
                    file_menu_open = false;
                    if (i == 0) {
                        // New
                        editor.deinit();
                        editor = editor_mod.TextEditor.init(allocator, "// New shader\n");
                        active_file_len = 0;
                    } else if (i == 1) {
                        // Open file dialog
                        wants_open = true;
                        open_path_len = 0;
                    } else if (i == 2) {
                        // Save (compile)
                        wants_compile = true;
                    } else if (i == 3) {
                        // Save to file
                        const src = editor.getContent(allocator) catch null;
                        if (src) |content| {
                            defer allocator.free(content);
                            if (active_file_len > 0) {
                                std.fs.cwd().writeFile(.{ .sub_path = active_file[0..active_file_len], .data = content }) catch {};
                                std.debug.print("Saved to {s}\n", .{active_file[0..active_file_len]});
                            } else {
                                std.fs.cwd().writeFile(.{ .sub_path = "shader.wgsl", .data = content }) catch {};
                                std.debug.print("Saved to shader.wgsl\n", .{});
                            }
                        }
                    }
                }
            }

            // Close menu when clicking outside
            if (ui_state.mouse_clicked) {
                const in_menu = ui_state.mouse_x >= 0 and ui_state.mouse_x <= menu_w and
                    ui_state.mouse_y >= menubar_h and ui_state.mouse_y <= menubar_h + menu_h;
                const in_btn = ui_state.mouse_x >= 0 and ui_state.mouse_x <= 70.0 and
                    ui_state.mouse_y >= 0 and ui_state.mouse_y <= menubar_h;
                if (!in_menu and !in_btn) {
                    file_menu_open = false;
                }
            }
        }

        // Open file dialog
        if (wants_open) {
            const dlg_w: f32 = 400.0;
            const dlg_h: f32 = 100.0;
            const dlg_x: f32 = (fw - dlg_w) / 2.0;
            const dlg_y: f32 = (fh - dlg_h) / 2.0;

            // Dim background
            ui_state.drawRect(0, 0, fw, fh, .{ 0.0, 0.0, 0.0, 0.5 });
            // Dialog box
            ui_state.drawRect(dlg_x, dlg_y, dlg_w, dlg_h, .{ 0.15, 0.15, 0.15, 1.0 });
            ui_state.drawRect(dlg_x, dlg_y, dlg_w, 1.0, .{ 0.3, 0.5, 0.8, 1.0 });
            ui_state.drawText("Open file:", dlg_x + 10.0, dlg_y + 10.0, .{ 0.8, 0.8, 0.8, 1.0 });

            // Text input area
            const inp_x = dlg_x + 10.0;
            const inp_y = dlg_y + 35.0;
            const inp_w = dlg_w - 20.0;
            const inp_h: f32 = 24.0;
            ui_state.drawRect(inp_x, inp_y, inp_w, inp_h, .{ 0.08, 0.08, 0.08, 1.0 });
            ui_state.drawRect(inp_x, inp_y + inp_h - 1.0, inp_w, 1.0, .{ 0.3, 0.5, 0.8, 1.0 });

            // Handle typing into the dialog
            if (input.char_input) |ch| {
                if (open_path_len < open_path_buf.len) {
                    open_path_buf[open_path_len] = ch;
                    open_path_len += 1;
                }
            }
            if (input.backspace and open_path_len > 0) {
                open_path_len -= 1;
            }

            if (open_path_len > 0) {
                ui_state.drawText(open_path_buf[0..open_path_len], inp_x + 4.0, inp_y + 4.0, .{ 1.0, 1.0, 1.0, 1.0 });
            }

            // Blinking cursor
            if (@rem(@divFloor(@as(i64, @intCast(std.time.milliTimestamp())), 500), 2) == 0) {
                ui_state.drawRect(inp_x + 4.0 + @as(f32, @floatFromInt(open_path_len)) * 16.0, inp_y + 4.0, 2.0, 16.0, .{ 1.0, 1.0, 1.0, 1.0 });
            }

            // Open button
            const btn_w: f32 = 80.0;
            const btn_h: f32 = 24.0;
            const open_btn_x = dlg_x + dlg_w - btn_w - 130.0;
            const open_btn_y = dlg_y + dlg_h - btn_h - 8.0;
            const cancel_btn_x = dlg_x + dlg_w - btn_w - 40.0;

            // Open
            {
                const hov = ui_state.mouse_x >= open_btn_x and ui_state.mouse_x <= open_btn_x + btn_w and
                    ui_state.mouse_y >= open_btn_y and ui_state.mouse_y <= open_btn_y + btn_h;
                ui_state.drawRect(open_btn_x, open_btn_y, btn_w, btn_h, if (hov) .{ 0.3, 0.5, 0.8, 1.0 } else .{ 0.2, 0.2, 0.2, 1.0 });
                ui_state.drawText("Open", open_btn_x + 8.0, open_btn_y + 4.0, .{ 1.0, 1.0, 1.0, 1.0 });

                if (hov and ui_state.mouse_clicked and open_path_len > 0) {
                    const path = open_path_buf[0..open_path_len];
                    const file_src = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
                    if (file_src) |src| {
                        defer allocator.free(src);
                        editor.deinit();
                        editor = editor_mod.TextEditor.init(allocator, src);
                        @memcpy(active_file[0..open_path_len], path);
                        active_file_len = open_path_len;
                        watcher = shader_manager.ShaderWatcher.init(allocator, active_file[0..active_file_len]);
                        wants_compile = true;
                        std.debug.print("Opened {s}\n", .{path});
                    } else {
                        std.debug.print("Failed to open {s}\n", .{path});
                    }
                    wants_open = false;
                }
            }
            // Cancel
            {
                const hov = ui_state.mouse_x >= cancel_btn_x and ui_state.mouse_x <= cancel_btn_x + btn_w and
                    ui_state.mouse_y >= open_btn_y and ui_state.mouse_y <= open_btn_y + btn_h;
                ui_state.drawRect(cancel_btn_x, open_btn_y, btn_w + 26, btn_h, if (hov) .{ 0.35, 0.2, 0.2, 1.0 } else .{ 0.2, 0.2, 0.2, 1.0 });
                ui_state.drawText("Cancel", cancel_btn_x + 8.0, open_btn_y + 4.0, .{ 1.0, 1.0, 1.0, 1.0 });

                if (hov and ui_state.mouse_clicked) {
                    wants_open = false;
                }
            }

            // Enter to confirm
            if (input.enter and open_path_len > 0) {
                const path = open_path_buf[0..open_path_len];
                const file_src = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch null;
                if (file_src) |src| {
                    defer allocator.free(src);
                    editor.deinit();
                    editor = editor_mod.TextEditor.init(allocator, src);
                    @memcpy(active_file[0..open_path_len], path);
                    active_file_len = open_path_len;
                    watcher = shader_manager.ShaderWatcher.init(allocator, active_file[0..active_file_len]);
                    wants_compile = true;
                    std.debug.print("Opened {s}\n", .{path});
                } else {
                    std.debug.print("Failed to open {s}\n", .{path});
                }
                wants_open = false;
            }
        }

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
