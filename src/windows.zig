const std = @import("std");
const builtin = @import("builtin");
const zwl = @import("zwl.zig");
const log = std.log.scoped(.zwl);
const Allocator = std.mem.Allocator;

pub const windows = struct {
    pub const kernel32 = @import("windows/kernel32.zig");
    pub const user32 = @import("windows/user32.zig");
    pub const gdi32 = @import("windows/gdi32.zig");
    usingnamespace @import("windows/bits.zig");
};

const classname = std.unicode.utf8ToUtf16LeStringLiteral("ZWL");

pub fn Platform(comptime Parent: anytype) type {
    return struct {
        const Self = @This();
        parent: Parent,
        instance: windows.HINSTANCE,
        revent: ?Parent.Event = null,

        pub fn init(allocator: *Allocator, options: zwl.PlatformOptions) !*Parent {
            var self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const module_handle = windows.kernel32.GetModuleHandleW(null) orelse unreachable;

            const window_class_info = windows.user32.WNDCLASSEXW{
                .style = windows.user32.CS_OWNDC | windows.user32.CS_HREDRAW | windows.user32.CS_VREDRAW,
                .lpfnWndProc = windowProc,
                .cbClsExtra = 0,
                .cbWndExtra = @sizeOf(usize),
                .hInstance = @ptrCast(windows.HINSTANCE, module_handle),
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = classname,
                .hIconSm = null,
            };
            if (windows.user32.RegisterClassExW(&window_class_info) == 0) {
                return error.RegisterClassFailed;
            }

            self.* = .{
                .parent = .{
                    .allocator = allocator,
                    .type = .Windows,
                    .window = undefined,
                    .windows = if (!Parent.settings.single_window) &[0]*Parent.Window{} else undefined,
                },
                .instance = @ptrCast(windows.HINSTANCE, module_handle),
            };

            log.info("Platform Initialized: Windows", .{});
            return @ptrCast(*Parent, self);
        }

        pub fn deinit(self: *Self) void {
            _ = windows.user32.UnregisterClassW(classname, self.instance);
            self.parent.allocator.destroy(self);
        }

        fn windowProc(hwnd: windows.HWND, uMsg: c_uint, wParam: usize, lParam: ?*c_void) callconv(std.os.windows.WINAPI) ?*c_void {
            switch (uMsg) {
                windows.user32.WM_CLOSE => {
                    _ = windows.user32.DestroyWindow(hwnd);
                },
                windows.user32.WM_DESTROY => {
                    var window_opt = @intToPtr(?*Window, @bitCast(usize, windows.user32.GetWindowLongPtrW(hwnd, 0)));
                    if (window_opt) |window| {
                        var platform = @ptrCast(*Self, window.parent.platform);
                        window.handle = null;
                        platform.revent = Parent.Event{ .WindowDestroyed = @ptrCast(*Parent.Window, window) };
                    }
                },
                windows.user32.WM_SIZE => {
                    var window_opt = @intToPtr(?*Window, @bitCast(usize, windows.user32.GetWindowLongPtrW(hwnd, 0)));
                    if (window_opt) |window| {
                        const dim = @bitCast([2]u16, @intCast(u32, @ptrToInt(lParam)));
                        if (dim[0] != window.width or dim[1] != window.height) {
                            var platform = @ptrCast(*Self, window.parent.platform);
                            window.width = dim[0];
                            window.height = dim[1];

                            if (window.render_context.createBitmap(window.width, window.height)) |new_bmp| {
                                window.render_context.bitmap.destroy();
                                window.render_context.bitmap = new_bmp;
                            } else |err| {
                                log.emerg("failed to recreate software framebuffer: {}", .{err});
                            }

                            platform.revent = Parent.Event{ .WindowResized = @ptrCast(*Parent.Window, window) };
                        }
                    }
                },
                windows.user32.WM_PAINT => {
                    var window_opt = @intToPtr(?*Window, @bitCast(usize, windows.user32.GetWindowLongPtrW(hwnd, 0)));
                    if (window_opt) |window| {
                        var platform = @ptrCast(*Self, window.parent.platform);

                        var ps = std.mem.zeroes(windows.user32.PAINTSTRUCT);
                        if (windows.user32.BeginPaint(hwnd, &ps)) |hDC| {
                            defer _ = windows.user32.EndPaint(hwnd, &ps);

                            const hOldBmp = windows.gdi32.SelectObject(
                                window.render_context.memory_dc,
                                window.render_context.bitmap.handle.toGdiObject(),
                            );
                            defer _ = windows.gdi32.SelectObject(window.render_context.memory_dc, hOldBmp);

                            _ = windows.gdi32.BitBlt(
                                hDC,
                                0,
                                0,
                                window.render_context.bitmap.width,
                                window.render_context.bitmap.height,
                                window.render_context.memory_dc,
                                0,
                                0,
                                @enumToInt(windows.gdi32.TernaryRasterOperation.SRCCOPY),
                            );
                        }

                        platform.revent = Parent.Event{ .WindowVBlank = @ptrCast(*Parent.Window, window) };
                    }
                },

                // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-mousemove
                windows.user32.WM_MOUSEMOVE => {
                    var window_opt = @intToPtr(?*Window, @bitCast(usize, windows.user32.GetWindowLongPtrW(hwnd, 0)));
                    if (window_opt) |window| {
                        var platform = @ptrCast(*Self, window.parent.platform);

                        const pos = @bitCast([2]u16, @intCast(u32, @ptrToInt(lParam)));

                        platform.revent = Parent.Event{
                            .MouseMotion = .{
                                .x = @intCast(i16, pos[0]),
                                .y = @intCast(i16, pos[1]),
                            },
                        };
                    }
                },
                windows.user32.WM_LBUTTONDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-lbuttondown
                windows.user32.WM_LBUTTONUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-lbuttonup
                windows.user32.WM_RBUTTONDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-rbuttondown
                windows.user32.WM_RBUTTONUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-rbuttonup
                windows.user32.WM_MBUTTONDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-mbuttondown
                windows.user32.WM_MBUTTONUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-mbuttonup
                => {
                    var window_opt = @intToPtr(?*Window, @bitCast(usize, windows.user32.GetWindowLongPtrW(hwnd, 0)));
                    if (window_opt) |window| {
                        var platform = @ptrCast(*Self, window.parent.platform);

                        const pos = @bitCast([2]u16, @intCast(u32, @ptrToInt(lParam)));

                        var data = zwl.MouseButtonEvent{
                            .x = @intCast(i16, pos[0]),
                            .y = @intCast(i16, pos[1]),
                            .button = switch (uMsg) {
                                windows.user32.WM_LBUTTONDOWN, windows.user32.WM_LBUTTONUP => .left,
                                windows.user32.WM_MBUTTONDOWN, windows.user32.WM_MBUTTONUP => .middle,
                                windows.user32.WM_RBUTTONDOWN, windows.user32.WM_RBUTTONUP => .right,
                                else => unreachable,
                            },
                        };

                        platform.revent = if ((uMsg == windows.user32.WM_LBUTTONDOWN) or (uMsg == windows.user32.WM_MBUTTONDOWN) or (uMsg == windows.user32.WM_RBUTTONDOWN))
                            Parent.Event{ .MouseButtonDown = data }
                        else
                            Parent.Event{ .MouseButtonUp = data };
                    }
                },
                windows.user32.WM_KEYDOWN, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
                windows.user32.WM_KEYUP, // https://docs.microsoft.com/en-us/windows/win32/inputdev/wm-keydown
                => {
                    var window_opt = @intToPtr(?*Window, @bitCast(usize, windows.user32.GetWindowLongPtrW(hwnd, 0)));
                    if (window_opt) |window| {
                        var platform = @ptrCast(*Self, window.parent.platform);

                        var kevent = zwl.KeyEvent{
                            .scancode = @truncate(u8, @ptrToInt(lParam) >> 16), // 16-23 is the OEM scancode
                        };

                        std.debug.print("{}\n", .{kevent});

                        platform.revent = if (uMsg == windows.user32.WM_KEYDOWN)
                            Parent.Event{ .KeyDown = kevent }
                        else
                            Parent.Event{ .KeyUp = kevent };
                    }
                },
                else => {
                    // log.debug("default windows message: 0x{X:0>4}", .{uMsg});
                    return windows.user32.DefWindowProcW(hwnd, uMsg, wParam, lParam);
                },
            }
            return null;
        }

        pub fn waitForEvent(self: *Self) !Parent.Event {
            var msg: windows.user32.MSG = undefined;
            while (true) {
                if (self.revent) |rev| {
                    self.revent = null;
                    return rev;
                }
                const ret = windows.user32.GetMessageW(&msg, null, 0, 0);
                if (ret == -1) unreachable;
                if (ret == 0) return Parent.Event{ .ApplicationTerminated = undefined };
                _ = windows.user32.TranslateMessage(&msg);
                _ = windows.user32.DispatchMessageW(&msg);
            }
        }

        pub fn createWindow(self: *Self, options: zwl.WindowOptions) !*Parent.Window {
            var window = try self.parent.allocator.create(Window);
            errdefer self.parent.allocator.destroy(window);
            try window.init(self, options);
            return @ptrCast(*Parent.Window, window);
        }

        pub const Window = struct {
            const RenderContext = struct {
                const Bitmap = struct {
                    handle: windows.gdi32.HBITMAP,
                    pixels: [*]u32,
                    width: u16,
                    height: u16,

                    fn destroy(self: *@This()) void {
                        _ = windows.gdi32.DeleteObject(self.handle.toGdiObject());
                        self.* = undefined;
                    }
                };

                memory_dc: windows.user32.HDC,
                bitmap: Bitmap,

                fn createBitmap(self: @This(), width: u16, height: u16) !Bitmap {
                    var bmi = std.mem.zeroes(windows.gdi32.BITMAPINFO);
                    bmi.bmiHeader.biSize = @sizeOf(windows.gdi32.BITMAPINFOHEADER);
                    bmi.bmiHeader.biWidth = width;
                    bmi.bmiHeader.biHeight = -@as(i32, height);
                    bmi.bmiHeader.biPlanes = 1;
                    bmi.bmiHeader.biBitCount = 32;
                    bmi.bmiHeader.biCompression = @enumToInt(windows.gdi32.Compression.BI_RGB);

                    var bmp = Bitmap{
                        .width = width,
                        .height = height,
                        .handle = undefined,
                        .pixels = undefined,
                    };

                    bmp.handle = windows.gdi32.CreateDIBSection(
                        self.memory_dc,
                        &bmi,
                        @enumToInt(windows.gdi32.DIBColors.DIB_RGB_COLORS),
                        @ptrCast(**c_void, &bmp.pixels),
                        null,
                        0,
                    ) orelse return error.CreateBitmapError;

                    return bmp;
                }
            };

            parent: Parent.Window,
            handle: ?windows.HWND,
            width: u16,
            height: u16,
            render_context: RenderContext,

            pub fn init(self: *Window, platform: *Self, options: zwl.WindowOptions) !void {
                self.* = .{
                    .parent = .{
                        .platform = @ptrCast(*Parent, platform),
                    },
                    .width = options.width orelse 800,
                    .height = options.height orelse 600,
                    .handle = undefined,
                    .render_context = undefined,
                };

                var namebuf: [512]u8 = undefined;
                var name_allocator = std.heap.FixedBufferAllocator.init(&namebuf);
                const title = try std.unicode.utf8ToUtf16LeWithNull(&name_allocator.allocator, options.title orelse "");
                var style: u32 = 0;
                style += if (options.visible == true) @as(u32, windows.user32.WS_VISIBLE) else 0;
                style += if (options.decorations == true) @as(u32, windows.user32.WS_CAPTION | windows.user32.WS_MAXIMIZEBOX | windows.user32.WS_MINIMIZEBOX | windows.user32.WS_SYSMENU) else 0;
                style += if (options.resizeable == true) @as(u32, windows.user32.WS_SIZEBOX) else 0;

                // mode, transparent...
                // CLIENT_RECT stuff... GetClientRect, GetWindowRect

                var rect = windows.user32.RECT{ .left = 0, .top = 0, .right = self.width, .bottom = self.height };
                _ = windows.user32.AdjustWindowRectEx(&rect, style, 0, 0);
                const x = windows.user32.CW_USEDEFAULT;
                const y = windows.user32.CW_USEDEFAULT;
                const w = rect.right - rect.left;
                const h = rect.bottom - rect.top;
                const handle = windows.user32.CreateWindowExW(0, classname, title, style, x, y, w, h, null, null, platform.instance, null);
                if (handle == null) return error.CreateWindowFailed;
                self.handle = handle.?;
                _ = windows.user32.SetWindowLongPtrW(self.handle.?, 0, @bitCast(isize, @ptrToInt(self)));

                const hDC = windows.user32.getDC(self.handle.?) catch return error.CreateWindowFailed;
                defer _ = windows.user32.releaseDC(self.handle.?, hDC);

                self.render_context = RenderContext{
                    .memory_dc = undefined,
                    .bitmap = undefined,
                };
                self.render_context.memory_dc = windows.gdi32.CreateCompatibleDC(hDC) orelse return error.CreateWindowFailed;
                errdefer _ = windows.gdi32.DeleteDC(self.render_context.memory_dc);

                self.render_context.bitmap = self.render_context.createBitmap(self.width, self.height) catch return error.CreateWindowFailed;
                errdefer self.render_context.bitmap.destroy();
            }

            pub fn deinit(self: *Window) void {
                self.render_context.bitmap.destroy();
                _ = windows.gdi32.DeleteDC(self.render_context.memory_dc);

                if (self.handle) |handle| {
                    _ = windows.user32.SetWindowLongPtrW(handle, 0, 0);
                    _ = windows.user32.DestroyWindow(handle);
                }
                var platform = @ptrCast(*Self, self.parent.platform);
                platform.parent.allocator.destroy(self);
            }

            pub fn configure(self: *Window, options: zwl.WindowOptions) !void {
                return error.Unimplemented;
            }

            pub fn getSize(self: *Window) [2]u16 {
                return [2]u16{ self.width, self.height };
            }

            pub fn mapPixels(self: *Window) !zwl.PixelBuffer {
                var platform = @ptrCast(*Self, self.parent.platform);

                return zwl.PixelBuffer{
                    .data = self.render_context.bitmap.pixels,
                    .width = self.render_context.bitmap.width,
                    .height = self.render_context.bitmap.height,
                };
            }

            pub fn submitPixels(self: *Window, updates: []const zwl.UpdateArea) !void {
                if (self.handle) |handle| {
                    _ = windows.user32.InvalidateRect(
                        handle,
                        null,
                        windows.FALSE, // We paint over *everything*
                    );
                }
            }
        };
    };
}
