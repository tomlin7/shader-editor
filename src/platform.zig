const std = @import("std");
const builtin = @import("builtin");
const c = @import("gpu.zig").c;

pub var global_char: ?u8 = null;
pub var global_backspace: bool = false;

fn charCallback(window: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
    _ = window;
    if (codepoint >= 32 and codepoint < 128) {
        global_char = @intCast(codepoint);
    }
}

fn keyCallback(window: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    _ = window; _ = scancode; _ = mods;
    if (key == c.GLFW_KEY_BACKSPACE and (action == c.GLFW_PRESS or action == c.GLFW_REPEAT)) {
        global_backspace = true;
    }
}

pub const Window = struct {
    handle: *c.GLFWwindow,

    pub fn init(width: i32, height: i32, title: [*c]const u8) !Window {
        if (c.glfwInit() == 0) return error.GlfwInitFailed;

        c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
        const handle = c.glfwCreateWindow(width, height, title, null, null) orelse return error.WindowCreationFailed;
        
        _ = c.glfwSetCharCallback(handle, charCallback);
        _ = c.glfwSetKeyCallback(handle, keyCallback);

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
