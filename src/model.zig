pub const ProjectStatus = enum {
    draft,
    doing,
    abandonned,
    completed,
};

pub const Project = struct {
    id: u64,
    name: []const u8,
    appetite: ?u32 = null,
    time_left: ?u32 = null,
    status: ProjectStatus = .draft,
};

pub const Task = struct {
    id: u64,
    project_id: u64,
    name: []const u8,
    done: bool = false,
};
