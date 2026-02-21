const std = @import("std");
const builtin = @import("builtin");
const c = @import("gpu.zig").c;

// Input state — consumed each frame
pub var global_char: ?u8 = null;
pub var global_backspace: bool = false;
pub var global_enter: bool = false;
pub var global_ctrl_s: bool = false;
pub var global_arrow_up: bool = false;
pub var global_arrow_down: bool = false;
pub var global_arrow_left: bool = false;
pub var global_arrow_right: bool = false;
pub var global_scroll_y: f32 = 0;

fn scrollCallback(window: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
    _ = window;
    _ = xoffset;
    global_scroll_y += @floatCast(yoffset);
}

fn charCallback(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    _ = window;
    if (codepoint >= 32 and codepoint < 128) {
        global_char = @intCast(codepoint);
    }
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = window;
    _ = scancode;
    const pressed = action == c.GLFW_PRESS or action == c.GLFW_REPEAT;
    if (!pressed) return;

    const ctrl = (mods & c.GLFW_MOD_CONTROL) != 0;

    if (ctrl and key == c.GLFW_KEY_S) {
        global_ctrl_s = true;
        return;
    }

    switch (key) {
        c.GLFW_KEY_BACKSPACE => global_backspace = true,
        c.GLFW_KEY_ENTER => global_enter = true,
        c.GLFW_KEY_UP => global_arrow_up = true,
        c.GLFW_KEY_DOWN => global_arrow_down = true,
        c.GLFW_KEY_LEFT => global_arrow_left = true,
        c.GLFW_KEY_RIGHT => global_arrow_right = true,
        else => {},
    }
}

pub fn consumeInput() InputState {
    const state = InputState{
        .char_input = global_char,
        .backspace = global_backspace,
        .enter = global_enter,
        .ctrl_s = global_ctrl_s,
        .arrow_up = global_arrow_up,
        .arrow_down = global_arrow_down,
        .arrow_left = global_arrow_left,
        .arrow_right = global_arrow_right,
        .scroll_y = global_scroll_y,
    };
    global_char = null;
    global_backspace = false;
    global_enter = false;
    global_ctrl_s = false;
    global_arrow_up = false;
    global_arrow_down = false;
    global_arrow_left = false;
    global_arrow_right = false;
    global_scroll_y = 0;
    return state;
}

pub const InputState = struct {
    char_input: ?u8 = null,
    backspace: bool = false,
    enter: bool = false,
    ctrl_s: bool = false,
    arrow_up: bool = false,
    arrow_down: bool = false,
    arrow_left: bool = false,
    arrow_right: bool = false,
    scroll_y: f32 = 0,
};

pub const Window = struct {
    handle: *c.GLFWwindow,

    pub fn init(width: i32, height: i32, title: [*c]const u8) !Window {
        if (c.glfwInit() == 0) return error.GlfwInitFailed;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        const handle = c.glfwCreateWindow(width, height, title, null, null) orelse return error.WindowCreationFailed;

        _ = c.glfwSetCharCallback(handle, charCallback);
        _ = c.glfwSetKeyCallback(handle, keyCallback);
        _ = c.glfwSetScrollCallback(handle, scrollCallback);

        return Window{ .handle = handle };
    }

    pub fn deinit(self: Window) void {
        c.glfwDestroyWindow(self.handle);
        c.glfwTerminate();
    }

    pub fn createSurface(self: Window, instance: c.WGPUInstance) !c.WGPUSurface {
        var surfaceDesc = std.mem.zeroes(c.WGPUSurfaceDescriptor);

        if (builtin.os.tag == .windows) {
            var hwndDesc = std.mem.zeroes(c.WGPUSurfaceDescriptorFromWindowsHWND);
            hwndDesc.chain.sType = c.WGPUSType_SurfaceDescriptorFromWindowsHWND;
            hwndDesc.hinstance = c.GetModuleHandleW(null);
            hwndDesc.hwnd = c.glfwGetWin32Window(self.handle);
            surfaceDesc.nextInChain = &hwndDesc.chain;
            return c.wgpuInstanceCreateSurface(instance, &surfaceDesc);
        } else if (builtin.os.tag == .macos) {
            const cocoaWindow = c.glfwGetCocoaWindow(self.handle);
            const msgSend_id = @as(fn (?*anyopaque, ?*anyopaque) callconv(.C) ?*anyopaque, @ptrCast(&c.objc_msgSend));
            const msgSend_bool = @as(fn (?*anyopaque, ?*anyopaque, bool) callconv(.C) void, @ptrCast(&c.objc_msgSend));

            const contentView = msgSend_id(cocoaWindow, c.sel_registerName("contentView"));
            msgSend_bool(contentView, c.sel_registerName("setWantsLayer:"), true);
            const layer = msgSend_id(contentView, c.sel_registerName("layer"));

            var metalDesc = std.mem.zeroes(c.WGPUSurfaceDescriptorFromMetalLayer);
            metalDesc.chain.sType = c.WGPUSType_SurfaceDescriptorFromMetalLayer;
            metalDesc.layer = layer;
            surfaceDesc.nextInChain = &metalDesc.chain;
            return c.wgpuInstanceCreateSurface(instance, &surfaceDesc);
        } else {
            // Linux X11
            var x11Desc = std.mem.zeroes(c.WGPUSurfaceDescriptorFromXlibWindow);
            x11Desc.chain.sType = c.WGPUSType_SurfaceDescriptorFromXlibWindow;
            x11Desc.display = c.glfwGetX11Display();
            x11Desc.window = c.glfwGetX11Window(self.handle);
            surfaceDesc.nextInChain = &x11Desc.chain;
            return c.wgpuInstanceCreateSurface(instance, &surfaceDesc);
        }
    }

    pub fn shouldClose(self: Window) bool {
        return c.glfwWindowShouldClose(self.handle) != 0;
    }

    pub fn pollEvents(_: Window) void {
        c.glfwPollEvents();
    }
};
