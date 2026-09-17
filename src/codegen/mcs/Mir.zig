//! MCS-251 / MCS-51 机器中间表示（MIR）。
//!
//! 与逐字节编码的后端不同，本后端产出的是 ASxxxx 汇编文本：因此 MIR 保存的是
//! 汇编文本层面的条目——局部标签、指令、原样指示符（`.area`/`.globl` 等）。
//! `CodeGen.generate` 负责把 AIR 降级为这些条目，`emit` 把它们写成汇编文本，
//! 随后由 `sdas251` 汇编、`sdld` 链接。
//!
//! 函数自身的 `.area` / `.globl` / 函数符号由链接层（`link/Asx.zig`）负责包裹，
//! 本模块的 `emit` 只输出函数体（含 prologue/epilogue 条目）。

const std = @import("std");

const encode = @import("encode.zig");
const link = @import("../../link.zig");
const codegen = @import("../../codegen.zig");
const Zcu = @import("../../Zcu.zig");
const InternPool = @import("../../InternPool.zig");

const Mir = @This();

/// 函数体的条目序列。
items: std.ArrayListUnmanaged(Item) = .empty,

/// 由本 MIR 持有、需要存活到 `emit` 的字符串（例如调用目标的符号名）。
owned: std.ArrayListUnmanaged([]const u8) = .empty,

/// 函数体中一个条目。
pub const Item = union(enum) {
    /// 局部数字标签，输出为 `L{n}:`。
    label: u32,
    /// 一条指令。
    inst: Inst,
    /// 原样输出的汇编文本（不含换行）。
    raw: []const u8,
};

/// 一条 MIR 指令：助记符 + 最多 3 个操作数。
pub const Inst = struct {
    mnemonic: encode.Mnemonic,
    operands: [max_operands]encode.Operand = undefined,
    len: u2 = 0,

    pub const max_operands = 3;

    pub fn ops(inst: *const Inst) []const encode.Operand {
        return inst.operands[0..inst.len];
    }
};

pub fn deinit(mir: *Mir, gpa: std.mem.Allocator) void {
    for (mir.owned.items) |text| gpa.free(text);
    mir.owned.deinit(gpa);
    mir.items.deinit(gpa);
    mir.* = undefined;
}

/// 记录一段由本 MIR 持有的文本，`deinit` 时释放。
pub fn addOwned(mir: *Mir, gpa: std.mem.Allocator, text: []const u8) !void {
    try mir.owned.append(gpa, text);
}

/// 追加一条指令。操作数个数不得超过 `Inst.max_operands`。
pub fn addInst(
    mir: *Mir,
    gpa: std.mem.Allocator,
    mnemonic: encode.Mnemonic,
    operands: []const encode.Operand,
) !void {
    std.debug.assert(operands.len <= Inst.max_operands);
    var inst: Inst = .{ .mnemonic = mnemonic };
    for (operands, 0..) |op, i| inst.operands[i] = op;
    inst.len = @intCast(operands.len);
    try mir.items.append(gpa, .{ .inst = inst });
}

/// 追加一条局部标签定义。
pub fn addLabel(mir: *Mir, gpa: std.mem.Allocator, n: u32) !void {
    try mir.items.append(gpa, .{ .label = n });
}

/// 追加一段原样输出的汇编文本。
pub fn addRaw(mir: *Mir, gpa: std.mem.Allocator, text: []const u8) !void {
    try mir.items.append(gpa, .{ .raw = text });
}

/// 把 MIR 写成 ASxxxx 汇编文本。
///
/// `lf`、`pt`、`func_index`、`atom_index`、`debug_output` 目前未使用：函数符号与
/// `.area`/`.globl` 由链接层负责，调试信息尚未实现。
pub fn emit(
    mir: Mir,
    lf: *link.File,
    pt: Zcu.PerThread,
    src_loc: Zcu.LazySrcLoc,
    func_index: InternPool.Index,
    atom_index: u32,
    w: *std.Io.Writer,
    debug_output: link.File.DebugInfoOutput,
) (codegen.CodeGenError || std.Io.Writer.Error)!void {
    _ = lf;
    _ = pt;
    _ = src_loc;
    _ = func_index;
    _ = atom_index;
    _ = debug_output;

    for (mir.items.items) |item| switch (item) {
        .label => |n| w.print("L{d}:\n", .{n}) catch return error.WriteFailed,
        .raw => |text| {
            try w.writeAll(text);
            try w.writeByte('\n');
        },
        .inst => |inst| {
            try w.writeAll("        ");
            try encode.formatInst(w, inst.mnemonic, inst.ops());
            try w.writeByte('\n');
        },
    };
}
