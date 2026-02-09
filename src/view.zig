const db = @import("db.zig");
const model = @import("model.zig");

const ProjectStorage = db.Storage(model.Project);

const TextElement = struct {
    x_pct: u8,
    text: []const u8,
    color: ?u8 = null,
    selected_color: ?u8 = null,
    bold: bool = false,
    same_row: bool = false,
};

pub const Section = struct {
    elements: [64]TextElement = undefined,
    selected: ?usize = null,
    len: usize = 0,
    input: ?Input = null,

    pub fn add(self: *Section, element: TextElement) void {
        self.elements[self.len] = element;
        self.len += 1;
    }
};

pub const Input  = struct {
    buf: [128]u21 = undefined,
    len:usize = 0,
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

    pub fn refreshBody(self: *BenchView, project_storage: *ProjectStorage) void {
        self.body.len = 0;
        var it = project_storage.entities.iterator();
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

pub const ProjectView = struct {
    header: Section,
    body: Section,
    footer: Section,

    pub fn init() ProjectView {
        var header = Section{};
        var body = Section{ .selected = 0 };
        var footer = Section{};

        const title = TextElement{
            .bold = true,
            .color = 33,
            .text = "Project",
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
            .text = "Footer",
            .x_pct = 50,
            .same_row = true,
        };

        header.add(title);
        body.add(mock_task_1);
        body.add(mock_task_2);
        footer.add(footer_back);
        footer.add(footer_start);
        footer.add(footer_title);

        return ProjectView{
            .header = header,
            .body = body,
            .footer = footer,
        };
    }
};

pub const TaskView = struct {
    header: Section,
    body: Section,
    footer: Section,

    pub fn init() TaskView {
        var header = Section{};
        var body = Section{};
        var footer = Section{};

        const project_title = TextElement{
            .bold = true,
            .color = 33,
            .text = "A task",
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

        header.add(project_title);
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
    bench: *BenchView,
    project: *ProjectView,
    task: *TaskView,
};

pub const Views = struct {
    bench: *BenchView,
    project: *ProjectView,
    task: *TaskView,
    active_view: View,

    pub fn init(bench: *BenchView, project: *ProjectView, task: *TaskView) Views {
        return .{
            .bench = bench,
            .project = project,
            .task = task,
            .active_view = .{ .bench = bench },
        };
    }
};
