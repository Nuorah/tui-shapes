const model = @import("model.zig");

pub const ShapeCreated = struct {
    id: u64,
    name: []const u8,
};

pub const EventData = union(enum) { shape_created: ShapeCreated };

pub const Event = struct {
    timestamp: i64,
    data: EventData,
};
