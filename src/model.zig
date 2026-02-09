pub const ShapeStatus = enum {
    draft,
    doing,
    abandonned,
    completed,
};

pub const Shape = struct {
    id: u64,
    name: []const u8,
    appetite: ?u32 = null,
    time_left: ?u32 = null,
    status: ShapeStatus = .draft,
};

pub const Task = struct {
    id: u64,
    shape_id: u64,
    name: []const u8,
    done: bool = false,
};
