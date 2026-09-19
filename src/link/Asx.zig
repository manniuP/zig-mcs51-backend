//! ASxxxx 可重定位文本输出 / SDCC `sdld` 驱动。
//!
//! 与直接产出目标字节的后端不同，本后端产出 ASxxxx 汇编文本。因此这里不做增量
//! 链接：`updateFunc` 渲染单个函数并把文本追加到 `assembly`，`flush` 一次性写入
//! 输出文件（通常为 `.asm`/`.s`），后续由 `sdas251` 汇编、`sdld` 链接。
//!
//! 函数符号按 fqn 修饰（命名空间 → `_`）避免同名冲突，导出名用 trampoline 提供；
//! 数据符号仍以短名 `_<name>` 导出（`updateNav`）。

const Asx = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Path = std.Build.Cache.Path;

const Zcu = @import("../Zcu.zig");
const Type = @import("../Type.zig");
const InternPool = @import("../InternPool.zig");
const Compilation = @import("../Compilation.zig");
const codegen = @import("../codegen.zig");
const mcs = @import("../codegen/mcs/CodeGen.zig");
const device = @import("../codegen/mcs/device.zig");
const link = @import("../link.zig");
const AnyMir = codegen.AnyMir;

base: link.File,

/// 累积的汇编文本。各函数的文本在 `updateFunc` 中追加，`flush` 一次性落盘。
assembly: std.ArrayList(u8) = .empty,

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

    // 与 C 后端一致：文件在 `flush` 时截断并写入。
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
            .gc_sections = options.gc_sections orelse (optimize_mode != .Debug and output_mode != .Obj),
            .print_gc_sections = options.print_gc_sections,
            .stack_size = options.stack_size orelse 0,
            .allow_shlib_undefined = options.allow_shlib_undefined orelse false,
            .file = file,
            .build_id = options.build_id,
        },
        .assembly = .empty,
    };
    return asx;
}

pub fn deinit(asx: *Asx) void {
    const gpa = asx.base.comp.gpa;
    asx.assembly.deinit(gpa);
}

/// 数据符号放置 → ASxxxx 区名（`edata` 为 251 的 16 位 `@dptr` 区；`exdata` 为片外 xdata 区）。
fn areaFor(p: device.Place) []const u8 {
    return switch (p) {
        .data => "\t.area DSEG    (DATA)\n",
        .idata => "\t.area ISEG    (DATA)\n",
        .edata => "\t.area EDATA   (XDATA)\n",
        .xdata => "\t.area XSEG    (XDATA)\n",
        .exdata => "\t.area EXDATA  (XDATA)\n",
    };
}

/// AIR/MIR 已由 codegen 生成；这里把函数文本渲染并追加到 `assembly`。
pub fn updateFunc(
    asx: *Asx,
    pt: Zcu.PerThread,
    func_index: InternPool.Index,
    mir: *AnyMir,
) codegen.CodeGenError!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = zcu.funcInfo(func_index).owner_nav;
    // 函数符号按 fqn 修饰（命名空间用 `_` 连接），避免同名冲突；导出名由 updateExports 提供。
    const name = try mcs.mangleNavSymbol(gpa, ip, nav);
    defer gpa.free(name);

    // O 等级（GCC 对齐）：`Os` 函数归入独立 `COLD` 区；其余进 `CSEG`。
    // 标签同时以注释 `; @tag func <name> <region><level>` 传给中间层。
    const raw: ?[]const u8 = if (ip.getNav(nav).resolved) |r| r.@"linksection".toSlice(ip) else null;
    const sec = if (raw) |s| device.parseSection(s) else device.Section{};
    const lvl_name = if (sec.level) |l| device.levelName(l) else "O3";
    const is_cold = if (sec.level) |l| l == .os else false;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    // 调试符号（调试档 `-ODebug`）：函数入口 `G$<名>$0$0`、出口 `XG$<名>$0$0`，
    // 用 `==.` 绑定当前地址；链接时 `sdld -y` 会写成 `.cdb` 的 `L:` 记录。
    const cdb_on = zcu.optimizeMode() == .Debug;
    const dbg_name = if (name.len > 0 and name[0] == '_') name[1..] else name;

    // 函数头：标签提示 + 代码区、全局符号与标签。
    w.print("; @tag func {s} {s}{s}\n", .{ name, if (is_cold) "cold" else "cseg", lvl_name }) catch return error.OutOfMemory;
    w.writeAll(if (is_cold) "\t.area COLD    (CODE)\n" else "\t.area CSEG    (CODE)\n") catch return error.OutOfMemory;
    if (cdb_on) w.print("\tG${s}$0$0 ==.\n", .{dbg_name}) catch return error.OutOfMemory;
    w.print("\t.globl {s}\n", .{name}) catch return error.OutOfMemory;
    w.print("{s}:\n", .{name}) catch return error.OutOfMemory;

    codegen.emitFunction(&asx.base, pt, zcu.navSrcLoc(nav), func_index, 0, mir, w, .none) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };

    if (cdb_on) w.print("\tXG${s}$0$0 ==.\n", .{dbg_name}) catch return error.OutOfMemory;

    try asx.assembly.appendSlice(gpa, aw.written());
}

/// 数据符号（全局变量）：在 xdata 区（`XSEG`）分配 `size` 字节并导出符号。
/// 注：目前只做零初始化（`.ds`），非零初值需经 XINIT/启动拷贝，暂未实现。
pub fn updateNav(
    asx: *Asx,
    pt: Zcu.PerThread,
    nav_index: InternPool.Nav.Index,
) codegen.CodeGenError!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = ip.getNav(nav_index);
    const resolved = nav.resolved orelse return;
    if (resolved.is_extern_decl) return; // extern 由 C 侧定义
    if (resolved.value == .none) return;
    const ty = Type.fromInterned(resolved.type);
    if (!ty.hasRuntimeBits(zcu)) return; // 函数 / 零位类型
    const size: u32 = @intCast(ty.abiSize(zcu));
    if (size == 0) return;

    const name = try std.fmt.allocPrint(gpa, "_{s}", .{nav.name.toSlice(ip)});
    defer gpa.free(name);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    // 数据空间/分区：`.cold`→独立 COLDX；其余按设备表（`MCS_DEVICE`）放置——
    // 显式 `linksection`（`.data`/`.hot`→DSEG、`.idata`→ISEG）优先，未标注时
    // ≤2B→DSEG、其余→设备默认数据空间（多数字号 XSEG/xdata）。与 CodeGen 的
    // derefSymbolRead/Write 保持一致（同一 `device.decide`）。
    const ls = resolved.@"linksection".toSlice(ip);
    const dev = device.get(asx.base.comp.environ_map);
    // 放置/O 等级标签以注释传给中间层（`tools/mcs_ir.py` 消费后删）。
    const section = if (ls) |s| device.parseSection(s) else device.Section{};
    const lvl_name = if (section.level) |l| device.levelName(l) else "O3";
    const place_name = if (section.place) |p| @tagName(p) else "auto";
    const area_line: []const u8 = blk: {
        if (ls) |s| {
            if (std.mem.eql(u8, s, ".cold")) break :blk "\t.area COLDX   (XDATA)\n";
        }
        const arch = asx.base.comp.root_mod.resolved_target.result.cpu.arch;
        break :blk areaFor(device.decide(dev, arch, ls, size));
    };
    w.print("; @tag sym {s} {s}{s}\n", .{ name, place_name, lvl_name }) catch return error.OutOfMemory;
    w.writeAll(area_line) catch return error.OutOfMemory;
    w.print("\t.globl {s}\n", .{name}) catch return error.OutOfMemory;
    w.print("{s}:\n", .{name}) catch return error.OutOfMemory;
    w.print("\t.ds {d}\n", .{size}) catch return error.OutOfMemory;
    try asx.assembly.appendSlice(gpa, aw.written());
}

/// 导出符号：函数体已按 fqn 修饰（`_<mangled>`），这里为每个导出名生成一个 trampoline
/// `_<export>: ejmp/ljmp _<mangled>`，使 C/启动代码仍能以短名引用（`_main` 等）。
/// 数据符号由 `updateNav` 直接以 `_<name>` 导出，这里跳过。
pub fn updateExports(
    asx: *Asx,
    pt: Zcu.PerThread,
    exported: Zcu.Exported,
    export_indices: []const Zcu.Export.Index,
) Allocator.Error!void {
    const zcu = pt.zcu;
    const gpa = zcu.gpa;
    const ip = &zcu.intern_pool;
    const nav = switch (exported) {
        .nav => |n| n,
        .uav => return,
    };
    const resolved = ip.getNav(nav).resolved orelse return;
    if (Type.fromInterned(resolved.type).zigTypeTag(zcu) != .@"fn") return;

    const target = try mcs.mangleNavSymbol(gpa, ip, nav);
    defer gpa.free(target);

    const arch = zcu.getTarget().cpu.arch;
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    for (export_indices) |idx| {
        const exp = idx.ptr(zcu);
        const export_name = exp.opts.name.toSlice(ip);
        const sym = try std.fmt.allocPrint(gpa, "_{s}", .{export_name});
        defer gpa.free(sym);
        if (std.mem.eql(u8, sym, target)) continue; // 已是同一符号，无需 trampoline
        w.print("\t.area CSEG    (CODE)\n", .{}) catch return error.OutOfMemory;
        w.print("\t.globl {s}\n", .{sym}) catch return error.OutOfMemory;
        w.print("{s}:\n", .{sym}) catch return error.OutOfMemory;
        if (arch == .mcs251) {
            w.print("\tejmp {s}\n", .{target}) catch return error.OutOfMemory;
        } else {
            w.print("\tljmp {s}\n", .{target}) catch return error.OutOfMemory;
        }
    }
    try asx.assembly.appendSlice(gpa, aw.written());
}

/// 把累积的汇编文本写入输出文件。
pub fn flush(
    asx: *Asx,
    arena: Allocator,
    tid: Zcu.PerThread.Id,
    prog_node: std.Progress.Node,
) link.File.FlushError!void {
    _ = arena;
    _ = tid;
    const sub_prog_node = prog_node.start("Flush ASxxxx output", 0);
    defer sub_prog_node.end();

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
