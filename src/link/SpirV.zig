base: link.File,
mirs: std.AutoArrayHashMapUnmanaged(InternPool.Nav.Index, Mir),

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*SpirV {
    const target = &comp.root_mod.resolved_target.result;

    assert(!comp.config.use_lld); // Caught by Compilation.Config.resolve
    assert(!comp.config.use_llvm); // Caught by Compilation.Config.resolve
    assert(target.ofmt == .spirv); // Caught by Compilation.Config.resolve
    switch (target.cpu.arch) {
        .spirv32, .spirv64 => {},
        else => unreachable, // Caught by Compilation.Config.resolve.
    }
    switch (target.os.tag) {
        .opencl, .opengl, .vulkan => {},
        else => unreachable, // Caught by Compilation.Config.resolve.
    }

    const self = try arena.create(SpirV);
    self.* = .{
        .base = .{
            .tag = .spirv,
            .comp = comp,
            .emit = emit,
            .gc_sections = options.gc_sections orelse false,
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse 0,
            .allow_shlib_undefined = options.allow_shlib_undefined orelse false,
            .file = try emit.root_dir.handle.createFile(emit.sub_path, .{
                .truncate = true,
                .read = true,
            }),
            .build_id = options.build_id,
        },
        .mirs = .empty,
    };
    return self;
}

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*SpirV {
    return createEmpty(arena, comp, emit, options);
}

pub fn deinit(self: *SpirV) void {
    const gpa = self.base.comp.gpa;
    for (self.mirs.values()) |*mir| mir.deinit(gpa);
    self.mirs.deinit(gpa);
}

pub fn updateNav(
    self: *SpirV,
    pt: Zcu.PerThread,
    nav: InternPool.Nav.Index,
) link.File.UpdateNavError!void {
    _ = self;
    _ = pt;
    _ = nav;
}

pub fn updateFunc(
    self: *SpirV,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *AnyMir,
) !void {
    const nav = pt.zcu.funcInfo(func_index).owner_nav;
    try self.mirs.put(self.base.comp.gpa, nav, mir.spirv);
}

pub fn updateExports(
    self: *SpirV,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) !void {
    _ = self;
    _ = pt;
    _ = exported;
    _ = export_indices;
}

pub fn flush(
    self: *SpirV,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.File.FlushError!void {
    _ = arena;
    _ = tid;

    const comp = self.base.comp;
    const sub_prog_node = prog_node.start("Flush Module", 0);
    defer sub_prog_node.end();

    var emit: Emit = .{
        .gpa = comp.gpa,
        .ip = &comp.zcu.?.intern_pool,
        .target = comp.getTarget(),
        .codes = self.mirs.values(),
    };
    defer emit.deinit();
    const words = try emit.lower();
    defer comp.gpa.free(words);

    self.base.file.?.writeAll(std.mem.sliceAsBytes(words)) catch |err|
        return comp.link_diags.fail("failed to write: {s}", .{@errorName(err)});
}

const SpirV = @This();

const std = @import("std");
const Zcu = @import("../Zcu.zig");
const InternPool = @import("../InternPool.zig");
const Compilation = @import("../Compilation.zig");
const link = @import("../link.zig");
const Mir = @import("../arch/spirv/Mir.zig");
const AnyMir = @import("../codegen.zig").AnyMir;
const Emit = @import("SpirV/Emit.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Path = std.Build.Cache.Path;
const log = std.log.scoped(.link);
