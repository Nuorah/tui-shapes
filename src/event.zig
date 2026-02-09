const model = @import("model.zig");

pub const ProjectCreated = struct {
    id: u64,
    name: []const u8,
};

pub const EventData = union(enum) { project_created: ProjectCreated };

pub const Event = struct {
    timestamp: i64,
    data: EventData,
};
