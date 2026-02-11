const model = @import("model.zig");

pub const ProjectCreated = struct {
    id: u64,
    name: []const u8,
};

pub const ProjectSetStatus = struct {
    id: u64,
    status: model.ProjectStatus,
};

pub const TaskCreated = struct {
    id: u64,
    project_id: u64,
    name: []const u8,
};

pub const TaskSetDone = struct {
    id: u64,
    done: bool,
};

pub const EventData = union(enum) {
    project_created: ProjectCreated,
    project_set_status: ProjectSetStatus,
    task_created: TaskCreated,
    task_set_done: TaskSetDone,
};

pub const Event = struct {
    timestamp: i64,
    data: EventData,
};
