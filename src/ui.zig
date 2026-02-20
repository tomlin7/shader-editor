const std = @import("std");
const c = @import("gpu.zig").c;
const platform = @import("platform.zig");
const font = @import("font.zig");

pub const UiQuad = extern struct {
    pos: [2]f32,
    size: [2]f32,
    color: [4]f32,
};

pub const UiState = struct {
    // Input state
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,

    // Keyboard state
    char_input: ?u8 = null,
    backspace_pressed: bool = false,
    
    // UI state
    hot_item: u32 = 0,
    active_item: u32 = 0,
    focused_item: u32 = 0, // persistent focus for text inputs
    select_all: bool = false, // select-all state for text input

    // Rendering
    allocator: std.mem.Allocator,
    quads: std.ArrayListUnmanaged(UiQuad),
    
    pub fn init(allocator: std.mem.Allocator) UiState {
        return .{
            .allocator = allocator,
            .quads = .{},
        };
    }
    
    pub fn deinit(self: *UiState) void {
        self.quads.deinit(self.allocator);
    }
    
    pub fn beginFrame(self: *UiState, w: *platform.Window) void {
        self.quads.clearRetainingCapacity();
        
        var mx: f64 = 0;
        var my: f64 = 0;
        c.glfwGetCursorPos(w.handle, &mx, &my);
        self.mouse_x = @floatCast(mx);
        self.mouse_y = @floatCast(my);
        
        const new_mouse_down = c.glfwGetMouseButton(w.handle, c.GLFW_MOUSE_BUTTON_LEFT) == c.GLFW_PRESS;
        self.mouse_clicked = new_mouse_down and !self.mouse_down;
        self.mouse_down = new_mouse_down;
        
        self.hot_item = 0;
    }
    
    pub fn endFrame(self: *UiState) void {
        // Reset active_item after widgets have had a chance to check it
        if (!self.mouse_down) {
            self.active_item = 0;
        }
        self.char_input = null;
        self.backspace_pressed = false;
    }
    
    pub fn drawRect(self: *UiState, x: f32, y: f32, w: f32, h: f32, color: [4]f32) void {
        self.quads.append(self.allocator, .{
            .pos = .{x, y},
            .size = .{w, h},
            .color = color,
        }) catch {};
    }
    
    pub fn drawText(self: *UiState, text: []const u8, x: f32, y: f32, color: [4]f32) void {
        var cursor_x = x;
        const scale = 2.0; // pixel scale
        
        for (text) |ch| {
            if (ch >= 0 and ch < 128) {
                const glyph = font.font8x8[ch];
                for (glyph, 0..) |row, r| {
                    if (row == 0) continue;
                    var c_bit: u3 = 0;
                    while (true) {
                        if (((row >> c_bit) & 1) != 0) {
                            self.drawRect(
                                cursor_x + @as(f32, @floatFromInt(c_bit)) * scale,
                                y + @as(f32, @floatFromInt(r)) * scale,
                                scale, scale,
                                color
                            );
                        }
                        if (c_bit == 7) break;
                        c_bit += 1;
                    }
                }
            }
            cursor_x += 8.0 * scale;
        }
    }
    
    // Very simple button
    pub fn button(self: *UiState, id: u32, text: []const u8, x: f32, y: f32, w: f32, h: f32) bool {
        const hovered = self.mouse_x >= x and self.mouse_x <= x + w and
                        self.mouse_y >= y and self.mouse_y <= y + h;
                        
        if (hovered) {
            self.hot_item = id;
            if (self.active_item == 0 and self.mouse_down) {
                self.active_item = id;
            }
        }
        
        var bg_color = [4]f32{0.2, 0.2, 0.2, 1.0};
        if (self.hot_item == id) {
            bg_color = if (self.active_item == id) [4]f32{0.4, 0.4, 0.4, 1.0} else [4]f32{0.3, 0.3, 0.3, 1.0};
        }
        
        self.drawRect(x, y, w, h, bg_color);
        self.drawText(text, x + 8.0, y + h/2.0 - 8.0, .{1.0, 1.0, 1.0, 1.0});
        
        return !self.mouse_down and self.hot_item == id and self.active_item == id;
    }
    
    pub fn textInput(self: *UiState, id: u32, buf: []u8, len: *usize, max_len: usize, x: f32, y: f32, w: f32, h: f32) void {
        const hovered = self.mouse_x >= x and self.mouse_x <= x + w and
                        self.mouse_y >= y and self.mouse_y <= y + h;
                        
        if (self.mouse_clicked) {
            if (hovered) {
                if (self.focused_item != id) {
                    self.select_all = true; // select all on first focus
                }
                self.focused_item = id;
            } else if (self.focused_item == id) {
                self.focused_item = 0;
                self.select_all = false;
            }
        }
        if (hovered) {
            self.hot_item = id;
        }
        
        const is_focused = self.focused_item == id;
        
        if (is_focused) {
            if (self.backspace_pressed) {
                if (self.select_all) {
                    len.* = 0;
                    self.select_all = false;
                } else if (len.* > 0) {
                    len.* -= 1;
                }
            } else if (self.char_input) |ch| {
                if (self.select_all) {
                    len.* = 0; // clear on first keystroke
                    self.select_all = false;
                }
                if (len.* < max_len) {
                    buf[len.*] = ch;
                    len.* += 1;
                }
            }
        }
        
        self.drawRect(x, y, w, h, if (is_focused) .{0.1, 0.1, 0.1, 1.0} else .{0.05, 0.05, 0.05, 1.0});
        self.drawRect(x, y, w, 2.0, if (is_focused) .{0.3, 0.8, 0.3, 1.0} else .{0.3, 0.3, 0.3, 1.0}); // underline
        
        // Highlight all text when selected
        if (is_focused and self.select_all and len.* > 0) {
            self.drawRect(x + 8.0, y + h/2.0 - 8.0, @as(f32, @floatFromInt(len.*)) * 16.0, 16.0, .{0.2, 0.4, 0.8, 0.5});
        }
        
        if (len.* > 0) {
            self.drawText(buf[0..len.*], x + 8.0, y + h/2.0 - 8.0, .{1.0, 1.0, 1.0, 1.0});
        }
        
        if (is_focused and @rem(@divFloor(@as(i64, @intCast(std.time.milliTimestamp())), 500), 2) == 0) {
            self.drawRect(x + 8.0 + @as(f32, @floatFromInt(len.*)) * 16.0, y + h/2.0 - 8.0, 8.0, 16.0, .{1.0, 1.0, 1.0, 1.0});
        }
    }
};

const ui_wgsl = 
    \\ struct Uniforms { res: vec2<f32>, pad: vec2<f32> };
    \\ @group(0) @binding(0) var<uniform> unif: Uniforms;
    \\
    \\ struct VertexOutput {
    \\     @builtin(position) pos: vec4<f32>,
    \\     @location(0) color: vec4<f32>,
    \\ };
    \\
    \\ @vertex
    \\ fn vs_main(
    \\     @builtin(vertex_index) vi: u32,
    \\     @location(0) i_pos: vec2<f32>,
    \\     @location(1) i_size: vec2<f32>,
    \\     @location(2) i_color: vec4<f32>
    \\ ) -> VertexOutput {
    \\     var out: VertexOutput;
    \\     
    \\     // Triangle strip positions for a quad:
    \\     // 0: 0,0  1: 0,1  2: 1,0  3: 1,1
    \\     let x = f32(vi & 1u);
    \\     let y = f32((vi & 2u) >> 1u);
    \\     
    \\     // To pixel coordinates
    \\     let px = i_pos.x + x * i_size.x;
    \\     let py = i_pos.y + y * i_size.y;
    \\     
    \\     // Screen resolution 0..w -> -1..1
    \\     let clip_x = (px / unif.res.x) * 2.0 - 1.0;
    \\     let clip_y = 1.0 - (py / unif.res.y) * 2.0; // Y down
    \\
    \\     out.pos = vec4<f32>(clip_x, clip_y, 0.0, 1.0);
    \\     out.color = i_color;
    \\     return out;
    \\ }
    \\
    \\ @fragment
    \\ fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    \\     return in.color;
    \\ }
;

pub const UiRenderer = struct {
    pipeline: c.WGPURenderPipeline,
    bind_group: c.WGPUBindGroup,
    uniform_buf: c.WGPUBuffer,
    instance_buf: c.WGPUBuffer,
    instance_cap: usize,
    
    pub fn init(device: c.WGPUDevice, format: c.WGPUTextureFormat) !UiRenderer {
        // Uniform buffer
        var unif_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
        unif_desc.usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst;
        unif_desc.size = 16;
        const uniform_buf = c.wgpuDeviceCreateBuffer(device, &unif_desc);
        
        // Instance buffer (capacity for 10000 quads)
        const cap: usize = 10000;
        var inst_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
        inst_desc.usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst;
        inst_desc.size = cap * @sizeOf(UiQuad);
        const instance_buf = c.wgpuDeviceCreateBuffer(device, &inst_desc);
        
        var wgsl_desc = std.mem.zeroes(c.WGPUShaderModuleWGSLDescriptor);
        wgsl_desc.chain.sType = c.WGPUSType_ShaderModuleWGSLDescriptor;
        wgsl_desc.code = ui_wgsl.ptr;
        var sm_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
        sm_desc.nextInChain = &wgsl_desc.chain;
        const shader = c.wgpuDeviceCreateShaderModule(device, &sm_desc);
        defer c.wgpuShaderModuleRelease(shader);
        
        var bgl_entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        bgl_entry.binding = 0;
        bgl_entry.visibility = c.WGPUShaderStage_Vertex;
        bgl_entry.buffer.type = c.WGPUBufferBindingType_Uniform;
        bgl_entry.buffer.minBindingSize = 16;
        var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        bgl_desc.entryCount = 1;
        bgl_desc.entries = &bgl_entry;
        const bgl = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc);
        
        var bg_entry = std.mem.zeroes(c.WGPUBindGroupEntry);
        bg_entry.binding = 0;
        bg_entry.buffer = uniform_buf;
        bg_entry.size = 16;
        var bg_desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
        bg_desc.layout = bgl;
        bg_desc.entryCount = 1;
        bg_desc.entries = &bg_entry;
        const bg = c.wgpuDeviceCreateBindGroup(device, &bg_desc);
        
        var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        pl_desc.bindGroupLayoutCount = 1;
        pl_desc.bindGroupLayouts = &bgl;
        const pl = c.wgpuDeviceCreatePipelineLayout(device, &pl_desc);
        defer c.wgpuPipelineLayoutRelease(pl);
        
        var attribs = [_]c.WGPUVertexAttribute{
            std.mem.zeroes(c.WGPUVertexAttribute),
            std.mem.zeroes(c.WGPUVertexAttribute),
            std.mem.zeroes(c.WGPUVertexAttribute)
        };
        attribs[0].format = c.WGPUVertexFormat_Float32x2; attribs[0].offset = 0; attribs[0].shaderLocation = 0;
        attribs[1].format = c.WGPUVertexFormat_Float32x2; attribs[1].offset = 8; attribs[1].shaderLocation = 1;
        attribs[2].format = c.WGPUVertexFormat_Float32x4; attribs[2].offset = 16; attribs[2].shaderLocation = 2;
        
        var vb_layout = std.mem.zeroes(c.WGPUVertexBufferLayout);
        vb_layout.arrayStride = @sizeOf(UiQuad);
        vb_layout.stepMode = c.WGPUVertexStepMode_Instance;
        vb_layout.attributeCount = 3;
        vb_layout.attributes = &attribs;
        
        var rp_desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
        rp_desc.layout = pl;
        rp_desc.vertex.module = shader;
        rp_desc.vertex.entryPoint = "vs_main";
        rp_desc.vertex.bufferCount = 1;
        rp_desc.vertex.buffers = &vb_layout;
        rp_desc.primitive.topology = c.WGPUPrimitiveTopology_TriangleStrip;
        rp_desc.primitive.cullMode = c.WGPUCullMode_None;
        rp_desc.multisample.count = 1;
        rp_desc.multisample.mask = 0xFFFFFFFF;
        rp_desc.multisample.alphaToCoverageEnabled = 0;
        
        var blend = std.mem.zeroes(c.WGPUBlendState);
        blend.color.operation = c.WGPUBlendOperation_Add;
        blend.color.srcFactor = c.WGPUBlendFactor_SrcAlpha;
        blend.color.dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha;
        blend.alpha.operation = c.WGPUBlendOperation_Add;
        blend.alpha.srcFactor = c.WGPUBlendFactor_One;
        blend.alpha.dstFactor = c.WGPUBlendFactor_Zero;
        
        var target = std.mem.zeroes(c.WGPUColorTargetState);
        target.format = format;
        target.blend = &blend;
        target.writeMask = c.WGPUColorWriteMask_All;
        
        var frag = std.mem.zeroes(c.WGPUFragmentState);
        frag.module = shader;
        frag.entryPoint = "fs_main";
        frag.targetCount = 1;
        frag.targets = &target;
        rp_desc.fragment = &frag;
        
        const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &rp_desc);
        
        return UiRenderer{
            .pipeline = pipeline,
            .bind_group = bg,
            .uniform_buf = uniform_buf,
            .instance_buf = instance_buf,
            .instance_cap = cap,
        };
    }
    
    pub fn render(self: *UiRenderer, state: *const UiState, queue: c.WGPUQueue, pass: c.WGPURenderPassEncoder, w: f32, h: f32) void {
        if (state.quads.items.len == 0) return;
        
        const res = [4]f32{w, h, 0, 0};
        c.wgpuQueueWriteBuffer(queue, self.uniform_buf, 0, &res, 16);
        
        const count = @min(state.quads.items.len, self.instance_cap);
        c.wgpuQueueWriteBuffer(queue, self.instance_buf, 0, state.quads.items.ptr, count * @sizeOf(UiQuad));
        
        c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.instance_buf, 0, count * @sizeOf(UiQuad));
        c.wgpuRenderPassEncoderDraw(pass, 4, @intCast(count), 0, 0);
    }
};
