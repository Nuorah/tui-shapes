const std = @import("std");

const db = @import("db.zig");
const model = @import("model.zig");
const event = @import("event.zig");
const view_module = @import("view.zig");
const BenchView = view_module.BenchView;
const Input = view_module.Input;
const Section = view_module.Section;
const ProjectView = view_module.ProjectView;
const TaskView = view_module.TaskView;
const Views = view_module.Views;
const Database = db.Database;

const ProjectStorage = db.Storage(model.Project);
const TaskStorage = db.Storage(model.Task);

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
    insert_char: u21,
    select,
    back,
    add,
    quit,
    escape,
    backspace,
    toggle_done,
    cycle_status,
    none,
};

// =====
// Update
// =====
fn update(
    allocator: std.mem.Allocator,
    action: Action,
    views: *Views,
    should_quit: *bool,
    database: *Database,
    project_storage: *ProjectStorage,
    task_storage: *TaskStorage,
) !void {
    if (action == .quit) {
        should_quit.* = true;
        return;
    }

    switch (views.active_view) {
        .bench => |p| {
            if (p.footer.input) |*in| {
                switch (action) {
                    .select => {
                        if (in.len == 0) {
                            p.footer.input = null;
                            return;
                        }
                        // encode u21 buf back to utf8 for storage
                        var name_buf: [1024]u8 = undefined;
                        var name_len: usize = 0;
                        var utf8_buf: [4]u8 = undefined;
                        for (in.buf[0..in.len]) |cp| {
                            const n = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                            @memcpy(name_buf[name_len..][0..n], utf8_buf[0..n]);
                            name_len += n;
                        }
                        const evt = event.Event{
                            .timestamp = std.time.timestamp(),
                            .data = .{
                                .project_created = .{
                                    .name = name_buf[0..name_len],
                                    .id = std.crypto.random.int(u64),
                                },
                            },
                        };

                        try database.appendEvent(allocator, allocator, evt, project_storage, task_storage);
                        p.refreshBody(&views.scratch, project_storage);
                        p.footer.input = null;
                    },
                    .escape => {
                        p.footer.input = null;
                    },
                    .insert_char => |c| {
                        if (in.len < in.buf.len) {
                            in.buf[in.len] = c;
                            in.len += 1;
                        }
                    },
                    .backspace => {
                        if (in.len > 0) {
                            in.len -= 1;
                        }
                    },
                    else => {},
                }
            } else {
                switch (action) {
                    .move_up => {
                        if (p.body.selected) |*se| {
                            se.* = (se.* -% 1) % p.body.len;
                        }
                    },
                    .move_down => {
                        if (p.body.selected) |*se| {
                            se.* = (se.* +% 1) % p.body.len;
                        }
                    },
                    .select => {
                        if (p.body.selected) |sel| {
                            // need project id from storage — iterate to find nth entry
                            var it = project_storage.entities.iterator();
                            var idx: usize = 0;
                            while (it.next()) |entry| {
                                if (idx == sel) {
                                    views.project.current_project_id = entry.key_ptr.*;
                                    views.project.header.elements[0].text = entry.value_ptr.name;
                                    break;
                                }
                                idx += 1;
                            }
                            views.project.refreshHeader(project_storage);
                            views.project.refreshBody(&views.scratch, task_storage, views.project.current_project_id);
                            views.active_view = .{ .project = views.project };
                        }
                    },
                    .add => {
                        p.footer.input = Input{
                            .prompt = "Add project: ",
                        };
                    },
                    .cycle_status => {
                        if (p.body.selected) |sel| {
                            var it = project_storage.entities.iterator();
                            var idx: usize = 0;
                            while (it.next()) |entry| {
                                if (idx == sel) {
                                    const id = entry.key_ptr.*;
                                    const current = entry.value_ptr.status;
                                    const status_fields: u8 = @intCast(@typeInfo(model.ProjectStatus).@"enum".fields.len);
                                    const next_status: model.ProjectStatus = @enumFromInt(
                                        (@as(u8, @intFromEnum(current)) +% 1) % status_fields,
                                    );
                                    const evt = event.Event{
                                        .timestamp = std.time.timestamp(),
                                        .data = .{
                                            .project_set_status = .{
                                                .id = id,
                                                .status = next_status,
                                            },
                                        },
                                    };
                                    try database.appendEvent(allocator, allocator, evt, project_storage, task_storage);
                                    p.refreshBody(&views.scratch, project_storage);
                                    p.body.selected = sel;
                                    break;
                                }
                                idx += 1;
                            }
                        }
                    },
                    else => {},
                }
            }
        },
        .project => |p| {
            if (p.footer.input) |*in| {
                switch (action) {
                    .select => {
                        if (in.len == 0) {
                            p.footer.input = null;
                            return;
                        }
                        // encode u21 buf back to utf8 for storage
                        var name_buf: [1024]u8 = undefined;
                        var name_len: usize = 0;
                        var utf8_buf: [4]u8 = undefined;
                        for (in.buf[0..in.len]) |cp| {
                            const n = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
                            @memcpy(name_buf[name_len..][0..n], utf8_buf[0..n]);
                            name_len += n;
                        }
                        const evt = event.Event{
                            .timestamp = std.time.timestamp(),
                            .data = .{
                                .task_created = .{
                                    .name = name_buf[0..name_len],
                                    .id = std.crypto.random.int(u64),
                                    .project_id = p.current_project_id,
                                },
                            },
                        };

                        try database.appendEvent(allocator, allocator, evt, project_storage, task_storage);
                        p.refreshBody(&views.scratch, task_storage, p.current_project_id);
                        p.footer.input = null;
                    },
                    .escape => {
                        p.footer.input = null;
                    },
                    .insert_char => |c| {
                        if (in.len < in.buf.len) {
                            in.buf[in.len] = c;
                            in.len += 1;
                        }
                    },
                    .backspace => {
                        if (in.len > 0) {
                            in.len -= 1;
                        }
                    },
                    else => {},
                }
            } else {
                switch (action) {
                    .move_up => {
                        if (p.body.selected) |*se| {
                            se.* = (se.* -% 1) % p.body.len;
                        }
                    },
                    .move_down => {
                        if (p.body.selected) |*se| {
                            se.* = (se.* +% 1) % p.body.len;
                        }
                    },
                    .select => {
                        if (p.body.selected) |sel| {
                            var it = task_storage.entities.iterator();
                            var idx: usize = 0;
                            while (it.next()) |entry| {
                                if (entry.value_ptr.project_id == p.current_project_id) {
                                    if (idx == sel) {
                                        views.task.current_task_id = entry.key_ptr.*;
                                        break;
                                    }
                                    idx += 1;
                                }
                            }
                            views.task.refreshHeader(project_storage, task_storage, p.current_project_id);
                            views.active_view = .{ .task = views.task };
                        }
                    },
                    .back => {
                        views.bench.refreshBody(&views.scratch, project_storage);
                        views.active_view = .{ .bench = views.bench };
                    },
                    .add => {
                        p.footer.input = Input{
                            .prompt = "Add Task: ",
                        };
                    },
                    .toggle_done => {
                        if (p.body.selected) |sel| {
                            var it = task_storage.entities.iterator();
                            var idx: usize = 0;
                            while (it.next()) |entry| {
                                if (entry.value_ptr.project_id == p.current_project_id) {
                                    if (idx == sel) {
                                        const evt = event.Event{
                                            .timestamp = std.time.timestamp(),
                                            .data = .{
                                                .task_set_done = .{
                                                    .id = entry.key_ptr.*,
                                                    .done = !entry.value_ptr.done,
                                                },
                                            },
                                        };
                                        try database.appendEvent(allocator, allocator, evt, project_storage, task_storage);
                                        p.refreshBody(&views.scratch, task_storage, p.current_project_id);
                                        p.body.selected = sel;
                                        break;
                                    }
                                    idx += 1;
                                }
                            }
                        }
                    },
                    .cycle_status => {
                        const id = p.current_project_id;
                        const project = project_storage.entities.get(id) orelse return;
                        const status_fields: u8 = @intCast(@typeInfo(model.ProjectStatus).@"enum".fields.len);
                        const next_status: model.ProjectStatus = @enumFromInt(
                            (@as(u8, @intFromEnum(project.status)) +% 1) % status_fields,
                        );
                        const evt = event.Event{
                            .timestamp = std.time.timestamp(),
                            .data = .{
                                .project_set_status = .{
                                    .id = id,
                                    .status = next_status,
                                },
                            },
                        };
                        try database.appendEvent(allocator, allocator, evt, project_storage, task_storage);
                        p.refreshHeader(project_storage);
                    },
                    else => {},
                }
            }
        },
        .task => switch (action) {
            .back => {
                views.project.refreshBody(&views.scratch, task_storage, views.project.current_project_id);
                views.project.refreshHeader(project_storage);
                views.active_view = .{ .project = views.project };
            },
            else => {},
        },
    }
}

// =====
// Render
// =====

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

fn renderInput(
    writer: *std.Io.Writer,
    input: Input,
    layout: *Layout,
    term_size: TerminalSize,
) !void {
    const row = layout.next();
    const col = @max(1, @as(u16, 2) * term_size.cols / 100);

    try writer.print("\x1b[1m\x1b[36m\x1b[{d};{d}H{s}", .{ row, col, input.prompt });

    var char_count: u16 = 0;
    var utf8_buf: [4]u8 = undefined;
    for (input.buf[0..input.len]) |cp| {
        const n = std.unicode.utf8Encode(cp, &utf8_buf) catch continue;
        try writer.writeAll(utf8_buf[0..n]);
        char_count += 1;
    }

    try writer.writeAll("\x1b[0m");

    const cursor_col = col + @as(u16, @intCast(input.prompt.len)) + char_count;
    try writer.print("\x1b[{d};{d}H\x1b[7m \x1b[0m", .{ row, cursor_col });
}

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
        .bench => |v| {
            try renderSection(writer, v.header, &layouts.header, term_size);
            try renderSection(writer, v.body, &layouts.body, term_size);
            if (v.footer.input) |i| {
                try renderInput(writer, i, &layouts.footer, term_size);
            } else {
                try renderSection(writer, v.footer, &layouts.footer, term_size);
            }
        },
        .project => |v| {
            try renderSection(writer, v.header, &layouts.header, term_size);
            try renderSection(writer, v.body, &layouts.body, term_size);
            if (v.footer.input) |i| {
                try renderInput(writer, i, &layouts.footer, term_size);
            } else {
                try renderSection(writer, v.footer, &layouts.footer, term_size);
            }
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
    return switch (views.active_view) {
        .bench => |p| {
            if (p.footer.input != null) {
                return switch (key) {
                    .char => |c| .{ .insert_char = c },
                    .backspace => .backspace,
                    .enter => .select,
                    .escape => .escape,
                    .none => .none,
                    else => .none,
                };
            }
            return switch (key) {
                .char => |c| switch (c) {
                    'q' => .quit,
                    'a' => .add,
                    's' => .cycle_status,
                    else => .none,
                },
                .ctrl => .none,
                .arrow_up => .move_up,
                .arrow_down => .move_down,
                .arrow_left => .move_left,
                .arrow_right => .move_right,
                .enter => .select,
                .none => .none,
                else => .none,
            };
        },
        .project => |p| {
            if (p.footer.input != null) {
                return switch (key) {
                    .char => |c| .{ .insert_char = c },
                    .backspace => .backspace,
                    .enter => .select,
                    .escape => .escape,
                    .none => .none,
                    else => .none,
                };
            } else {
                return switch (key) {
                    .char => |c| switch (c) {
                        'q' => .quit,
                        'a' => .add,
                        'b' => .back,
                        's' => .cycle_status,
                        'x' => .toggle_done,
                        else => .none,
                    },
                    .arrow_up => .move_up,
                    .arrow_down => .move_down,
                    .arrow_left => .move_left,
                    .arrow_right => .move_right,
                    .enter => .select,
                    .escape => .escape,
                    .none => .none,
                    else => .none,
                };
            }
        },
        .task => switch (key) {
            .char => |c| switch (c) {
                'q' => .quit,
                's' => .back,
                else => .none,
            },
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
                stderr_writer.interface.print("Error: {}\n", .{err}) catch return 1;
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

    var project_storage = ProjectStorage.init(main_allocator);
    var task_storage = TaskStorage.init(main_allocator);

    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const wal_path = try std.fmt.allocPrint(main_allocator, "{s}/.local/share/bench/db.wal", .{home});

    std.fs.makeDirAbsolute(std.fmt.allocPrint(main_allocator, "{s}/.local/share/bench", .{home}) catch unreachable) catch |err| {
        if (err != error.PathAlreadyExists) return err;
    };

    var init_scratch = std.heap.ArenaAllocator.init(main_allocator);
    var database = try db.Database.init(init_scratch.allocator(), wal_path);
    init_scratch.deinit();
    defer database.deinit();

    var startup_arena = std.heap.ArenaAllocator.init(main_allocator);

    try database.loadAllEvents(main_allocator, startup_arena.allocator(), &project_storage, &task_storage);
    startup_arena.deinit();

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

    var bench_view = BenchView.init();
    var project_view = ProjectView.init();
    var task_view = TaskView.init();

    var views = Views.init(main_allocator, &bench_view, &project_view, &task_view);
    bench_view.refreshBody(&views.scratch, &project_storage);

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
            try update(main_allocator, action, &views, &should_quit, &database, &project_storage, &task_storage);
            needs_render = true;
        }

        if (needs_render) {
            layouts.reset(term_size.rows);
            switch (views.active_view) {
                .bench => {},
                .project => {},
                .task => {},
            }
            try render(stdout_writer, &views, term_size, &layouts);
        }
    }
}
