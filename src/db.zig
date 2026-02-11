const std = @import("std");

const db = @import("db");

const event = @import("event.zig");
const model = @import("model.zig");

// Event-sourced storage layer
// All state changes are persisted as events in append-only WAL
// Current state is rebuilt by replaying all events on startup

pub fn Storage(comptime T: type) type {
    return db.Storage(u64, T);
}

const Wal = db.Wal(event.Event);

const ProjectStorage = Storage(model.Project);
const TaskStorage = Storage(model.Task);

pub const Database = struct {
    const Self = @This();

    wal: Wal,

    pub fn init(wal_path: []const u8) !Database {
        return .{
            .wal = try Wal.init(wal_path),
        };
    }

    pub fn deinit(self: *Database) void {
        self.wal.deinit();
    }

    // Not thread safe, to use at launch or lock storage mutex around it
    pub fn loadEvent(
        allocator: std.mem.Allocator,
        event_to_load: event.Event,
        project_storage: *ProjectStorage,
        task_storage: *TaskStorage,
    ) !void {
        switch (event_to_load.data) {
            .project_created => |payload| {
                const project = model.Project{
                    .id = payload.id,
                    .name = try allocator.dupe(u8, payload.name),
                };

                try project_storage.entities.put(project.id, project);
            },
            .project_set_status => |payload| {
                const project_to_update = project_storage.entities.getPtr(payload.id) orelse return error.ProjectNotFound;
                project_to_update.status = payload.status;
            },
            .task_created => |payload| {
                const task = model.Task{
                    .id = payload.id,
                    .name = try allocator.dupe(u8, payload.name),
                    .done = false,
                    .project_id = payload.project_id,
                };

                try task_storage.entities.put(task.id, task);
            },
            .task_set_done => |payload| {
                const task_to_update = task_storage.entities.getPtr(payload.id) orelse return error.TaskNotFound;
                task_to_update.done = payload.done;
            },
        }
    }

    pub fn loadAllEvents(
        self: *Self,
        allocator: std.mem.Allocator,
        arena_allocator: std.mem.Allocator,
        project_storage: *ProjectStorage,
        task_storage: *TaskStorage,
    ) !void {
        const events = try self.wal.readAll(arena_allocator);

        for (events.items) |event_to_load| {
            try loadEvent(allocator, event_to_load, project_storage, task_storage);
        }
    }

    pub fn appendEvent(
        self: *Self,
        main_allocator: std.mem.Allocator,
        arena_allocator: std.mem.Allocator,
        event_to_append: event.Event,
        project_storage: *ProjectStorage,
        task_storage: *TaskStorage,
    ) !void {
        project_storage.mutex.lock();
        defer project_storage.mutex.unlock();
        task_storage.mutex.lock();
        defer task_storage.mutex.unlock();

        try self.wal.append(arena_allocator, event_to_append);

        try loadEvent(main_allocator, event_to_append, project_storage, task_storage);
    }
};
