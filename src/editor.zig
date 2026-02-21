const std = @import("std");
const platform = @import("platform.zig");
const ui_mod = @import("ui.zig");

const Line = std.ArrayListUnmanaged(u8);

pub const TextEditor = struct {
    lines: std.ArrayListUnmanaged(Line),
    cursor_row: usize = 0,
    cursor_col: usize = 0,
    scroll_y: usize = 0,
    scroll_x: usize = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, initial_content: []const u8) TextEditor {
        var ed = TextEditor{
            .lines = .{},
            .allocator = allocator,
        };
        var start: usize = 0;
        for (initial_content, 0..) |ch, i| {
            if (ch == '\n') {
                ed.appendLine(initial_content[start..i]);
                start = i + 1;
            }
        }
        ed.appendLine(initial_content[start..]);
        return ed;
    }

    fn appendLine(self: *TextEditor, content: []const u8) void {
        var line = Line{};
        line.appendSlice(self.allocator, content) catch {};
        self.lines.append(self.allocator, line) catch {};
    }

    pub fn deinit(self: *TextEditor) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    pub fn handleInput(self: *TextEditor, input: platform.InputState) void {
        // Mouse scroll
        if (input.scroll_y != 0) {
            const delta: i32 = @intFromFloat(-input.scroll_y * 3.0);
            const new_scroll = @as(i32, @intCast(self.scroll_y)) + delta;
            if (new_scroll < 0) {
                self.scroll_y = 0;
            } else {
                self.scroll_y = @intCast(new_scroll);
            }
        }

        if (input.arrow_up) {
            if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                self.clampCol();
            }
        }
        if (input.arrow_down) {
            if (self.cursor_row + 1 < self.lines.items.len) {
                self.cursor_row += 1;
                self.clampCol();
            }
        }
        if (input.arrow_left) {
            if (self.cursor_col > 0) {
                self.cursor_col -= 1;
            } else if (self.cursor_row > 0) {
                self.cursor_row -= 1;
                self.cursor_col = self.currentLineLen();
            }
        }
        if (input.arrow_right) {
            if (self.cursor_col < self.currentLineLen()) {
                self.cursor_col += 1;
            } else if (self.cursor_row + 1 < self.lines.items.len) {
                self.cursor_row += 1;
                self.cursor_col = 0;
            }
        }
        if (input.enter) {
            self.splitLine();
        }
        if (input.backspace) {
            self.deleteBack();
        }
        if (input.char_input) |ch| {
            self.insertChar(ch);
        }
    }

    fn currentLineLen(self: *TextEditor) usize {
        if (self.cursor_row < self.lines.items.len) {
            return self.lines.items[self.cursor_row].items.len;
        }
        return 0;
    }

    fn clampCol(self: *TextEditor) void {
        const len = self.currentLineLen();
        if (self.cursor_col > len) self.cursor_col = len;
    }

    fn insertChar(self: *TextEditor, ch: u8) void {
        if (self.cursor_row >= self.lines.items.len) return;
        var line = &self.lines.items[self.cursor_row];
        line.insert(self.allocator, self.cursor_col, ch) catch return;
        self.cursor_col += 1;
    }

    fn deleteBack(self: *TextEditor) void {
        if (self.cursor_row >= self.lines.items.len) return;
        if (self.cursor_col > 0) {
            var line = &self.lines.items[self.cursor_row];
            _ = line.orderedRemove(self.cursor_col - 1);
            self.cursor_col -= 1;
        } else if (self.cursor_row > 0) {
            const prev_len = self.lines.items[self.cursor_row - 1].items.len;
            const current_items = self.lines.items[self.cursor_row].items;
            self.lines.items[self.cursor_row - 1].appendSlice(self.allocator, current_items) catch {};
            self.lines.items[self.cursor_row].deinit(self.allocator);
            _ = self.lines.orderedRemove(self.cursor_row);
            self.cursor_row -= 1;
            self.cursor_col = prev_len;
        }
    }

    fn splitLine(self: *TextEditor) void {
        if (self.cursor_row >= self.lines.items.len) return;
        var new_line = Line{};
        const old_line = &self.lines.items[self.cursor_row];
        if (self.cursor_col < old_line.items.len) {
            new_line.appendSlice(self.allocator, old_line.items[self.cursor_col..]) catch {};
            old_line.shrinkRetainingCapacity(self.cursor_col);
        }
        self.lines.insert(self.allocator, self.cursor_row + 1, new_line) catch {};
        self.cursor_row += 1;
        self.cursor_col = 0;
    }

    pub fn getContent(self: *const TextEditor, allocator: std.mem.Allocator) ![]u8 {
        var total: usize = 0;
        for (self.lines.items) |line| {
            total += line.items.len + 1;
        }
        const buf = try allocator.alloc(u8, total);
        var pos: usize = 0;
        for (self.lines.items) |line| {
            @memcpy(buf[pos .. pos + line.items.len], line.items);
            pos += line.items.len;
            buf[pos] = '\n';
            pos += 1;
        }
        return buf;
    }

    pub fn render(self: *TextEditor, ui_state: *ui_mod.UiState, panel_x: f32, panel_y: f32, panel_w: f32, panel_h: f32) void {
        const char_w: f32 = 16.0;
        const char_h: f32 = 16.0;
        const line_h: f32 = 20.0;
        const gutter_w: f32 = 60.0;
        const pad: f32 = 6.0;
        const text_area_x = panel_x + gutter_w;
        const text_area_w = panel_w - gutter_w;

        // Backgrounds
        ui_state.drawRect(panel_x, panel_y, panel_w, panel_h, .{ 0.08, 0.08, 0.08, 1.0 });
        ui_state.drawRect(panel_x, panel_y, gutter_w, panel_h, .{ 0.06, 0.06, 0.06, 1.0 });

        // Auto-scroll to keep cursor visible
        const visible_lines = @as(usize, @intFromFloat(@max(1.0, panel_h / line_h)));
        if (self.cursor_row < self.scroll_y) {
            self.scroll_y = self.cursor_row;
        } else if (self.cursor_row >= self.scroll_y + visible_lines) {
            self.scroll_y = self.cursor_row - visible_lines + 1;
        }

        // Horizontal auto-scroll
        const visible_cols = @as(usize, @intFromFloat(@max(1.0, text_area_w / char_w))) -| 2;
        if (self.cursor_col < self.scroll_x) {
            self.scroll_x = self.cursor_col;
        } else if (self.cursor_col >= self.scroll_x + visible_cols) {
            self.scroll_x = self.cursor_col - visible_cols + 1;
        }

        // Draw visible lines
        var row: usize = self.scroll_y;
        var y_pos: f32 = panel_y + 2.0;
        while (row < self.lines.items.len and y_pos + line_h <= panel_y + panel_h) : ({
            row += 1;
            y_pos += line_h;
        }) {
            // Line number
            var num_buf: [8]u8 = undefined;
            const num_str = std.fmt.bufPrint(&num_buf, "{d: >4}", .{row + 1}) catch "????";
            ui_state.drawText(num_str, panel_x + 4.0, y_pos + 2.0, .{ 0.4, 0.4, 0.4, 1.0 });

            // Current line highlight
            if (row == self.cursor_row) {
                ui_state.drawRect(text_area_x, y_pos, text_area_w, line_h, .{ 1.0, 1.0, 1.0, 0.04 });
            }

            // Line text (clipped to visible area via scroll_x)
            const line = self.lines.items[row].items;
            if (line.len > self.scroll_x) {
                const visible_text = line[self.scroll_x..];
                const max_chars = @min(visible_text.len, visible_cols + 2);
                if (max_chars > 0) {
                    ui_state.drawText(visible_text[0..max_chars], text_area_x + pad, y_pos + 2.0, .{ 0.9, 0.9, 0.9, 1.0 });
                }
            }

            // Cursor
            if (row == self.cursor_row) {
                if (@rem(@divFloor(@as(i64, @intCast(std.time.milliTimestamp())), 500), 2) == 0) {
                    if (self.cursor_col >= self.scroll_x) {
                        const cx = text_area_x + pad + @as(f32, @floatFromInt(self.cursor_col - self.scroll_x)) * char_w;
                        if (cx < panel_x + panel_w - 4.0) {
                            ui_state.drawRect(cx, y_pos + 2.0, 2.0, char_h, .{ 1.0, 1.0, 1.0, 1.0 });
                        }
                    }
                }
            }
        }

        // Draw ~ markers for empty lines below content (vim-style)
        while (y_pos + line_h <= panel_y + panel_h) : (y_pos += line_h) {
            ui_state.drawText("~", panel_x + 4.0, y_pos + 2.0, .{ 0.25, 0.25, 0.25, 1.0 });
        }

        // Gutter separator
        ui_state.drawRect(panel_x + gutter_w - 1.0, panel_y, 1.0, panel_h, .{ 0.2, 0.2, 0.2, 1.0 });

        // Vertical scrollbar
        const total_lines = self.lines.items.len;
        if (total_lines > visible_lines) {
            const sb_x = panel_x + panel_w - 8.0;
            const sb_h = panel_h;
            const thumb_h = @max(20.0, sb_h * @as(f32, @floatFromInt(visible_lines)) / @as(f32, @floatFromInt(total_lines)));
            const thumb_y = panel_y + (sb_h - thumb_h) * @as(f32, @floatFromInt(self.scroll_y)) / @as(f32, @floatFromInt(total_lines - visible_lines));

            // Track
            ui_state.drawRect(sb_x, panel_y, 8.0, sb_h, .{ 0.1, 0.1, 0.1, 1.0 });
            // Thumb
            ui_state.drawRect(sb_x + 1.0, thumb_y, 6.0, thumb_h, .{ 0.3, 0.3, 0.3, 1.0 });
        }

        // Horizontal scrollbar
        if (self.scroll_x > 0) {
            // Find max line length
            var max_len: usize = 0;
            for (self.lines.items) |line| {
                if (line.items.len > max_len) max_len = line.items.len;
            }
            if (max_len > visible_cols) {
                const hsb_y = panel_y + panel_h - 8.0;
                const hsb_w = text_area_w;
                const hthumb_w = @max(20.0, hsb_w * @as(f32, @floatFromInt(visible_cols)) / @as(f32, @floatFromInt(max_len)));
                const hthumb_x = text_area_x + (hsb_w - hthumb_w) * @as(f32, @floatFromInt(self.scroll_x)) / @as(f32, @floatFromInt(max_len - visible_cols));

                ui_state.drawRect(text_area_x, hsb_y, hsb_w, 8.0, .{ 0.1, 0.1, 0.1, 1.0 });
                ui_state.drawRect(hthumb_x, hsb_y + 1.0, hthumb_w, 6.0, .{ 0.3, 0.3, 0.3, 1.0 });
            }
        }
    }
};
