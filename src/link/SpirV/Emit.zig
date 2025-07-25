gpa: std.mem.Allocator,
ip: *const InternPool,
target: *const std.Target,
codes: []const Mir,
nav_map: std.AutoArrayHashMapUnmanaged(InternPool.Nav.Index, Id) = .empty,
local_map: std.AutoArrayHashMapUnmanaged(GlobalKey, Id) = .empty,
type_map: std.ArrayHashMapUnmanaged(AnyIndex.Type, Id, TypeMapContext, true) = .empty,
next_id: Word = 1,
capabilities: Section = .{},
extensions: Section = .{},
extended_instruction_set: Section = .{},
entry_points: Section = .{},
exec_modes: Section = .{},
debug_strings: Section = .{},
debug_names: Section = .{},
annotations: Section = .{},
types_constants: Section = .{},
functions: Section = .{},

const GlobalKey = struct {
    mir: *const Mir,
    local_index: LocalIndex,
};

const TypeMapContext = struct {
    mir: *const Mir,

    pub fn hash(ctx: TypeMapContext, key: AnyIndex.Type) u32 {
        var hasher: std.hash.XxHash32 = .init(0x1234);

        hasher.update(&std.mem.toBytes(key.tag));
        switch (key.tag) {
            .void => {},
            .func => {
                const extra = ctx.mir.extraValue(AnyIndex.FnType, key.index);
                const params_index = ctx.mir.extraSlice(ExtraIndex, extra.params);
                const return_ty = ctx.mir.extraValue(AnyIndex.Type, extra.return_ty);
                hasher.update(&std.mem.toBytes(hash(ctx, return_ty.*)));
                for (params_index) |param_index| {
                    const param = ctx.mir.extraValue(AnyIndex.Type, param_index);
                    hasher.update(&std.mem.toBytes(hash(ctx, param.*)));
                }
            },
            else => unreachable,
        }

        return hasher.final();
    }

    pub fn eql(ctx: TypeMapContext, a: AnyIndex.Type, b: AnyIndex.Type, index: usize) bool {
        if (a.tag != b.tag) return false;

        switch (a.tag) {
            .void => {},
            .func => {
                const a_extra = ctx.mir.extraValue(AnyIndex.FnType, a.index);
                const b_extra = ctx.mir.extraValue(AnyIndex.FnType, b.index);

                const a_return_ty = ctx.mir.extraValue(AnyIndex.Type, a_extra.return_ty);
                const b_return_ty = ctx.mir.extraValue(AnyIndex.Type, b_extra.return_ty);
                if (!eql(ctx, a_return_ty.*, b_return_ty.*, index)) return false;

                const a_params_index = ctx.mir.extraSlice(ExtraIndex, a_extra.params);
                const b_params_index = ctx.mir.extraSlice(ExtraIndex, b_extra.params);
                for (a_params_index, b_params_index) |a_param_index, b_param_index| {
                    const a_param = ctx.mir.extraValue(AnyIndex.Type, a_param_index);
                    const b_param = ctx.mir.extraValue(AnyIndex.Type, b_param_index);
                    if (!eql(ctx, a_param.*, b_param.*, index)) return false;
                }
            },
            else => unreachable,
        }

        return true;
    }
};

pub fn deinit(emit: *Emit) void {
    emit.nav_map.deinit(emit.gpa);
    emit.local_map.deinit(emit.gpa);
    emit.type_map.deinit(emit.gpa);

    emit.capabilities.deinit(emit.gpa);
    emit.extensions.deinit(emit.gpa);
    emit.extended_instruction_set.deinit(emit.gpa);
    emit.entry_points.deinit(emit.gpa);
    emit.exec_modes.deinit(emit.gpa);
    emit.debug_strings.deinit(emit.gpa);
    emit.debug_names.deinit(emit.gpa);
    emit.annotations.deinit(emit.gpa);
    emit.types_constants.deinit(emit.gpa);
    emit.functions.deinit(emit.gpa);
}

pub fn lower(emit: *Emit) ![]Word {
    const os_tag = emit.target.os.tag;
    const cpu = emit.target.cpu;

    { // Emit capabilities and extensions
        try emit.capabilities.ensureUnusedCapacity(emit.gpa, 64);
        try emit.extensions.ensureUnusedCapacity(emit.gpa, 16);

        emit.lowerCap(.int8);
        emit.lowerCap(.int16);
        switch (os_tag) {
            .opengl => {
                emit.lowerCap(.shader);
                emit.lowerCap(.matrix);
            },
            .vulkan => {
                emit.lowerCap(.shader);
                emit.lowerCap(.matrix);
                if (cpu.arch == .spirv64) {
                    emit.lowerExt("SPV_KHR_physical_storage_buffer");
                    emit.lowerCap(.physical_storage_buffer_addresses);
                }
            },
            .opencl, .amdhsa => {
                emit.lowerCap(.kernel);
                emit.lowerCap(.addresses);
            },
            else => unreachable,
        }
        if (cpu.arch == .spirv64 or cpu.has(.spirv, .int64)) emit.lowerCap(.int64);
        if (cpu.has(.spirv, .float16)) emit.lowerCap(.float16);
        if (cpu.has(.spirv, .float64)) emit.lowerCap(.float64);
        if (cpu.has(.spirv, .generic_pointer)) emit.lowerCap(.generic_pointer);
        if (cpu.has(.spirv, .vector16)) emit.lowerCap(.vector16);
        if (cpu.has(.spirv, .storage_push_constant16)) {
            emit.lowerExt("SPV_KHR_16bit_storage");
            emit.lowerCap(.storage_push_constant16);
        }
        if (cpu.has(.spirv, .arbitrary_precision_integers)) {
            emit.lowerExt("SPV_INTEL_arbitrary_precision_integers");
            emit.lowerCap(.arbitrary_precision_integers_intel);
        }
        if (cpu.has(.spirv, .variable_pointers)) {
            emit.lowerExt("SPV_KHR_variable_pointers");
            emit.lowerCap(.variable_pointers);
            emit.lowerCap(.variable_pointers_storage_buffer);
        }
    }

    {
        const addressing_model: spec.AddressingModel = switch (os_tag) {
            .opengl => .logical,
            .vulkan => if (cpu.arch == .spirv32) .logical else .physical_storage_buffer64,
            .opencl => if (cpu.arch == .spirv32) .physical32 else .physical64,
            .amdhsa => .physical64,
            else => unreachable,
        };
        const memory_model: spec.MemoryModel = switch (os_tag) {
            .opencl => .open_cl,
            .vulkan, .opengl => .glsl450,
            else => unreachable,
        };
        try emit.entry_points.emit(emit.gpa, .OpMemoryModel, .{
            .addressing_model = addressing_model,
            .memory_model = memory_model,
        });
    }

    {
        // We need to export the list of error names somewhere so that we can pretty-print them in the
        // executor. This is not really an important thing though, so we can just dump it in any old
        // nonsemantic instruction. For now, just put it in OpSourceExtension with a special name.
        var error_info: std.io.Writer.Allocating = .init(emit.gpa);
        defer error_info.deinit();

        error_info.writer.writeAll("zig_errors:") catch return error.OutOfMemory;
        for (emit.ip.global_error_set.getNamesFromMainThread()) |name| {
            // Errors can contain pretty much any character - to encode them in a string we must escape
            // them somehow. Easiest here is to use some established scheme, one which also preseves the
            // name if it contains no strange characters is nice for debugging. URI encoding fits the bill.
            // We're using : as separator, which is a reserved character.
            error_info.writer.writeByte(':') catch return error.OutOfMemory;
            std.Uri.Component.percentEncode(
                &error_info.writer,
                name.toSlice(emit.ip),
                struct {
                    fn isValidChar(c: u8) bool {
                        return switch (c) {
                            0, '%', ':' => false,
                            else => true,
                        };
                    }
                }.isValidChar,
            ) catch return error.OutOfMemory;
        }

        try emit.debug_strings.emit(emit.gpa, .OpSourceExtension, .{
            .extension = error_info.getWritten(),
        });
    }

    var source: Section = .{};
    defer source.deinit(emit.gpa);
    try emit.debug_strings.emit(emit.gpa, .OpSource, .{
        .source_language = .zig,
        .version = 0,
        // We cannot emit these because the Khronos translator
        // does not parse this instruction correctly.
        // See https://github.com/KhronosGroup/SPIRV-LLVM-Translator/issues/2188
        .file = null,
        .source = null,
    });

    for (emit.codes) |*mir| {
        const tag = mir.instructions.items(.tag)[0];
        const index = mir.instructions.items(.index)[0];
        std.debug.assert(tag == .func);
        try emit.lowerFn(mir, index.extra_index);
    }

    const version: spec.Version = .{
        .major = 1,
        .minor = blk: {
            // Prefer higher versions
            if (cpu.has(.spirv, .v1_6)) break :blk 6;
            if (cpu.has(.spirv, .v1_5)) break :blk 5;
            if (cpu.has(.spirv, .v1_4)) break :blk 4;
            if (cpu.has(.spirv, .v1_3)) break :blk 3;
            if (cpu.has(.spirv, .v1_2)) break :blk 2;
            if (cpu.has(.spirv, .v1_1)) break :blk 1;
            break :blk 0;
        },
    };
    const buffers = &[_][]const Word{
        &.{
            spec.magic_number,
            version.toWord(),
            spec.zig_generator_id,
            emit.next_id,
            0, // Schema (currently reserved for future use)
        },
        emit.capabilities.toWords(),
        emit.extensions.toWords(),
        emit.extended_instruction_set.toWords(),
        emit.entry_points.toWords(),
        emit.exec_modes.toWords(),
        source.toWords(),
        emit.debug_strings.toWords(),
        emit.debug_names.toWords(),
        emit.annotations.toWords(),
        emit.types_constants.toWords(),
        emit.functions.toWords(),
    };

    var total_result_size: usize = 0;
    for (buffers) |buffer| {
        total_result_size += buffer.len;
    }

    const words = try emit.gpa.alloc(Word, total_result_size);
    errdefer comptime unreachable;

    var offset: usize = 0;
    for (buffers) |buffer| {
        @memcpy(words[offset..][0..buffer.len], buffer);
        offset += buffer.len;
    }

    return words;
}

fn allocId(emit: *Emit) Id {
    defer emit.next_id += 1;
    return @enumFromInt(emit.next_id);
}

fn localId(emit: *Emit, mir: *const Mir, index: LocalIndex) !Id {
    const gop = try emit.local_map.getOrPut(emit.gpa, .{ .mir = mir, .local_index = index });
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = emit.allocId();
    return gop.value_ptr.*;
}

fn navId(emit: *Emit, index: InternPool.Nav.Index) !Id {
    const gop = try emit.nav_map.getOrPut(emit.gpa, index);
    if (gop.found_existing) return gop.value_ptr.*;
    gop.value_ptr.* = emit.allocId();
    return gop.value_ptr.*;
}

fn lowerExt(emit: *Emit, ext: []const u8) void {
    try emit.extensions.emitAssumeCapacity(.OpExtension, .{ .name = ext });
}

fn lowerCap(emit: *Emit, cap: spec.Capability) void {
    try emit.capabilities.emitAssumeCapacity(.OpCapability, .{ .capability = cap });
}

fn lowerInst(emit: *Emit, mir: *const Mir, tag: Inst.Tag, index: AnyIndex) !Id {
    switch (tag) {
        .func => unreachable,
        .ret => try emit.functions.emit(emit.gpa, .OpReturn, {}),
        .ret_value => {
            const operand = try emit.localId(mir, index.local_index);
            try emit.functions.emit(emit.gpa, .OpReturnValue, .{ .value = operand });
        },
        else => unreachable,
    }
    return .none;
}

fn lowerType(emit: *Emit, mir: *const Mir, index: ExtraIndex) !Id {
    const ty = mir.extraValue(AnyIndex.Type, index);

    const gop = try emit.type_map.getOrPutContext(emit.gpa, ty.*, .{ .mir = mir });
    if (gop.found_existing) return gop.value_ptr.*;
    const id = emit.allocId();
    gop.value_ptr.* = id;

    switch (ty.tag) {
        .void => try emit.types_constants.emit(emit.gpa, .OpTypeVoid, .{
            .id_result = id,
        }),
        .func => {
            const extra = mir.extraValue(AnyIndex.FnType, ty.index);
            const params_index = mir.extraSlice(ExtraIndex, extra.params);
            const params_id = try emit.gpa.alloc(Id, extra.params.len());
            defer emit.gpa.free(params_id);
            for (params_index, params_id) |param_index, *param_id| {
                param_id.* = try emit.lowerType(mir, param_index);
            }
            try emit.types_constants.emit(emit.gpa, .OpTypeFunction, .{
                .id_result = id,
                .return_type = try emit.lowerType(mir, extra.return_ty),
                .id_ref_2 = params_id,
            });
        },
        else => unreachable,
    }

    return id;
}

fn lowerFn(emit: *Emit, mir: *const Mir, extra_index: ExtraIndex) !void {
    const func = mir.extraValue(AnyIndex.Fn, extra_index);
    const name = mir.extraSliceZ(u8, func.name);
    const interface_data = mir.extraSlice(AnyIndex, func.interface);

    const interface = try emit.gpa.alloc(Id, interface_data.len);
    defer emit.gpa.free(interface);
    for (interface, interface_data) |*id, dep_index| {
        id.* = try emit.navId(dep_index.nav_index);
    }

    const result_id = try emit.navId(func.nav_index);
    try emit.entry_points.emit(emit.gpa, .OpEntryPoint, .{
        .execution_model = switch (func.exec_model) {
            .vertex => .vertex,
            .fragment => .fragment,
            .compute => switch (emit.target.os.tag) {
                .opencl, .amdhsa => .kernel,
                else => .gl_compute,
            },
        },
        .entry_point = result_id,
        .name = name,
        .interface = interface,
    });

    switch (func.exec_model) {
        .vertex => {},
        .fragment => {
            try emit.exec_modes.emit(emit.gpa, .OpExecutionMode, .{
                .entry_point = result_id,
                .mode = switch (emit.target.os.tag) {
                    .vulkan => .origin_upper_left,
                    .opengl => .origin_upper_left,
                    else => unreachable,
                },
            });
        },
        .compute => |compute| {
            try emit.exec_modes.emit(emit.gpa, .OpExecutionMode, .{
                .entry_point = result_id,
                .mode = .{ .local_size = .{
                    .x_size = compute[0],
                    .y_size = compute[1],
                    .z_size = compute[2],
                } },
            });
        },
    }

    try emit.functions.emit(emit.gpa, .OpFunction, .{
        .id_result_type = try emit.lowerType(mir, func.return_ty),
        .id_result = result_id,
        .function_control = .{},
        .function_type = try emit.lowerType(mir, func.ty),
    });
    const label_id = emit.allocId();
    try emit.functions.emit(emit.gpa, .OpLabel, .{ .id_result = label_id });

    for (
        mir.instructions.items(.tag)[1..],
        mir.instructions.items(.index)[1..],
    ) |tag, data| {
        _ = try emit.lowerInst(mir, tag, data);
    }

    try emit.functions.emit(emit.gpa, .OpFunctionEnd, {});
}

const Emit = @This();

const LocalIndex = Mir.LocalIndex;
const ExtraIndex = Mir.ExtraIndex;
const AnyIndex = Mir.AnyIndex;
const Inst = Mir.Inst;
const Id = spec.Id;
const Word = spec.Word;
const Mir = @import("../../arch/spirv/Mir.zig");
const Section = @import("Section.zig");
const spec = @import("spec.zig");
const InternPool = @import("../../InternPool.zig");
const std = @import("std");
