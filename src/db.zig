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
        shape_storage: *Storage(model.Project),
    ) !void {
        switch (event_to_load.data) {
            .project_created => |payload| {
                const shape = model.Project{
                    .id = payload.id,
                    .name = try allocator.dupe(u8, payload.name),
                };

                try shape_storage.entities.put(shape.id, shape);
            },
        }
    }

    pub fn loadAllEvents(
        self: *Self,
        allocator: std.mem.Allocator,
        arena_allocator: std.mem.Allocator,
        shape_storage: *Storage(model.Project),
    ) !void {
        const events = try self.wal.readAll(arena_allocator);

        for (events.items) |event_to_load| {
            try loadEvent(allocator, event_to_load, shape_storage);
        }
    }

    pub fn appendEvent(
        self: *Self,
        main_allocator: std.mem.Allocator,
        arena_allocator: std.mem.Allocator,
        event_to_append: event.Event,
        shape_storage: *Storage(model.Project),
    ) !void {
        shape_storage.mutex.lock();
        defer shape_storage.mutex.unlock();

        try self.wal.append(arena_allocator, event_to_append);

        try loadEvent(main_allocator, event_to_append, shape_storage);
    }
};
