//! ASxxxx 汇编文本输出（mcs2 最小链接层）。
//!
//! 不做增量链接：每个函数渲染为 ASxxxx 文本并追加到 `assembly`，
//! `flush` 一次性写文件；后续由 sdas8051/sdld 接管。
//! 当前只支持 mcs2 的空函数与简单数据占位。

const Asx = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Path = std.Build.Cache.Path;

const Zcu = @import("../Zcu.zig");
const Type = @import("../Type.zig");
const InternPool = @import("../InternPool.zig");
const Compilation = @import("../Compilation.zig");
const codegen = @import("../codegen.zig");
const mcs2 = @import("../codegen/mcs2.zig");
const link = @import("../link.zig");
const AnyMir = codegen.AnyMir;

base: link.File,

/// 累积的 ASxxxx 文本。
assembly: std.ArrayListUnmanaged(u8) = .empty,

pub fn open(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Asx {
    return createEmpty(arena, comp, emit, options);
}

pub fn createEmpty(
    arena: Allocator,
    comp: *Compilation,
    emit: Path,
    options: link.File.OpenOptions,
) !*Asx {
    const io = comp.io;
    const target = &comp.root_mod.resolved_target.result;
    std.debug.assert(target.ofmt == .hex);
    const optimize_mode = comp.root_mod.optimize_mode;
    const output_mode = comp.config.output_mode;

    const file = try emit.root_dir.handle.createFile(io, emit.sub_path, .{
        .truncate = false,
    });
    errdefer file.close(io);

    const asx = try arena.create(Asx);
    asx.* = .{
        .base = .{
            .tag = .asx,
            .comp = comp,
            .emit = emit,
            .gc_sections = options.gc_sections orelse (optimize_mode != .debug and output_mode != .Obj),
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse 0,
            .allow_shlib_undefined = options.allow_shlib_undefined orelse false,
            .file = file,
            .build_id = options.build_id,
        },
        .assembly = .empty,
    };

    try asx.assembly.appendSlice(
        comp.gpa,
        "\t.area DSEG    (DATA)\n" ++
            "\t.area ISEG    (DATA)\n" ++
            "\t.area BSEG    (BIT)\n" ++
            "\t.area XSEG    (XDATA)\n" ++
            "\t.area CSEG    (CODE)\n",
    );
    return asx;
}

pub fn deinit(asx: *Asx) void {
    const gpa = asx.base.comp.gpa;
    asx.assembly.deinit(gpa);
}

pub fn updateFunc(
    asx: *Asx,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *AnyMir,
) codegen.Error!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = zcu.funcInfo(func_index).owner_nav;
    const name = try mcs2.mangleNavSymbol(gpa, ip, nav);
    defer gpa.free(name);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    w.print("\t.area CSEG    (CODE)\n", .{}) catch return error.OutOfMemory;
    w.print("\t.globl {s}\n", .{name}) catch return error.OutOfMemory;
    w.print("{s}:\n", .{name}) catch return error.OutOfMemory;
    codegen.emitFunction(&asx.base, pt, func_index, @fromBackingInt(@intCast(0)), mir, w, .none) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };

    try asx.assembly.appendSlice(gpa, aw.written());
}

pub fn updateNav(
    asx: *Asx,
    pt: Zcu.PerThread,
    nav_index: InternPool.Nav.Index,
) codegen.Error!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    const resolved = nav.resolved orelse return;
    if (resolved.is_extern_decl) return;
    if (resolved.value == .none) return;
    const ty = Type.fromInterned(resolved.type);
    if (!ty.hasRuntimeBits(zcu)) return;
    const size: u32 = @intCast(ty.abiSize(zcu));
    if (size == 0) return;

    const name = try std.fmt.allocPrint(gpa, "_{s}", .{nav.name.toSlice(ip)});
    defer gpa.free(name);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    w.print("\t.area XSEG    (XDATA)\n", .{}) catch return error.OutOfMemory;
    w.print("\t.globl {s}\n", .{name}) catch return error.OutOfMemory;
    w.print("{s}:\n", .{name}) catch return error.OutOfMemory;
    w.print("\t.ds {d}\n", .{size}) catch return error.OutOfMemory;
    try asx.assembly.appendSlice(gpa, aw.written());
}

pub fn updateExports(
    asx: *Asx,
    pt: Zcu.PerThread,
    export_indices: []const Zcu.Export.Index,
) Allocator.Error!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const arch = zcu.getTarget().cpu.arch;
    for (export_indices) |idx| {
        const exp = idx.ptr(zcu);
        const nav = switch (exp.exported) {
            .nav => |n| n,
            .uav => continue,
        };
        const resolved = ip.getNav(nav).resolved orelse continue;
        if (Type.fromInterned(resolved.type).zigTypeTag(zcu) != .@"fn") continue;

        const target = try mcs2.mangleNavSymbol(gpa, ip, nav);
        defer gpa.free(target);
        const export_name = exp.opts.name.toSlice(ip);
        const sym = try std.fmt.allocPrint(gpa, "_{s}", .{export_name});
        defer gpa.free(sym);
        if (std.mem.eql(u8, sym, target)) continue;

        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.print("\t.area CSEG    (CODE)\n", .{}) catch return error.OutOfMemory;
        w.print("\t.globl {s}\n", .{sym}) catch return error.OutOfMemory;
        w.print("{s}:\n", .{sym}) catch return error.OutOfMemory;
        w.print("\t{s} {s}\n", .{ if (arch == .mcs251) "ejmp" else "ljmp", target }) catch return error.OutOfMemory;
        try asx.assembly.appendSlice(gpa, aw.written());
    }
}

pub fn loadInput(asx: *Asx, input: link.Input) !void {
    _ = asx;
    _ = input;
    std.log.err("asx (mcs2) does not support linking object files or archives", .{});
    return error.AlreadyReported;
}

pub fn navSymbol(asx: *Asx, nav: InternPool.Nav.Index) link.Error!link.File.SymbolId {
    _ = asx;
    _ = nav;
    return @fromBackingInt(@intCast(0));
}

pub fn uavSymbol(
    asx: *Asx,
    pt: Zcu.PerThread,
    uav: InternPool.Index,
    explicit_alignment: InternPool.Alignment,
) link.Error!link.File.SymbolId {
    _ = asx;
    _ = pt;
    _ = uav;
    _ = explicit_alignment;
    return @fromBackingInt(@intCast(0));
}

pub fn flush(
    asx: *Asx,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.Error!void {
    _ = arena;
    _ = tid;
    const sub = prog_node.start("Flush ASxxxx output", 0);
    defer sub.end();

    const comp = asx.base.comp;
    const io = comp.io;
    const diags = &comp.link_diags;
    const text = asx.assembly.items;

    const file = asx.base.file orelse return diags.fail("ASxxxx output file is not open", .{});
    file.setLength(io, text.len) catch |err| return diags.fail("failed to allocate ASxxxx output: {t}", .{err});

    var fw = file.writer(io, &.{});
    const w = &fw.interface;
    w.writeAll(text) catch |err| switch (err) {
        error.WriteFailed => return diags.fail("failed to write '{f}': {s}", .{
            std.fmt.alt(asx.base.emit, .formatEscapeChar), @errorName(fw.err.?),
        }),
    };
    w.flush() catch |err| switch (err) {
        error.WriteFailed => return diags.fail("failed to flush '{f}': {s}", .{
            std.fmt.alt(asx.base.emit, .formatEscapeChar), @errorName(fw.err.?),
        }),
    };
}
