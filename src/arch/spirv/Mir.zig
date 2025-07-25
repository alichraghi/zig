//! Machine Intermediate Representation.
//! This data is produced by CodeGen.zig

instructions: Inst.List,
extra: []const u8,

pub const Inst = struct {
    tag: Tag,
    index: AnyIndex,

    pub const Tag = enum(u32) {
        func,

        ret,
        ret_value,

        addi,
        addu,
        addf,
        subi,
        subu,
        subf,
        muli,
        mulu,
        mulf,
        divi,
        divu,
        divf,
    };

    pub const List = std.MultiArrayList(Inst);
};

pub const ExtraIndex = enum(u32) {
    none,
    _,

    pub const Range = struct {
        start: ExtraIndex,
        end: ExtraIndex,

        pub const empty: Range = .{ .start = .none, .end = .none };

        pub fn len(range: Range) u32 {
            return @intFromEnum(range.end) - @intFromEnum(range.start);
        }
    };
};

pub const LocalIndex = enum(u32) {
    none,
    error_buffer,
    _,

    pub const start: LocalIndex = @enumFromInt(@typeInfo(LocalIndex).@"enum".fields.len);
};

pub const AnyIndex = union {
    none: void,
    local_index: LocalIndex,
    nav_index: InternPool.Nav.Index,
    ip_index: InternPool.Index,
    extra_index: ExtraIndex,

    pub const Type = struct {
        tag: Tag,
        index: ExtraIndex,

        pub const Tag = enum(u8) {
            void,
            i8,
            i16,
            i32,
            i64,
            u8,
            u16,
            u32,
            u64,
            arr,
            vec,
            ptr,
            func,
        };
    };

    pub const FnType = struct {
        return_ty: ExtraIndex,
        params: ExtraIndex.Range,
    };

    pub const StorageClass = enum(u8) {
        local,
        input,
        output,
    };

    pub const Fn = struct {
        nav_index: InternPool.Nav.Index,
        exec_model: ExecModel,
        name: ExtraIndex,
        ty: ExtraIndex,
        return_ty: ExtraIndex,
        interface: ExtraIndex.Range,
        end: ExtraIndex,
    };

    pub const ExecModel = union(enum(u8)) {
        vertex,
        fragment,
        compute: [3]u32,
    };
};

pub fn deinit(mir: *Mir, gpa: std.mem.Allocator) void {
    mir.instructions.deinit(gpa);
    gpa.free(mir.extra);
}

pub fn extraValue(mir: Mir, comptime T: type, index: ExtraIndex) *align(1) const T {
    return std.mem.bytesAsValue(T, mir.extra[@intFromEnum(index)..]);
}

pub fn extraSlice(mir: Mir, comptime T: type, range: ExtraIndex.Range) []align(1) const T {
    std.debug.assert(@intFromEnum(range.end) >= @intFromEnum(range.start));
    return std.mem.bytesAsSlice(T, mir.extra[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

pub fn extraSliceZ(mir: Mir, comptime T: type, start: ExtraIndex) []align(1) const T {
    const ptr = mir.extra[@intFromEnum(start)..];
    const len = std.mem.indexOfSentinel(u8, 0, @ptrCast(ptr));
    return std.mem.bytesAsSlice(T, ptr[0..len]);
}

const Mir = @This();

const InternPool = @import("../../InternPool.zig");
const std = @import("std");
