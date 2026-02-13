const std = @import("std");
const model = @import("model.zig");
const db = @import("db");

pub const Event = db.Event(EventData);
pub const ProjectStorage = db.Storage(u64, model.Project);
pub const TaskStorage = db.Storage(u64, model.Task);


pub const Storages = struct {
    projects: *db.Storage(u64, model.Project),
    tasks: *db.Storage(u64, model.Task),
};

pub const ProjectCreated = struct {
    id: u64,
    name: []const u8,

    pub fn apply(self: @This(), allocator: std.mem.Allocator, storages: Storages) !void {
        try storages.projects.entities.put(self.id, .{
            .id = self.id,
            .name = try allocator.dupe(u8, self.name),
        });
    }
};

pub const ProjectSetStatus = struct {
    id: u64,
    status: model.ProjectStatus,

    pub fn apply(self: @This(), _: std.mem.Allocator, storages: Storages) !void {
        const project = storages.projects.entities.getPtr(self.id) orelse return error.ProjectNotFound;
        project.status = self.status;
    }
};

pub const TaskCreated = struct {
    id: u64,
    project_id: u64,
    name: []const u8,

    pub fn apply(self: @This(), allocator: std.mem.Allocator, storages: Storages) !void {
        try storages.tasks.entities.put(self.id, .{
            .id = self.id,
            .project_id = self.project_id,
            .name = try allocator.dupe(u8, self.name),
            .done = false,
        });
    }
};

pub const TaskSetDone = struct {
    id: u64,
    done: bool,

    pub fn apply(self: @This(), _: std.mem.Allocator, storages: Storages) !void {
        const task = storages.tasks.entities.getPtr(self.id) orelse return error.TaskNotFound;
        task.done = self.done;
    }
};

pub const EventData = union(enum) {
    project_created: ProjectCreated,
    project_set_status: ProjectSetStatus,
    task_created: TaskCreated,
    task_set_done: TaskSetDone,
};
