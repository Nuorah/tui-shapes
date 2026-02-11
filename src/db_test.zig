const std = @import("std");
const db = @import("db.zig");
const model = @import("model.zig");
const event = @import("event.zig");

const ProjectStorage = db.Storage(model.Project);
const TaskStorage = db.Storage(model.Task);
const Database = db.Database;

fn freshStorages(allocator: std.mem.Allocator) struct { ProjectStorage, TaskStorage } {
    return .{ ProjectStorage.init(allocator), TaskStorage.init(allocator) };
}

fn load(allocator: std.mem.Allocator, evt: event.Event, ps: *ProjectStorage, ts: *TaskStorage) !void {
    try Database.loadEvent(allocator, evt, ps, ts);
}

// =====
// Projects
// =====

test "project created with draft status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    try load(allocator, .{
        .timestamp = 0,
        .data = .{ .project_created = .{ .id = 1, .name = "my project" } },
    }, &ps, &ts);

    const project = ps.entities.get(1).?;
    try std.testing.expectEqualStrings("my project", project.name);
    try std.testing.expectEqual(model.ProjectStatus.draft, project.status);
}

test "project status cycles through all states" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    try load(allocator, .{
        .timestamp = 0,
        .data = .{ .project_created = .{ .id = 1, .name = "test" } },
    }, &ps, &ts);

    const statuses = [_]model.ProjectStatus{ .doing, .abandonned, .completed };
    for (statuses, 1..) |expected_status, i| {
        try load(allocator, .{
            .timestamp = @intCast(i),
            .data = .{ .project_set_status = .{ .id = 1, .status = expected_status } },
        }, &ps, &ts);
        try std.testing.expectEqual(expected_status, ps.entities.get(1).?.status);
    }
}

test "set status on nonexistent project returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    const result = load(allocator, .{
        .timestamp = 0,
        .data = .{ .project_set_status = .{ .id = 999, .status = .doing } },
    }, &ps, &ts);

    try std.testing.expectError(error.ProjectNotFound, result);
}

test "multiple projects are independent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    try load(allocator, .{ .timestamp = 0, .data = .{ .project_created = .{ .id = 1, .name = "alpha" } } }, &ps, &ts);
    try load(allocator, .{ .timestamp = 1, .data = .{ .project_created = .{ .id = 2, .name = "beta" } } }, &ps, &ts);
    try load(allocator, .{ .timestamp = 2, .data = .{ .project_set_status = .{ .id = 1, .status = .completed } } }, &ps, &ts);

    try std.testing.expectEqual(model.ProjectStatus.completed, ps.entities.get(1).?.status);
    try std.testing.expectEqual(model.ProjectStatus.draft, ps.entities.get(2).?.status);
}

// =====
// Tasks
// =====

test "task created linked to project" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    try load(allocator, .{ .timestamp = 0, .data = .{ .project_created = .{ .id = 1, .name = "proj" } } }, &ps, &ts);
    try load(allocator, .{
        .timestamp = 1,
        .data = .{ .task_created = .{ .id = 10, .project_id = 1, .name = "do the thing" } },
    }, &ps, &ts);

    const task = ts.entities.get(10).?;
    try std.testing.expectEqualStrings("do the thing", task.name);
    try std.testing.expectEqual(@as(u64, 1), task.project_id);
    try std.testing.expectEqual(false, task.done);
}

test "task toggle done flips correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    try load(allocator, .{ .timestamp = 0, .data = .{ .project_created = .{ .id = 1, .name = "proj" } } }, &ps, &ts);
    try load(allocator, .{ .timestamp = 1, .data = .{ .task_created = .{ .id = 10, .project_id = 1, .name = "task" } } }, &ps, &ts);

    try load(allocator, .{ .timestamp = 2, .data = .{ .task_set_done = .{ .id = 10, .done = true } } }, &ps, &ts);
    try std.testing.expectEqual(true, ts.entities.get(10).?.done);

    try load(allocator, .{ .timestamp = 3, .data = .{ .task_set_done = .{ .id = 10, .done = false } } }, &ps, &ts);
    try std.testing.expectEqual(false, ts.entities.get(10).?.done);
}

test "toggle done on nonexistent task returns error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    const result = load(allocator, .{
        .timestamp = 0,
        .data = .{ .task_set_done = .{ .id = 999, .done = true } },
    }, &ps, &ts);

    try std.testing.expectError(error.TaskNotFound, result);
}

// =====
// Full replay
// =====

test "full event replay produces correct final state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var ps, var ts = freshStorages(allocator);

    const events = [_]event.Event{
        .{ .timestamp = 0, .data = .{ .project_created = .{ .id = 1, .name = "website redesign" } } },
        .{ .timestamp = 1, .data = .{ .project_created = .{ .id = 2, .name = "cli tool" } } },
        .{ .timestamp = 2, .data = .{ .task_created = .{ .id = 10, .project_id = 1, .name = "wireframes" } } },
        .{ .timestamp = 3, .data = .{ .task_created = .{ .id = 11, .project_id = 1, .name = "css cleanup" } } },
        .{ .timestamp = 4, .data = .{ .task_created = .{ .id = 20, .project_id = 2, .name = "arg parser" } } },
        .{ .timestamp = 5, .data = .{ .project_set_status = .{ .id = 1, .status = .doing } } },
        .{ .timestamp = 6, .data = .{ .task_set_done = .{ .id = 10, .done = true } } },
        .{ .timestamp = 7, .data = .{ .project_set_status = .{ .id = 2, .status = .abandonned } } },
        .{ .timestamp = 8, .data = .{ .task_set_done = .{ .id = 20, .done = true } } },
        .{ .timestamp = 9, .data = .{ .task_set_done = .{ .id = 20, .done = false } } },
    };

    for (events) |evt| {
        try load(allocator, evt, &ps, &ts);
    }

    // project 1: doing, two tasks, one done
    const p1 = ps.entities.get(1).?;
    try std.testing.expectEqualStrings("website redesign", p1.name);
    try std.testing.expectEqual(model.ProjectStatus.doing, p1.status);

    // project 2: abandonned
    const p2 = ps.entities.get(2).?;
    try std.testing.expectEqual(model.ProjectStatus.abandonned, p2.status);

    // task 10: done
    try std.testing.expectEqual(true, ts.entities.get(10).?.done);
    // task 11: not done
    try std.testing.expectEqual(false, ts.entities.get(11).?.done);
    // task 20: toggled on then off, so not done
    try std.testing.expectEqual(false, ts.entities.get(20).?.done);
    // task linkage
    try std.testing.expectEqual(@as(u64, 1), ts.entities.get(10).?.project_id);
    try std.testing.expectEqual(@as(u64, 2), ts.entities.get(20).?.project_id);
}
