const std = @import("std");
const model = @import("model.zig");

pub const Event = @import("db").Event(EventData);

pub const ProjectCreated = struct {
    id: u64,
    name: []const u8,

    pub fn walSerialize(self: @This(), arena: std.mem.Allocator) ![]const u8 {
        const name_len: u16 = @intCast(self.name.len);
        const buf = try arena.alloc(u8, 8 + 2 + self.name.len);
        std.mem.writeInt(u64, buf[0..8], self.id, .little);
        std.mem.writeInt(u16, buf[8..10], name_len, .little);
        @memcpy(buf[10..], self.name);
        return buf;
    }

    pub fn walDeserialize(arena: std.mem.Allocator, payload: []const u8) !@This() {
        const id = std.mem.readInt(u64, payload[0..8], .little);
        const name_len = std.mem.readInt(u16, payload[8..10], .little);
        const name = try arena.dupe(u8, payload[10..][0..name_len]);
        return .{ .id = id, .name = name };
    }
};

pub const ProjectSetStatus = struct {
    id: u64,
    status: model.ProjectStatus,

    pub fn walSerialize(self: @This(), arena: std.mem.Allocator) ![]const u8 {
        const buf = try arena.alloc(u8, 8 + 1);
        std.mem.writeInt(u64, buf[0..8], self.id, .little);
        buf[8] = @intFromEnum(self.status);
        return buf;
    }

    pub fn walDeserialize(_: std.mem.Allocator, payload: []const u8) !@This() {
        const id = std.mem.readInt(u64, payload[0..8], .little);
        const status = std.meta.intToEnum(model.ProjectStatus, payload[8]) catch return error.InvalidStatus;
        return .{ .id = id, .status = status };
    }
};

pub const TaskCreated = struct {
    id: u64,
    project_id: u64,
    name: []const u8,

    pub fn walSerialize(self: @This(), arena: std.mem.Allocator) ![]const u8 {
        const name_len: u16 = @intCast(self.name.len);
        const buf = try arena.alloc(u8, 8 + 8 + 2 + self.name.len);
        std.mem.writeInt(u64, buf[0..8], self.id, .little);
        std.mem.writeInt(u64, buf[8..16], self.project_id, .little);
        std.mem.writeInt(u16, buf[16..18], name_len, .little);
        @memcpy(buf[18..], self.name);
        return buf;
    }

    pub fn walDeserialize(arena: std.mem.Allocator, payload: []const u8) !@This() {
        const id = std.mem.readInt(u64, payload[0..8], .little);
        const project_id = std.mem.readInt(u64, payload[8..16], .little);
        const name_len = std.mem.readInt(u16, payload[16..18], .little);
        const name = try arena.dupe(u8, payload[18..][0..name_len]);
        return .{ .id = id, .project_id = project_id, .name = name };
    }
};

pub const TaskSetDone = struct {
    id: u64,
    done: bool,

    pub fn walSerialize(self: @This(), arena: std.mem.Allocator) ![]const u8 {
        const buf = try arena.alloc(u8, 8 + 1);
        std.mem.writeInt(u64, buf[0..8], self.id, .little);
        buf[8] = @intFromBool(self.done);
        return buf;
    }

    pub fn walDeserialize(_: std.mem.Allocator, payload: []const u8) !@This() {
        const id = std.mem.readInt(u64, payload[0..8], .little);
        const done = payload[8] != 0;
        return .{ .id = id, .done = done };
    }
};

pub const EventData = union(enum) {
    project_created: ProjectCreated,
    project_set_status: ProjectSetStatus,
    task_created: TaskCreated,
    task_set_done: TaskSetDone,
};
