gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
pt: Zcu.PerThread,
air: *const Air,
liveness: *const ?Air.Liveness,
target: *const std.Target,
nav_index: InternPool.Nav.Index,
next_local_index: Mir.LocalIndex,
mir_instructions: std.MultiArrayList(Mir.Inst),
mir_extra: std.ArrayListUnmanaged(u8),

pub fn deinit(cg: *CodeGen) void {
    cg.arena.deinit();
}

fn addInst(cg: *CodeGen, tag: Mir.Inst.Tag, index: Mir.AnyIndex) !void {
    try cg.mir_instructions.append(cg.gpa, .{ .tag = tag, .index = index });
}

fn addString(cg: *CodeGen, string: []const u8) !Mir.ExtraIndex {
    const index = cg.mir_extra.items.len;
    try cg.mir_extra.ensureUnusedCapacity(cg.gpa, string.len + 1);
    cg.mir_extra.appendSliceAssumeCapacity(string);
    cg.mir_extra.appendAssumeCapacity(0);
    return @enumFromInt(index);
}

fn reserveExtra(cg: *CodeGen, T: type) !struct { Mir.ExtraIndex, *align(1) T } {
    const index = cg.mir_extra.items.len;
    const extra = try cg.mir_extra.addManyAsArray(cg.gpa, @sizeOf(T));
    return .{ @enumFromInt(index), @ptrCast(extra) };
}

fn addExtra(cg: *CodeGen, extra: anytype) !Mir.ExtraIndex {
    const index, const ptr = try cg.reserveExtra(@TypeOf(extra));
    ptr.* = extra;
    return index;
}

pub fn generate(
    lf: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    air: *const Air,
    liveness: *const ?Air.Liveness,
) !Mir {
    _ = lf;
    _ = src_loc;

    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav_index = pt.zcu.funcInfo(func_index).owner_nav;
    const nav = ip.getNav(nav_index);
    const val = zcu.navValue(nav_index);
    const ty = val.typeOf(zcu);
    const target = &pt.zcu.root_mod.resolved_target.result;

    var cg: CodeGen = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .pt = pt,
        .air = air,
        .liveness = liveness,
        .target = target,
        .nav_index = nav_index,
        .next_local_index = .start,
        .mir_instructions = .empty,
        .mir_extra = .empty,
    };
    defer cg.deinit();

    if (ip.isFunctionType(nav.typeOf(ip))) {
        const is_test = pt.zcu.test_functions.contains(nav_index);

        // Generate a test kernel declaration if this is a test function.
        if (is_test) {
            // const anyerror_ty_id = try cg.resolveType(Type.anyerror, .direct);
            // const ptr_anyerror_ty = try cg.pt.ptrType(.{
            //     .child = Type.anyerror.toIntern(),
            //     .flags = .{ .address_space = .global },
            // });
            // const ptr_anyerror_ty_id = try cg.resolveType(ptr_anyerror_ty, .direct);

            // const p_error_id = cg.mir.allocId();
            // switch (cg.target.os.tag) {
            //     .opencl, .amdhsa => {
            //         const kernel_proto_ty_id = try cg.functionType(Type.void, &.{ptr_anyerror_ty});

            //         try cg.func.prologue.emit(cg.gpa, .OpFunction, .{
            //             .id_result_type = try cg.resolveType(Type.void, .direct),
            //             .id_result = result_id,
            //             .function_control = .{},
            //             .function_type = kernel_proto_ty_id,
            //         });

            //         try cg.func.prologue.emit(cg.gpa, .OpFunctionParameter, .{
            //             .id_result_type = ptr_anyerror_ty_id,
            //             .id_result = p_error_id,
            //         });

            //         cg.error_buffer = p_error_id;
            //     },
            //     .vulkan, .opengl => {
            //         const buffer_struct_ty_id = cg.mir.allocId();
            //         try cg.structType(buffer_struct_ty_id, &.{anyerror_ty_id}, &.{"error_out"});
            //         try cg.decorate(buffer_struct_ty_id, .block);
            //         try cg.decorateMember(buffer_struct_ty_id, 0, .{ .offset = .{ .byte_offset = 0 } });

            //         const ptr_buffer_struct_ty_id = cg.mir.allocId();
            //         try cg.mir.types_constants.emit(cg.gpa, .OpTypePointer, .{
            //             .id_result = ptr_buffer_struct_ty_id,
            //             .storage_class = cg.spvStorageClass(.global),
            //             .type = buffer_struct_ty_id,
            //         });

            //         const buffer_struct_id = cg.mir.allocId();
            //         try cg.mir.types_constants.emit(cg.gpa, .OpVariable, .{
            //             .id_result_type = ptr_buffer_struct_ty_id,
            //             .id_result = buffer_struct_id,
            //             .storage_class = cg.spvStorageClass(.global),
            //         });
            //         try cg.decorate(buffer_struct_id, .{ .descriptor_set = .{ .descriptor_set = 0 } });
            //         try cg.decorate(buffer_struct_id, .{ .binding = .{ .binding_point = 0 } });
            //         try cg.mir.entry_point.?.deps.putNoClobber(cg.gpa, buffer_struct_id, {});

            //         cg.error_buffer = buffer_struct_id;

            //         const kernel_proto_ty_id = try cg.functionType(Type.void, &.{});
            //         try cg.func.prologue.emit(cg.gpa, .OpFunction, .{
            //             .id_result_type = try cg.resolveType(Type.void, .direct),
            //             .id_result = result_id,
            //             .function_control = .{},
            //             .function_type = kernel_proto_ty_id,
            //         });
            //     },
            //     else => unreachable,
            // }
        } else {}

        const extra_index, const func = try cg.reserveExtra(Mir.AnyIndex.Fn);
        try cg.addInst(.func, .{ .extra_index = extra_index });

        for (air.getMainBody()) |inst| {
            _ = try cg.lowerInst(inst);
        }

        const name = nav.fqn.toSlice(ip);
        const cc = ty.fnCallingConvention(zcu);
        const name_index = try cg.addString(name);
        const return_ty = try cg.addExtra(Mir.AnyIndex.Type{ .tag = .void, .index = .none });
        const fn_ty_extra = try cg.addExtra(Mir.AnyIndex.FnType{
            .return_ty = return_ty,
            .params = .empty,
        });
        const fn_ty = try cg.addExtra(Mir.AnyIndex.Type{ .tag = .func, .index = fn_ty_extra });

        func.* = .{
            .nav_index = nav_index,
            .exec_model = switch (cc) {
                .spirv_vertex => .vertex,
                .spirv_fragment => .fragment,
                .spirv_kernel => @panic("TODO"),
                .spirv_device => @panic("TODO"),
                .auto => @panic("TODO"),
                else => if (is_test) .{ .compute = .{ 1, 1, 1 } } else @panic("TODO"),
            },
            .name = name_index,
            .ty = fn_ty,
            .return_ty = return_ty,
            .interface = .empty,
            .end = .none,
        };
    } else switch (nav.getAddrspace()) {
        .generic => {
            @panic("TODO");
        },
        else => {
            @panic("TODO");
            // const maybe_init_val: ?Value = switch (ip.indexToKey(val.toIntern())) {
            //     .func => unreachable,
            //     .variable => |variable| Value.fromInterned(variable.init),
            //     .@"extern" => null,
            //     else => val,
            // };
            // assert(maybe_init_val == null); // TODO

            // const storage_class = cg.spvStorageClass(nav.getAddrspace());
            // assert(storage_class != .generic); // These should be instance globals

            // const ptr_ty_id = try cg.ptrType(ty, storage_class, .indirect);

            // try cg.mir.types_constants.emit(cg.gpa, .OpVariable, .{
            //     .id_result_type = ptr_ty_id,
            //     .id_result = result_id,
            //     .storage_class = storage_class,
            // });

            // if (std.meta.stringToEnum(spec.BuiltIn, nav.fqn.toSlice(ip))) |built_in| {
            //     try cg.decorate(result_id, .{ .built_in = .{ .built_in = built_in } });
            // }

            // try cg.debugName(result_id, nav.fqn.toSlice(ip));
        },
    }

    return .{
        .instructions = cg.mir_instructions,
        .extra = try cg.mir_extra.toOwnedSlice(gpa),
    };
}

fn lowerInst(cg: *CodeGen, inst: Air.Inst.Index) !Mir.AnyIndex {
    const zcu = cg.pt.zcu;
    const ip = &zcu.intern_pool;

    if (cg.liveness.*.?.isUnused(inst) and !cg.air.mustLower(inst, ip))
        return .{ .none = {} };

    const air_tags = cg.air.instructions.items(.tag);
    switch (air_tags[@intFromEnum(inst)]) {
        .ret_safe => try cg.lowerReturn(inst),
        else => |tag| std.debug.print("implement AIR tag {s}\n", .{@tagName(tag)}),
    }

    return .{ .none = {} };
}

fn lowerReturn(cg: *CodeGen, inst: Air.Inst.Index) !void {
    const zcu = cg.pt.zcu;
    const operand = cg.air.instructions.items(.data)[@intFromEnum(inst)].un_op;
    const ret_ty = cg.air.typeOf(operand, &zcu.intern_pool);
    if (ret_ty.hasRuntimeBitsIgnoreComptime(zcu)) {
        const operand_index = try cg.resolveRef(operand);
        try cg.addInst(.ret_value, operand_index);
    }
    try cg.addInst(.ret, .{ .none = {} });
}

fn resolveRef(cg: *CodeGen, ref: Air.Inst.Ref) std.mem.Allocator.Error!Mir.AnyIndex {
    const pt = cg.pt;
    const zcu = pt.zcu;
    if (try cg.air.value(ref, pt)) |val| {
        const ty = cg.air.typeOf(ref, &zcu.intern_pool);
        _ = ty;
        _ = val;
        unreachable;
        // return try cg.constant(ty, val, .direct);
    }
    return cg.lowerInst(ref.toIndex().?);
}

pub fn legalizeFeatures(_: *const std.Target) *const Air.Legalize.Features {
    return comptime &.initMany(&.{
        .expand_intcast_safe,
        .expand_int_from_float_safe,
        .expand_int_from_float_optimized_safe,
        .expand_add_safe,
        .expand_sub_safe,
        .expand_mul_safe,
    });
}

const CodeGen = @This();

const log = std.log.scoped(.codegen);
const assert = std.debug.assert;

const Mir = @import("Mir.zig");
const Air = @import("../../Air.zig");
const InternPool = @import("../../InternPool.zig");
const Zcu = @import("../../Zcu.zig");
const codegen = @import("../../codegen.zig");
const link = @import("../../link.zig");
const std = @import("std");
