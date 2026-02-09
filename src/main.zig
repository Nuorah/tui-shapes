const std = @import("std");

const ArrayList = @import("collections").ArrayList;
const editor = @import("editor");

const db = @import("db.zig");
const model = @import("model.zig");

const ShapeStorage = db.Storage(model.Shape);

const TerminalSize = struct {
    cols: u16,
    rows: u16,
};

fn getTerminalSize(fd: std.posix.fd_t) TerminalSize {
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(fd, std.posix.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc == 0) {
        return .{
            .cols = wsz.col,
            .rows = wsz.row,
        };
    }
    // fallback
    return .{ .cols = 80, .rows = 24 };
}

// =====
// Input
// =====

const Key = union(enum) {
    char: u21,
    ctrl: u8,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    escape,
    enter,
    backspace,
    delete,
    home,
    end,
    page_up,
    page_down,
    tab,
    none,
};

fn readKey(reader: anytype) !Key {
    var buf: [1]u8 = undefined;
    reader.readSliceAll(&buf) catch |err| {
        if (err == error.EndOfStream) return .none;
        return err;
    };

    const c = buf[0];

    if (c == '\x1b') {
        const seq0 = reader.takeByte() catch return .escape;
        if (seq0 == '[') {
            const seq1 = reader.takeByte() catch return .escape;
            return switch (seq1) {
                'A' => .arrow_up,
                'B' => .arrow_down,
                'C' => .arrow_right,
                'D' => .arrow_left,
                'H' => .home,
                'F' => .end,
                '1'...'9' => blk: {
                    const seq2 = reader.takeByte() catch break :blk .escape;
                    if (seq2 == '~') {
                        break :blk switch (seq1) {
                            '1' => .home,
                            '3' => .delete,
                            '4' => .end,
                            '5' => .page_up,
                            '6' => .page_down,
                            '7' => .home,
                            '8' => .end,
                            else => .escape,
                        };
                    }
                    break :blk .escape;
                },
                else => .escape,
            };
        } else if (seq0 == 'O') {
            const seq1 = reader.takeByte() catch return .escape;
            return switch (seq1) {
                'H' => .home,
                'F' => .end,
                else => .escape,
            };
        }
        return .escape;
    }

    if (c == '\r') return .enter;
    if (c == '\t') return .tab;
    if (c == 127) return .backspace;
    if (c < 32) return .{ .ctrl = c + 'a' - 1 };
    // at the end of readKey, instead of just returning .{ .char = c }
    if (c < 0x80) {
        return .{ .char = c };
    } else if (c & 0xE0 == 0xC0) {
        // 2-byte sequence
        const c2 = reader.takeByte() catch return .none;
        const codepoint = (@as(u21, c & 0x1F) << 6) | (c2 & 0x3F);
        return .{ .char = codepoint };
    } else if (c & 0xF0 == 0xE0) {
        // 3-byte sequence
        const c2 = reader.takeByte() catch return .none;
        const c3 = reader.takeByte() catch return .none;
        const codepoint = (@as(u21, c & 0x0F) << 12) | (@as(u21, c2 & 0x3F) << 6) | (c3 & 0x3F);
        return .{ .char = codepoint };
    } else if (c & 0xF8 == 0xF0) {
        // 4-byte sequence
        const c2 = reader.takeByte() catch return .none;
        const c3 = reader.takeByte() catch return .none;
        const c4 = reader.takeByte() catch return .none;
        const codepoint = (@as(u21, c & 0x07) << 18) | (@as(u21, c2 & 0x3F) << 12) | (@as(u21, c3 & 0x3F) << 6) | (c4 & 0x3F);
        return .{ .char = codepoint };
    }
    return .none; // invalid utf-8 lead byte
}

// =====
// Action
// =====
const Action = union(enum) {
    move_up,
    move_down,
    move_left,
    move_right,
    select,
    quit,
    none,
};

// =====
// Update
// =====

fn update(
    action: Action,
    views: *Views,
    should_quit: *bool,
) void {
    if (action == .quit) {
        should_quit.* = true;
        return;
    }

    switch (action) {
        .move_up => {
            switch (views.active_view) {
                .pit => {
                    if (views.active_view.pit.body.selected) |*s| {
                        s.* = (s.* -% 1) % views.active_view.pit.body.len;
                    }
                },
                .shape => {},
                .task => {},
            }
        },
        .move_down => {
            switch (views.active_view) {
                .pit => {
                    if (views.active_view.pit.body.selected) |*s| {
                        s.* = (s.* +% 1) % views.active_view.pit.body.len;
                    }
                },
                .shape => {},
                .task => {},
            }
        },
        .move_left => {},
        .move_right => {},
        .select => {
            switch (views.active_view) {
                .pit => {
                    views.active_view = .{ .shape = views.shape };
                },
                .shape => {
                    views.active_view = .{ .task = views.task };
                },
                .task => {},
            }
        },
        .none => {},
        else => {},
    }
}

// =====
// Render
// =====

const TextElement = struct {
    x_pct: u8,
    text: []const u8,
    color: ?u8 = null,
    selected_color: ?u8 = null,
    bold: bool = false,
    same_row: bool = false,
};

const Section = struct {
    elements: [64]TextElement = undefined,
    selected: ?usize = null,
    len: usize = 0,
    input: bool = false,

    pub fn add(self: *Section, element: TextElement) void {
        self.elements[self.len] = element;
        self.len += 1;
    }
};

const PitView = struct {
    header: Section,
    body: Section,
    footer: Section,

    pub fn init() PitView {
        var header = Section{};
        var body = Section{ .selected = 0 };
        var footer = Section{};
        const title = TextElement{
            .bold = true,
            .color = 32,
            .text = "Pit",
            .x_pct = 50,
        };
        const mock_elem = TextElement{
            .bold = true,
            .color = 32,
            .selected_color = 31,
            .text = " - Tui for shape up for a solo dev",
            .x_pct = 2,
        };
        const mock_elem_2 = TextElement{
            .bold = true,
            .color = 32,
            .selected_color = 31,
            .text = " - Make a whole database",
            .x_pct = 2,
        };
        const footer_quit = TextElement{
            .bold = true,
            .color = 37,
            .text = "q) Quit",
            .x_pct = 1,
        };
        const footer_title = TextElement{
            .bold = true,
            .color = 36,
            .text = "Footer",
            .x_pct = 50,
            .same_row = true,
        };

        header.add(title);
        footer.add(footer_quit);
        footer.add(footer_title);
        body.add(mock_elem);
        body.add(mock_elem_2);

        return PitView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }

    pub fn refreshBody(self: *PitView, shape_storage: *ShapeStorage) void {
        self.body.len = 0;
        var it = shape_storage.entities.iterator();
        while (it.next()) |entry| {
            self.body.add(.{
                .bold = true,
                .color = 32,
                .selected_color = 31,
                .text = entry.value_ptr.name,
                .x_pct = 2,
            });
        }
        self.body.selected = if (self.body.len > 0) 0 else null;
    }
};

const ShapeView = struct {
    header: Section,
    body: Section,
    footer: Section,

    pub fn init() ShapeView {
        var header = Section{};
        var body = Section{ .selected = 0 };
        var footer = Section{};

        const title = TextElement{
            .bold = true,
            .color = 33,
            .text = "Shape",
            .x_pct = 50,
        };

        const mock_task_1 = TextElement{
            .bold = true,
            .color = 32,
            .selected_color = 31,
            .text = "[ ] init project with basic raw mode",
            .x_pct = 2,
        };
        const mock_task_2 = TextElement{
            .bold = true,
            .color = 32,
            .selected_color = 31,
            .text = "[x] make it compile",
            .x_pct = 2,
        };

        const footer_back = TextElement{
            .bold = true,
            .color = 37,
            .text = "b) Back",
            .x_pct = 1,
        };
        const footer_start = TextElement{
            .bold = true,
            .color = 37,
            .text = "enter) Start task",
            .x_pct = 25,
            .same_row = true,
        };
        const footer_title = TextElement{
            .bold = true,
            .color = 36,
            .text = "Tui for shape up for a solo dev",
            .x_pct = 50,
            .same_row = true,
        };

        header.add(title);
        body.add(mock_task_1);
        body.add(mock_task_2);
        footer.add(footer_back);
        footer.add(footer_start);
        footer.add(footer_title);

        return ShapeView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }
};

const TaskView = struct {
    header: Section,
    body: Section,
    footer: Section,

    pub fn init() TaskView {
        var header = Section{};
        var body = Section{};
        var footer = Section{};

        const shape_title = TextElement{
            .bold = true,
            .color = 33,
            .text = "Tui for shape up for a solo dev",
            .x_pct = 50,
        };
        const task_title = TextElement{
            .bold = true,
            .color = 36,
            .text = "init project with basic raw mode",
            .x_pct = 50,
        };

        const countdown = TextElement{
            .bold = true,
            .color = 32,
            .text = "25:00",
            .x_pct = 50,
        };

        const footer_stop = TextElement{
            .bold = true,
            .color = 37,
            .text = "s) Stop",
            .x_pct = 1,
        };
        const footer_doc = TextElement{
            .bold = true,
            .color = 37,
            .text = "d) View doc",
            .x_pct = 20,
            .same_row = true,
        };
        const footer_status = TextElement{
            .bold = true,
            .color = 32,
            .text = "RUNNING",
            .x_pct = 50,
            .same_row = true,
        };

        header.add(shape_title);
        header.add(task_title);
        body.add(countdown);
        footer.add(footer_stop);
        footer.add(footer_doc);
        footer.add(footer_status);

        return TaskView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }
};

const View = union(enum) {
    pit: *PitView,
    shape: *ShapeView,
    task: *TaskView,
};

const Views = struct {
    pit: *PitView,
    shape: *ShapeView,
    task: *TaskView,
    active_view: View,

    pub fn init(pit: *PitView, shape: *ShapeView, task: *TaskView) Views {
        return .{
            .pit = pit,
            .shape = shape,
            .task = task,
            .active_view = .{ .pit = pit },
        };
    }
};

const Layout = struct {
    start_pct: u8,
    start_row: u16 = 0,
    gap: u16,
    current_row: u16 = 0,

    pub fn init(start_pct: u8, gap: u16) Layout {
        return .{
            .gap = gap,
            .start_pct = start_pct,
        };
    }

    pub fn next(self: *Layout) u16 {
        const row = self.current_row;
        self.current_row += self.gap;
        return row;
    }

    fn reset(self: *Layout, term_rows: u16) void {
        self.start_row = @max(1, @as(u16, self.start_pct) * term_rows / 100);
        self.current_row = self.start_row;
    }
};

const Layouts = struct {
    header: Layout,
    body: Layout,
    footer: Layout,

    pub fn init() Layouts {
        return Layouts{
            .header = Layout.init(5, 1),
            .body = Layout.init(15, 1),
            .footer = Layout.init(95, 1),
        };
    }

    pub fn reset(self: *Layouts, term_rows: u16) void {
        self.header.reset(term_rows);
        self.body.reset(term_rows);
        self.footer.reset(term_rows);
    }
};

fn renderSection(
    writer: *std.Io.Writer,
    section: Section,
    layout: *Layout,
    term_size: TerminalSize,
) !void {
    var row = layout.current_row;
    for (section.elements[0..section.len], 0..) |el, i| {
        if (!el.same_row) {
            row = layout.next();
        }
        const col = @max(1, @as(u16, el.x_pct) * term_size.cols / 100);
        if (el.bold) try writer.writeAll("\x1b[1m");
        if (el.selected_color) |c| {
            if (section.selected) |s| {
                if (i == s) {
                    try writer.print("\x1b[{d}m", .{c});
                }
            }
        } else if (el.color) |c| try writer.print("\x1b[{d}m", .{c});
        try writer.print("\x1b[{d};{d}H{s}", .{ row, col, el.text });
        try writer.writeAll("\x1b[0m");
    }
}

fn render(
    writer: *std.Io.Writer,
    views: *Views,
    term_size: TerminalSize,
    layouts: *Layouts,
) !void {
    try writer.writeAll("\x1b[H\x1b[2J");

    switch (views.active_view) {
        .pit => |v| {
            try renderSection(writer, v.header, &layouts.header, term_size);
            try renderSection(writer, v.body, &layouts.body, term_size);
            try renderSection(writer, v.footer, &layouts.footer, term_size);
        },
        .shape => |v| {
            try renderSection(writer, v.header, &layouts.header, term_size);
            try renderSection(writer, v.body, &layouts.body, term_size);
            try renderSection(writer, v.footer, &layouts.footer, term_size);
        },
        .task => |v| {
            try renderSection(writer, v.header, &layouts.header, term_size);
            try renderSection(writer, v.body, &layouts.body, term_size);
            try renderSection(writer, v.footer, &layouts.footer, term_size);
        },
    }

    try writer.flush();
}

fn keyToAction(key: Key, views: *Views) Action {
    if (key == .char and key.char == 'q') {
        return .quit;
    }
    return switch (views.active_view) {
        .pit => switch (key) {
            .char => |c| switch (c) {
                else => .none,
            },
            .ctrl => |c| switch (c) {
                else => .none,
            },
            .arrow_up => .move_up,
            .arrow_down => .move_down,
            .arrow_left => .move_left,
            .arrow_right => .move_right,
            .enter => .select,
            .none => .none,
            else => .none,
        },
        .shape => switch (key) {
            .arrow_up => .move_up,
            .arrow_down => .move_down,
            .arrow_left => .move_left,
            .arrow_right => .move_right,
            .enter => .select,
            .none => .none,
            else => .none,
        },
        .task => switch (key) {
            .enter => .select,
            .none => .none,
            else => .none,
        },
    };
}

pub fn main() u8 {
    var stdout = std.fs.File.stdout();
    var stdout_writer_buffer: [128]u8 = undefined;
    var stdout_writer = stdout.writer(&stdout_writer_buffer);

    var stderr = std.fs.File.stderr();
    var stderr_writer_buffer: [128]u8 = undefined;
    var stderr_writer = stderr.writer(&stderr_writer_buffer);

    run(&stdout_writer.interface, &stderr_writer.interface) catch |err| {
        switch (err) {
            else => {
                stderr_writer.interface.print("Error: {}", .{err}) catch return 1;
                stderr_writer.interface.flush() catch return 1;
                return 1;
            },
        }
    };
    return 0;
}

pub fn run(stdout_writer: *std.Io.Writer, stderr_writer: *std.Io.Writer) !void {
    _ = stderr_writer;

    const main_allocator = std.heap.c_allocator;

    var shape_storage = ShapeStorage.init(main_allocator);

    var database = try db.Database.init("db.wal");
    defer database.deinit();

    var startup_arena = std.heap.ArenaAllocator.init(main_allocator);

    try database.loadAllEvents(main_allocator, startup_arena.allocator(), &shape_storage);
    startup_arena.deinit();

    // seed if empty
    if (shape_storage.entities.count() == 0) {
        try database.appendEvent(main_allocator, main_allocator, .{
            .timestamp = std.time.timestamp(),
            .data = .{ .shape_created = .{
                .id = std.crypto.random.int(u64),
                .name = " - Tui for shape up for a solo dev",
            } },
        }, &shape_storage);

        try database.appendEvent(main_allocator, main_allocator, .{
            .timestamp = std.time.timestamp(),
            .data = .{ .shape_created = .{
                .id = std.crypto.random.int(u64),
                .name = " - Make a whole database",
            } },
        }, &shape_storage);
    }

    const stdin = std.fs.File.stdin();
    var stdin_reader_buffer: [128]u8 = undefined;
    var stdin_reader = stdin.reader(&stdin_reader_buffer);

    const original = try std.posix.tcgetattr(stdin.handle);
    defer std.posix.tcsetattr(stdin.handle, .FLUSH, original) catch {};

    var raw = original;
    raw.iflag.BRKINT = false;
    raw.iflag.INPCK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.oflag.OPOST = false;
    raw.cflag.CSIZE = .CS8;
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 1;
    try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

    // block SIGWINCH so it goes to signalfd instead of interrupting us
    var mask = std.os.linux.sigemptyset();
    std.os.linux.sigaddset(&mask, std.posix.SIG.WINCH);
    _ = std.os.linux.sigprocmask(std.os.linux.SIG.BLOCK, &mask, null);

    // create an fd that becomes readable when SIGWINCH fires
    const sig_fd = std.os.linux.signalfd(-1, &mask, 0);
    defer std.posix.close(@intCast(sig_fd));

    var should_quit = false;

    try stdout_writer.writeAll("\x1b[?1049h");
    try stdout_writer.writeAll("\x1b[?25l");

    defer stdout_writer.flush() catch {};
    defer stdout_writer.writeAll("\x1b[?25h") catch {};
    defer stdout_writer.writeAll("\x1b[?1049l") catch {};

    var pit = PitView.init();
    var shape = ShapeView.init();
    var task = TaskView.init();

    var views = Views.init(&pit, &shape, &task);

    var term_size = getTerminalSize(stdin.handle);

    var layouts = Layouts.init();
    layouts.reset(term_size.rows);

    // initial render
    try render(stdout_writer, &views, term_size, &layouts);

    while (!should_quit) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = @intCast(sig_fd), .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = std.posix.poll(&fds, -1) catch |err| {
            if (err == error.Interrupted) {} else return err;
        };

        var needs_render = false;

        // terminal resized
        if (fds[1].revents & std.posix.POLL.IN != 0) {
            var buf: [@sizeOf(std.os.linux.signalfd_siginfo)]u8 = undefined;
            _ = std.posix.read(@intCast(sig_fd), &buf) catch {};

            term_size = getTerminalSize(stdin.handle);
            needs_render = true;
        }

        // keyboard input
        if (fds[0].revents & std.posix.POLL.IN != 0) {
            const key = try readKey(&stdin_reader.interface);
            const action = keyToAction(key, &views);
            update(action, &views, &should_quit);
            needs_render = true;
        }

        if (needs_render) {
            layouts.reset(term_size.rows);
            switch (views.active_view) {
                .pit => {},
                .shape => {},
                .task => {},
            }
            try render(stdout_writer, &views, term_size, &layouts);
        }
    }
}
