const std = @import("std");

const model = @import("model.zig");
const event = @import("event.zig");

const ProjectStorage = event.ProjectStorage;
const TaskStorage = event.TaskStorage;
const Storages = event.Storages;

const TextElement = struct {
    x_pct: u8,
    text: []const u8,
    color: ?u8 = null,
    selected_color: ?u8 = null,
    bold: bool = false,
    same_row: bool = false,
};

pub const Section = struct {
    elements: [128]TextElement = undefined,
    selected: ?usize = null,
    len: usize = 0,
    input: ?Input = null,

    pub fn add(self: *Section, element: TextElement) void {
        self.elements[self.len] = element;
        self.len += 1;
    }
};

pub const Input = struct {
    buf: [128]u21 = undefined,
    len: usize = 0,
    prompt: []const u8,
};

pub const BenchView = struct {
    header: Section,
    body: Section,
    footer: Section,

    pub fn init() BenchView {
        var header = Section{};
        const body = Section{ .selected = 0 };
        var footer = Section{};
        const title = TextElement{
            .bold = true,
            .color = 32,
            .text = "Bench",
            .x_pct = 50,
        };

        const footer_add = TextElement{
            .bold = true,
            .color = 37,
            .text = "a) Add",
            .x_pct = 1,
        };
        const footer_select = TextElement{
            .bold = true,
            .color = 37,
            .text = "enter) Select",
            .x_pct = 21,
            .same_row = true,
        };
        const footer_quit = TextElement{
            .bold = true,
            .color = 37,
            .text = "q) Quit",
            .x_pct = 41,
            .same_row = true,
        };

        header.add(title);
        footer.add(footer_add);
        footer.add(footer_select);
        footer.add(footer_quit);

        return BenchView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }

    pub fn refreshBody(self: *BenchView, scratch: *std.heap.ArenaAllocator, project_storage: *ProjectStorage) void {
        _ = scratch.reset(.retain_capacity);
        const allocator = scratch.allocator();
        self.body.len = 0;
        var it = project_storage.entities.iterator();
        while (it.next()) |entry| {
            const status_str: []const u8 = switch (entry.value_ptr.status) {
                .draft => "[draft]      |",
                .doing => "[doing]      |",
                .abandonned => "[abandonned] |",
                .completed => "[completed]  |",
            };
            const color: u8 = switch (entry.value_ptr.status) {
                .draft => 37,
                .doing => 33,
                .abandonned => 90,
                .completed => 32,
            };
            const text = std.fmt.allocPrint(allocator, "{s} {s}", .{ status_str, entry.value_ptr.name }) catch continue;
            self.body.add(.{
                .bold = true,
                .color = color,
                .selected_color = 31,
                .text = text,
                .x_pct = 2,
            });
            self.body.selected = if (self.body.len > 0) 0 else null;
        }
    }
};

pub const ProjectView = struct {
    header: Section,
    body: Section,
    footer: Section,
    current_project_id: u64 = 0,

    pub fn init() ProjectView {
        var header = Section{};
        const body = Section{ .selected = 0 };
        var footer = Section{};

        const title = TextElement{
            .bold = true,
            .color = 33,
            .text = "Project",
            .x_pct = 50,
        };

        const status = TextElement{
            .bold = true,
            .color = 90,
            .text = "",
            .x_pct = 50,
        };

        const footer_add = TextElement{
            .bold = true,
            .color = 37,
            .text = "a) Add",
            .x_pct = 1,
        };
        const footer_start = TextElement{
            .bold = true,
            .color = 37,
            .text = "enter) Start task",
            .x_pct = 21,
            .same_row = true,
        };
        const footer_back = TextElement{
            .bold = true,
            .color = 37,
            .text = "b) Back",
            .x_pct = 41,
            .same_row = true,
        };
        const footer_toggle = TextElement{
            .bold = true,
            .color = 37,
            .text = "x) Toggle done",
            .x_pct = 61,
            .same_row = true,
        };
        const footer_status = TextElement{
            .bold = true,
            .color = 37,
            .text = "s) Status",
            .x_pct = 81,
            .same_row = true,
        };

        header.add(title);
        header.add(status);
        footer.add(footer_add);
        footer.add(footer_back);
        footer.add(footer_start);
        footer.add(footer_toggle);
        footer.add(footer_status);

        return ProjectView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }

    pub fn refreshHeader(self: *ProjectView, project_storage: *ProjectStorage) void {
        if (project_storage.entities.get(self.current_project_id)) |project| {
            self.header.elements[0].text = project.name;
            const status_text: []const u8 = switch (project.status) {
                .draft => "[draft]",
                .doing => "[doing]",
                .abandonned => "[abandonned]",
                .completed => "[completed]",
            };
            const status_color: u8 = switch (project.status) {
                .draft => 37,
                .doing => 33,
                .abandonned => 90,
                .completed => 32,
            };
            self.header.elements[1].text = status_text;
            self.header.elements[1].color = status_color;
        }
    }

    pub fn refreshBody(
        self: *ProjectView,
        scratch: *std.heap.ArenaAllocator,
        task_storage: *TaskStorage,
        project_id: u64,
    ) void {
        _ = scratch.reset(.retain_capacity);
        const allocator = scratch.allocator();
        self.body.len = 0;
        var it = task_storage.entities.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.project_id == project_id) {
                const prefix: []const u8 = if (entry.value_ptr.done) "[x] " else "[ ] ";
                const text = std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, entry.value_ptr.name }) catch continue;
                self.body.add(.{
                    .bold = true,
                    .color = if (entry.value_ptr.done) 90 else 32,
                    .selected_color = 31,
                    .text = text,
                    .x_pct = 2,
                });
            }
        }
        self.body.selected = if (self.body.len > 0) 0 else null;
    }
};

pub const TaskView = struct {
    header: Section,
    body: Section,
    footer: Section,
    current_task_id: u64 = 0,

    pub fn init() TaskView {
        var header = Section{};
        var body = Section{};
        var footer = Section{};

        const project_title = TextElement{
            .bold = true,
            .color = 33,
            .text = "",
            .x_pct = 50,
        };
        const task_title = TextElement{
            .bold = true,
            .color = 36,
            .text = "",
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

        header.add(project_title);
        header.add(task_title);
        body.add(countdown);
        footer.add(footer_stop);

        return TaskView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }

    pub fn refreshHeader(
        self: *TaskView,
        storages:Storages,
        project_id: u64,
    ) void {
        if (storages.projects.entities.get(project_id)) |project| {
            self.header.elements[0].text = project.name;
        }
        if (storages.tasks.entities.get(self.current_task_id)) |task| {
            self.header.elements[1].text = task.name;
        }
    }
};

const View = union(enum) {
    bench: *BenchView,
    project: *ProjectView,
    task: *TaskView,
};

pub const Views = struct {
    bench: *BenchView,
    project: *ProjectView,
    task: *TaskView,
    active_view: View,
    scratch: std.heap.ArenaAllocator,

    pub fn init(backing: std.mem.Allocator, bench: *BenchView, project: *ProjectView, task: *TaskView) Views {
        return .{
            .bench = bench,
            .project = project,
            .task = task,
            .active_view = .{ .bench = bench },
            .scratch = std.heap.ArenaAllocator.init(backing),
        };
    }

    pub fn deinit(self: *Views) void {
        self.scratch.deinit();
    }
};
