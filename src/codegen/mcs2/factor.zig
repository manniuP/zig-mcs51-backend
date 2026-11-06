//! 重复复杂算法提取（code factoring）。
//!
//! 目标：统计编译单元内反复出现的「复杂算法」直线算术块，把块体压到一份
//! 共享子程序，调用点改成 `lcall`。这是「体积小」轴上继 DPTR 复用之后的
//! 第二刀，对应 tools/mcs2/exp_shared.py 的对照结论：同一运算出现两个调用点
//! 起，共享例程必然更省 Flash。
//!
//! 口径（与三根轴对齐）：
//!  - 尺寸：第一个站点付 `lcall 3 B + ret 1 B`，之后每个站点用「搬运 + lcall」
//!    取代整块；块越大、站点越多，收益越明显。
//!  - 安全：只提取纯算术直线块（无标签、无跳转、无内存访问、无调用）；
//!    ISR 一律不参与，共享例程本身也不调用任何函数。
//!  - 互操作：**不新增静态槽**。共享例程复用「第一次出现该块的函数」的
//!    vreg 基线，块内相对槽号经 `byteOf` 加同一个基线即可对上；边界 ABI
//!    与 `_名_PARM_n` 完全不碰。
//!
//! 已知限制（与 mcs2 既有静态槽模型一致，非新增退化）：
//!  拥有者函数的槽会被其它函数经共享例程临时使用。若「拥有者正在执行 →
//!  调用别的函数 → 别的函数又用到同一共享例程」，拥有者的活值可能被覆盖。
//!  mcs2 的静态参数区本来就不支持重入（非尾自递归已编译期拒绝），因此
//!  这里沿用同一约束；如后续引入栈帧或槽保存，应同步解除本限制。
const std = @import("std");
const mir = @import("mir.zig");
const mcs51 = @import("mcs51.zig");

const Op = mir.Op;
const Byte = mir.Byte;

/// 注册表容量：编译单元内的算法模板数、单块的槽数、指纹字节数。
/// 固定上限，不用堆分配，避免会话级全局状态带来泄漏或生命周期问题。
const MAX_TPL = 24;
const MAX_MAP = 32;
const MAX_BLOCK_OPS = 64;
const MIN_BLOCK_OPS = 5;
/// 单块参与的槽数上限（输入 + 输出）。超过就放弃共享，见判据处的说明。
const MAX_SHARE_SLOTS = 10;
const KEY_CAP = MAX_BLOCK_OPS * 12 + 1;

/// 全局开关（由 generate 按环境变量设置）。关闭时逐字节保持原有产物。
pub var enabled: bool = true;
/// 统计输出开关：诊断时手工改 true（与项目其它诊断开关同款口径）。
pub var dump: bool = false;

const Tpl = struct {
    key: [KEY_CAP]u8 = undefined,
    key_len: usize = 0,
    sym: [20]u8 = undefined,
    sym_len: usize = 0,
    owner_base: u8 = 0,
    owner_name: [64]u8 = undefined,
    owner_name_len: usize = 0,
    /// 归一化序号 -> 拥有者函数内的相对 vreg 编号
    map: [MAX_MAP]u8 = undefined,
    map_len: u8 = 0,
    inputs: u64 = 0,
    outputs: u64 = 0,
    hits: u32 = 0,
    block_len: usize = 0,
};

var tpls: [MAX_TPL]Tpl = std.mem.zeroes([MAX_TPL]Tpl);
var tpl_n: usize = 0;

/// `_mcs_vN` 名字的静态存储：搬运指令要用符号引用别的函数槽，
/// 这些 slice 必须活到 compileEx 发射完，放全局最省事。
var slot_names: [256][16]u8 = undefined;

fn slotName(abs: u8) []const u8 {
    return std.fmt.bufPrint(&slot_names[abs], "_mcs_v{d}", .{abs}) catch unreachable;
}

/// 一条 op 的规范化形状：最多 4 个 Byte 操作数 + 一个 16 位附加常量。
/// `is_write` 标出哪些操作数是写，用来算输入/输出槽。
/// `ok=false` 表示该 op 不能进块（切断块）。
const Shape = struct {
    tag: u8 = 0,
    slot: [4]?Byte = .{ null, null, null, null },
    is_write: [4]bool = .{ false, false, false, false },
    n: u16 = 0,
    complex: bool = false,
    ok: bool = true,
};

fn bin(tag: u8, x: anytype, complex: bool) Shape {
    return .{
        .tag = tag,
        .slot = .{ x.dst, x.lhs, x.rhs, null },
        .is_write = .{ true, false, false, false },
        .complex = complex,
    };
}

fn unary(tag: u8, dst: Byte, src: Byte, complex: bool) Shape {
    return .{
        .tag = tag,
        .slot = .{ dst, src, null, null },
        .is_write = .{ true, false, false, false },
        .complex = complex,
    };
}

/// 只放行纯 vreg/立即数的直线算术 op；带标签、跳转、内存、调用、SFR
/// 直址的一律切断块（共享例程不能依赖调用者的地址环境）。
fn opShape(op: Op) Shape {
    var s: Shape = switch (op) {
        .imm => |x| .{ .tag = 1, .slot = .{ x.dst, null, null, null }, .is_write = .{ true, false, false, false }, .n = x.value },
        .add => |x| bin(2, x, false),
        .sub => |x| bin(3, x, false),
        .and_ => |x| bin(4, x, false),
        .or_ => |x| bin(5, x, false),
        .xor_ => |x| bin(6, x, false),
        .clr_c => .{ .tag = 7 },
        .addc => |x| bin(8, x, true),
        .subb => |x| bin(9, x, true),
        .mul => |x| bin(10, x, true),
        .div_ => |x| bin(11, x, true),
        .rem_ => |x| bin(12, x, true),
        .mul16 => |x| .{
            .tag = 13,
            .slot = .{ x.lo, x.hi, x.lhs, x.rhs },
            .is_write = .{ true, true, false, false },
            .complex = true,
        },
        .not_ => |x| unary(14, x.dst, x.src, false),
        .shl => |x| .{ .tag = 15, .slot = .{ x.dst, x.lhs, null, null }, .is_write = .{ true, false, false, false }, .n = x.n, .complex = true },
        .shr => |x| .{ .tag = if (x.arith) 17 else 16, .slot = .{ x.dst, x.lhs, null, null }, .is_write = .{ true, false, false, false }, .n = x.n, .complex = true },
        .sex => |x| unary(18, x.dst, x.src, false),
        .rlc => |x| unary(19, x.dst, x.src, true),
        .rrc => |x| unary(20, x.dst, x.src, true),
        .mov => |x| unary(21, x.dst, x.src, false),
        .dec => |r| .{ .tag = 22, .slot = .{ Byte{ .vreg = r }, null, null, null }, .is_write = .{ true, false, false, false } },
        else => .{ .ok = false },
    };
    // 带 SFR 直址 / 私有符号的 op 一律当块边界：共享例程不能依赖调用者的
    // 地址环境（PARM 符号名、ABI 寄存器读写都属于函数私有形态）。
    if (s.ok) {
        for (s.slot) |maybe| {
            const b = maybe orelse continue;
            switch (b) {
                .vreg, .imm => {},
                else => {
                    s.ok = false;
                    break;
                },
            }
        }
    }
    return s;
}

fn byteVreg(b: Byte) ?u8 {
    return switch (b) {
        .vreg => |v| v,
        else => null,
    };
}

fn byteImm(b: Byte) ?u8 {
    return switch (b) {
        .imm => |v| v,
        else => null,
    };
}

fn isVregByte(b: Byte, r: u8) bool {
    return switch (b) {
        .vreg => |x| x == r,
        else => false,
    };
}

/// 宽量：从 base 起的 n 个连续槽是否覆盖 r。
fn isWideVreg(base: u8, n: u8, r: u8) bool {
    const begin: u16 = base;
    const at: u16 = r;
    return at >= begin and at < begin + @as(u16, n);
}

/// 一条 op 是否以任何方式（读或写）触碰 vreg `v`。
///
/// **保守口径**：这里逐条列出所有「会带 vreg 操作数」的形态；不带 vreg 的
/// 控制类指令显式返回 false。判定只服务于「这个槽是不是块专用临时量」，
/// 万一某个形态被漏掉、误判成 false，代价是错误地把活值当死值重绑；
/// 所以凡是拿不准的一律按「触碰」处理——多判 true 只会放弃一次优化。
fn touches(op: Op, v: u8) bool {
    return switch (op) {
        .imm => |x| isVregByte(x.dst, v),
        .add => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .sub => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .and_ => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .or_ => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .xor_ => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .addc => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .subb => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .mul => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .div_ => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .rem_ => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .mul16 => |x| isVregByte(x.lo, v) or isVregByte(x.hi, v) or
            isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .not_ => |x| isVregByte(x.dst, v) or isVregByte(x.src, v),
        .mov => |x| isVregByte(x.dst, v) or isVregByte(x.src, v),
        .sex => |x| isVregByte(x.dst, v) or isVregByte(x.src, v),
        .rlc => |x| isVregByte(x.dst, v) or isVregByte(x.src, v),
        .rrc => |x| isVregByte(x.dst, v) or isVregByte(x.src, v),
        .shl => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v),
        .shr => |x| isVregByte(x.dst, v) or isVregByte(x.lhs, v),
        .dec => |r| r == v,
        .dec_br_nz => |x| isVregByte(x.dst, v),
        .load_dir => |x| isVregByte(x.dst, v),
        .load_xdata => |x| isVregByte(x.dst, v),
        .load_xdata_sym => |x| isVregByte(x.dst, v),
        .load_code_sym => |x| isVregByte(x.dst, v),
        .load_xdata_idx => |x| isVregByte(x.dst, v) or isVregByte(x.idx, v),
        .load_xdata_idx_sym => |x| isVregByte(x.dst, v) or isVregByte(x.idx, v),
        .load_code_idx_sym => |x| isVregByte(x.dst, v) or isVregByte(x.idx, v),
        .load_xdata_dptr => |x| isVregByte(x.dst, v),
        .load_code_dptr => |x| isVregByte(x.dst, v),
        .store_xdata_dptr => |x| isVregByte(x.src, v),
        .dptr_add_scaled => |x| isVregByte(x.idx, v),
        .push => |x| isVregByte(x.src, v),
        .pop => |x| isVregByte(x.dst, v),
        .store_dir => |x| isVregByte(x.src, v),
        .store_xdata => |x| isVregByte(x.src, v),
        .store_xdata_sym => |x| isVregByte(x.src, v),
        .store_xdata_idx => |x| isVregByte(x.idx, v) or isVregByte(x.src, v),
        .store_xdata_idx_sym => |x| isVregByte(x.idx, v) or isVregByte(x.src, v),
        .cmp_br => |x| isVregByte(x.lhs, v) or isVregByte(x.rhs, v),
        .br_ifnz => |x| isVregByte(x.cond, v),
        .br_ifz => |x| isVregByte(x.cond, v),
        .cmp_wide_br => |x| isWideVreg(x.lhs, x.n, v) or isWideVreg(x.rhs, x.n, v) or
            isVregByte(x.tmp, v),
        .lcall_ind => |x| isVregByte(x.save, v),
        // 以下形态确定不带 vreg 操作数（跳转目标、符号名、条件位、纯标志操作）。
        .clr_c, .ret, .reti, .halt, .label, .br, .br_c, .bit_br,
        .lcall, .ljmp, .lea_dptr_sym,
        => false,
        // 取槽地址：只读槽、不改值，但保守起见按「触碰」处理（见 touches）。
        .lea_r_vreg => true,
    };
}

const Rebound = struct { idx: usize, src: Byte };

/// 站点输入槽 `v` 能否**原地重绑**到拥有者槽：把它的定义直接写到拥有者
/// 槽上，站点就不必在 `lcall` 前再搬一次。
///
/// 三个条件（全部满足才成立）：
///  1. 块前只有**一条**指令触碰 `v`，且形态是 `mov v, S`；
///  2. `S` 不是本站点自己的任何槽（否则几条重绑之间会产生顺序依赖）；
///  3. 块后完全没有触碰 `v` 的指令——私有槽从此是死值，不会有人再读它。
///
/// 满足时「私有槽」只是块专用临时量，改写相当于把它的家搬到拥有者槽，
/// 语义逐字节等价，省掉的是 `mov 拥有者槽, 私有槽` 这一整条。
fn reboundDef(
    src_ops: []const Op,
    start: usize,
    end: usize,
    v: u8,
    site_slots: *const [MAX_MAP]u8,
    map_len: u8,
) ?Rebound {
    var found: ?usize = null;
    var i: usize = 0;
    while (i < start) : (i += 1) {
        if (!touches(src_ops[i], v)) continue;
        if (found != null) return null; // 块前不止一次触碰：不是纯临时量
        found = i;
    }
    const idx = found orelse return null;
    const mv = switch (src_ops[idx]) {
        .mov => |x| x,
        else => return null,
    };
    switch (mv.dst) {
        .vreg => |d| if (d != v) return null,
        else => return null,
    }
    if (byteVreg(mv.src)) |sv| {
        var k: u8 = 0;
        while (k < map_len) : (k += 1) if (site_slots[k] == sv) return null;
    }
    for (src_ops[end..]) |op| if (touches(op, v)) return null;
    return .{ .idx = idx, .src = mv.src };
}

/// 输出侧重绑：块后对站点槽的每一处使用都只是「读出来放进某个目的地」，
/// 就把这些读的源直接换成拥有者槽，`mov 站点槽, 拥有者槽` 的搬出整条省掉。
/// 返回受影响的指令下标表；`n == 0` 表示不适用。
///
/// 消费者不止 `mov`：函数返回走的是 `store_dir 0x82, v`（DPL），早期只认
/// `mov` 会让所有「结果直接返回」的站点全部漏掉。
const MAX_OUT_USE = 8;
const OutRebind = struct {
    n: u8 = 0,
    idx: [MAX_OUT_USE]usize = undefined,
    ops: [MAX_OUT_USE]Op = undefined,
};

/// 把一条「读站点槽」的消费者改写成「读拥有者槽」。语义只换源操作数。
fn rebindOutOp(op: Op, sym: []const u8) ?Op {
    const src: Byte = .{ .sym = sym };
    return switch (op) {
        .mov => |x| .{ .mov = .{ .dst = x.dst, .src = src } },
        .store_dir => |x| .{ .store_dir = .{ .addr = x.addr, .src = src } },
        .store_xdata => |x| .{ .store_xdata = .{ .addr = x.addr, .src = src } },
        .store_xdata_sym => |x| .{ .store_xdata_sym = .{ .sym = x.sym, .off = x.off, .src = src } },
        .push => .{ .push = .{ .src = src } },
        else => null,
    };
}

fn reboundOut(
    src_ops: []const Op,
    end: usize,
    v: u8,
    site_slots: *const [MAX_MAP]u8,
    map_len: u8,
) ?OutRebind {
    var r: OutRebind = .{};
    var i: usize = end;
    while (i < src_ops.len) : (i += 1) {
        const op = src_ops[i];
        if (!touches(op, v)) continue;
        // 只认「纯读消费者」，且源必须正好是 v。
        switch (op) {
            .mov => |x| {
                if (byteVreg(x.src)) |sv| {
                    if (sv != v) return null;
                } else return null;
                if (byteVreg(x.dst)) |dv| {
                    if (dv == v) return null; // 原地改写：值会被覆盖
                    var k: u8 = 0;
                    while (k < map_len) : (k += 1) if (site_slots[k] == dv) return null;
                }
            },
            .store_dir, .store_xdata, .store_xdata_sym, .push => {
                const s = switch (op) {
                    .store_dir => |x| x.src,
                    .store_xdata => |x| x.src,
                    .store_xdata_sym => |x| x.src,
                    .push => |x| x.src,
                    else => unreachable,
                };
                if (byteVreg(s)) |sv| {
                    if (sv != v) return null;
                } else return null;
            },
            else => return null,
        }
        if (r.n >= MAX_OUT_USE) return null;
        r.idx[r.n] = i;
        r.ops[r.n] = op;
        r.n += 1;
    }
    if (r.n == 0) return null;
    return r;
}

fn norm(map: *const [MAX_MAP]u8, map_len: u8, v: u8) u8 {
    var i: u8 = 0;
    while (i < map_len) : (i += 1) if (map[i] == v) return i;
    return 0;
}

fn bit(k: u8) u64 {
    return @as(u64, 1) << @intCast(k);
}

/// 一条汇编指令的 8051 编码长度。用于「实测块字节」判据：把块真的编译
/// 成汇编文本再逐行数，宁可多花编译时间，也不用粗略估算决定要不要压缩。
fn lineBytes(line: []const u8) u32 {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len == 0 or t[0] == ';' or t[0] == '.' or std.mem.endsWith(u8, t, ":")) return 0;
    if (std.mem.startsWith(u8, t, "lcall") or std.mem.startsWith(u8, t, "ljmp")) return 3;
    if (std.mem.startsWith(u8, t, "mov dptr,#")) return 3;
    if (std.mem.startsWith(u8, t, "mov ")) {
        if (std.mem.startsWith(u8, t, "mov a,") or
            std.mem.startsWith(u8, t, "mov b,") or
            std.mem.endsWith(u8, t, ",a") or
            std.mem.endsWith(u8, t, ",b")) return 2;
        return 3; // mov direct,direct / mov direct,#imm
    }
    if (std.mem.startsWith(u8, t, "mul ab") or
        std.mem.startsWith(u8, t, "div ab") or
        std.mem.startsWith(u8, t, "clr c") or
        std.mem.startsWith(u8, t, "setb c") or
        std.mem.startsWith(u8, t, "clr a") or
        std.mem.startsWith(u8, t, "cpl a") or
        std.mem.startsWith(u8, t, "rlc a") or
        std.mem.startsWith(u8, t, "rrc a") or
        std.mem.startsWith(u8, t, "rl a") or
        std.mem.startsWith(u8, t, "rr a") or
        std.mem.startsWith(u8, t, "ret") or
        std.mem.startsWith(u8, t, "nop") or
        std.mem.startsWith(u8, t, "movx") or
        std.mem.startsWith(u8, t, "movc")) return 1;
    if (std.mem.startsWith(u8, t, "sjmp") or
        std.mem.startsWith(u8, t, "ajmp") or
        std.mem.startsWith(u8, t, "jc ") or
        std.mem.startsWith(u8, t, "jnc ") or
        std.mem.startsWith(u8, t, "jz ") or
        std.mem.startsWith(u8, t, "jnz ") or
        std.mem.startsWith(u8, t, "jb ") or
        std.mem.startsWith(u8, t, "jnb ") or
        std.mem.startsWith(u8, t, "jbc ")) return 2;
    if (std.mem.startsWith(u8, t, "djnz") or
        std.mem.startsWith(u8, t, "cjne") or
        std.mem.startsWith(u8, t, "push") or
        std.mem.startsWith(u8, t, "pop ")) return 3;
    return 2; // add/subb/anl/orl/xrl/inc/dec 的 direct 形式
}

/// 从 renderDef 产出的文本里数出共享例程本体的机器码字节数。
fn bodyBytes(def: []const u8) u32 {
    var total: u32 = 0;
    var it = std.mem.splitScalar(u8, def, '\n');
    while (it.next()) |line| total += lineBytes(line);
    return total;
}

/// 记下一个被读的 Byte：只关心块内的归一化槽。
fn noteRead(b: Byte, map: *const [MAX_MAP]u8, map_len: u8, reads: *u64) void {
    const v = byteVreg(b) orelse return;
    var k: u8 = 0;
    while (k < map_len) : (k += 1) {
        if (map[k] == v) {
            reads.* |= bit(k);
            return;
        }
    }
}

/// 扫描块之后的指令，收集仍会被读的槽。返回 false 表示遇到无法解析的
/// 形态，调用方应退回「块内写过的槽全部搬回」的保守口径。
fn afterReads(op: Op, map: *const [MAX_MAP]u8, map_len: u8, reads: *u64) bool {
    const s = opShape(op);
    if (s.ok) {
        for (s.slot, 0..) |maybe, j| {
            const b = maybe orelse continue;
            if (!s.is_write[j]) noteRead(b, map, map_len, reads);
        }
        return true;
    }
    return switch (op) {
        .store_dir => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            break :blk true;
        },
        .store_xdata => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            break :blk true;
        },
        .store_xdata_sym => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            break :blk true;
        },
        .store_xdata_idx => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            noteRead(x.idx, map, map_len, reads);
            break :blk true;
        },
        .store_xdata_idx_sym => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            noteRead(x.idx, map, map_len, reads);
            break :blk true;
        },
        .store_xdata_dptr => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            break :blk true;
        },
        .push => |x| blk: {
            noteRead(x.src, map, map_len, reads);
            break :blk true;
        },
        .cmp_br => |x| blk: {
            noteRead(x.lhs, map, map_len, reads);
            noteRead(x.rhs, map, map_len, reads);
            break :blk true;
        },
        .br_ifnz => |x| blk: {
            noteRead(x.cond, map, map_len, reads);
            break :blk true;
        },
        .br_ifz => |x| blk: {
            noteRead(x.cond, map, map_len, reads);
            break :blk true;
        },
        // 无 vreg 读的终结/控制类指令。`.lcall`/`.ljmp` 会间接用到共享槽，
        // 故意不列入：遇到它们就退回保守口径，避免漏搬输出。
        .ret, .halt, .clr_c, .br, .br_c, .bit_br, .reti, .label => true,
        else => false,
    };
}

/// 把一段块编码成指纹，同时算出归一化槽表、输入/输出位图。
/// 返回 false 表示这段块不合格（含非 vreg/imm 操作数、槽过多、块过长）。
fn encodeBlock(
    block: []const Op,
    key: *[KEY_CAP]u8,
    key_len: *usize,
    map: *[MAX_MAP]u8,
    map_len: *u8,
    inputs: *u64,
    outputs: *u64,
    complex_count: *u8,
) bool {
    if (block.len < MIN_BLOCK_OPS or block.len > MAX_BLOCK_OPS) return false;
    map_len.* = 0;
    inputs.* = 0;
    outputs.* = 0;
    complex_count.* = 0;

    // 第一遍：登记块内出现过的 vreg，按首次出现顺序归一化。
    for (block) |op| {
        const s = opShape(op);
        if (!s.ok) return false;
        if (s.complex) complex_count.* +|= 1;
        for (s.slot) |maybe| {
            const b = maybe orelse continue;
            if (byteVreg(b)) |v| {
                if (norm(map, map_len.*, v) == 0 and (map_len.* == 0 or map[0] != v)) {
                    if (map_len.* >= MAX_MAP) return false;
                    map[map_len.*] = v;
                    map_len.* += 1;
                }
            } else if (byteImm(b) == null) {
                // dir / sym：与函数地址环境绑定，不能共享
                return false;
            }
        }
    }
    // 「复杂算法」的硬定义：块内至少两个高成本运算（乘/除/多字节链/移位）。
    // 一条 add / anl / mov 本身就是 1～3 B，把它搬进子程序再用 lcall 调回来
    // 必然更大也更慢；这类廉价指令只在陪伴复杂算法时一并搬走，不单独成块。
    if (complex_count.* < 2) return false;

    // 第二遍：定长编码 + 读写集合。
    // `inputs` 取「块内首次访问是读」的槽：读-改-写槽（原地累加）也是输入，
    // 不能像早期版本那样用 reads & ~writes 把它剔除，否则非拥有者站点会
    // 搬到未初始化的共享槽，除法与宽局部量用例会静默算错。
    var seen: u64 = 0;
    var ins: u64 = 0;
    var writes: u64 = 0;
    var off: usize = 0;
    for (block) |op| {
        const s = opShape(op);
        if (off + 12 > KEY_CAP) return false;
        key[off] = s.tag;
        key[off + 1] = @truncate(s.n);
        key[off + 2] = @truncate(s.n >> 8);
        key[off + 3] = 0;
        for (s.is_write, 0..) |w, j| {
            if (w) key[off + 3] |= @as(u8, 1) << @intCast(j);
        }
        for (s.slot, 0..) |maybe, j| {
            var kind: u8 = 0;
            var val: u8 = 0;
            if (maybe) |b| {
                if (byteVreg(b)) |v| {
                    kind = 1;
                    val = norm(map, map_len.*, v);
                } else if (byteImm(b)) |v| {
                    kind = 2;
                    val = v;
                } else return false;
            }
            key[off + 4 + j * 2] = kind;
            key[off + 5 + j * 2] = val;
        }
        // 读写集合必须「先读后写」：rlc a / subb a 这类原地读改写指令的
        // dst 与 src 是同一个槽，若按 op 字段顺序先算写，会被误判成
        // 「块内新建的中间量」而不搬输入，除法循环因此静默算错。
        for (s.slot, 0..) |maybe, j| {
            if (s.is_write[j]) continue;
            const b = maybe orelse continue;
            const v = byteVreg(b) orelse continue;
            const k = norm(map, map_len.*, v);
            if (seen & bit(k) == 0) ins |= bit(k);
            seen |= bit(k);
        }
        for (s.slot, 0..) |maybe, j| {
            if (!s.is_write[j]) continue;
            const b = maybe orelse continue;
            const v = byteVreg(b) orelse continue;
            const k = norm(map, map_len.*, v);
            writes |= bit(k);
            seen |= bit(k);
        }
        off += 12;
    }
    key_len.* = off;
    inputs.* = ins;
    // 调用点真正需要的输出在 run 里再与「块后读取集合」求交；这里先给出
    // 保守上界，遇到无法解析的后续指令时直接用它。
    outputs.* = writes;
    return true;
}

const Cand = struct {
    start: usize,
    len: usize,
    key: [KEY_CAP]u8 = undefined,
    key_len: usize = 0,
    /// 同一函数内出现重复模板时整组放弃（见 run 第一遍的说明）。
    skip: bool = false,
    tpl: usize = 0,
    is_owner: bool = false,
    /// 已经原地重绑到拥有者槽的输入槽位图（不再需要搬运）。
    rebound: u64 = 0,
    /// 已经改成直接读拥有者槽的输出槽位图（不再需要搬出）。
    rebound_out: u64 = 0,
    cur_map: [MAX_MAP]u8 = undefined,
    map_len: u8 = 0,
    inputs: u64 = 0,
    outputs: u64 = 0,
};

/// 生成共享子程序定义文本。用 mcs51.lower + render（不跑窥孔，避免
/// 「写了但本函数内没读」的输出槽被当死代码删掉）。
fn renderDef(gpa: std.mem.Allocator, tpl: *const Tpl, block: []const Op) ![]u8 {
    const ops = try gpa.alloc(Op, block.len + 1);
    defer gpa.free(ops);
    @memcpy(ops[0..block.len], block);
    ops[block.len] = .ret;

    const f: mir.Function = .{
        .name = tpl.sym[1..tpl.sym_len],
        .profile = .mcs51_sdcc,
        .nregs = 0, // 槽声明已在拥有者函数的头部发过，这里不能重复 .ds
        .vreg_base = tpl.owner_base,
        .ops = ops,
    };
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var items = try mcs51.lower(f, aa, true);
    defer items.deinit(aa);
    return mcs51.render(gpa, items.items);
}

pub const Result = struct {
    /// 需要追加到本函数汇编文本之后的共享子程序定义。
    defs: std.ArrayListUnmanaged(u8) = .empty,
    /// 本函数被替换掉的块数、被压缩掉的原始 op 数（统计口径）。
    blocks: usize = 0,
    folded_ops: usize = 0,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        self.defs.deinit(gpa);
    }
};

/// 就地改写 ops：把命中的重复复杂算法块换成「参数搬运 + lcall」，
/// 首次出现的模板额外产出一份共享子程序定义文本。
pub fn run(
    gpa: std.mem.Allocator,
    ops: *std.ArrayListUnmanaged(Op),
    owner_base: u8,
    fn_name: []const u8,
) !Result {
    var res: Result = .{};
    errdefer res.deinit(gpa);
    if (!enabled) return res;

    var cands: std.ArrayListUnmanaged(Cand) = .empty;
    defer cands.deinit(gpa);

    const src = ops.items;
    if (dump) {
        var longest: usize = 0;
        var cur: usize = 0;
        for (src) |op| {
            if (opShape(op).ok) {
                cur += 1;
                if (cur > longest) longest = cur;
            } else cur = 0;
        }
        std.debug.print("FACTOR fn={s} ops={d} 最长纯段={d}\n", .{ fn_name, src.len, longest });
    }
    // 第一遍：找候选块。同一函数里出现两次以上的模板**整组放弃**：
    // 共享例程复用拥有者的槽，函数内第二个站点会把第一个站点的活值踩掉
    // （u32div / wloc2 的真实回归）。跨函数共享不受影响，每个函数最多
    // 贡献一个站点，仍是「统计重复算法 → 压到一处 → 跳转调用」的主场。
    var i: usize = 0;
    while (i < src.len) {
        if (!opShape(src[i]).ok) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < src.len and opShape(src[i]).ok) : (i += 1) {}
        if (i - start < MIN_BLOCK_OPS) continue;

        var key: [KEY_CAP]u8 = undefined;
        var key_len: usize = 0;
        var map: [MAX_MAP]u8 = undefined;
        var map_len: u8 = 0;
        var inputs: u64 = 0;
        var outputs: u64 = 0;
        var complex: u8 = 0;
        if (!encodeBlock(src[start..i], &key, &key_len, &map, &map_len,
            &inputs, &outputs, &complex)) continue;

        // 只把「块之后仍会被读」的槽搬回调用点：块内的中间量（如 16 位乘
        // 的三个部分积）留在共享槽里即可，不必每个站点各搬一次。
        // 遇到无法解析的后续指令就退回「块内写过的槽全部搬回」。
        var after: u64 = 0;
        var known = true;
        for (src[i..]) |op| {
            if (!afterReads(op, &map, map_len, &after)) {
                known = false;
                break;
            }
        }
        if (known) outputs &= after;

        var dup = false;
        for (cands.items) |*prev| {
            if (prev.skip) continue;
            if (prev.key_len == key_len and
                std.mem.eql(u8, prev.key[0..key_len], key[0..key_len]))
            {
                prev.skip = true;
                dup = true;
                break;
            }
        }
        if (dup) continue;

        var cd: Cand = .{
            .start = start,
            .len = i - start,
            .cur_map = map,
            .map_len = map_len,
            .inputs = inputs,
            .outputs = outputs,
        };
        @memcpy(cd.key[0..key_len], key[0..key_len]);
        cd.key_len = key_len;
        try cands.append(gpa, cd);
    }

    // 第二遍：注册模板、生成共享例程定义、决定每个站点的搬运集合。
    for (cands.items) |*cd| {
        if (cd.skip) continue;
        const key = cd.key[0..cd.key_len];

        var t: ?usize = null;
        var t_i: usize = 0;
        while (t_i < tpl_n) : (t_i += 1) {
            if (tpls[t_i].key_len == cd.key_len and
                std.mem.eql(u8, tpls[t_i].key[0..cd.key_len], key))
            {
                t = t_i;
                break;
            }
        }
        var is_owner = false;
        if (t == null) {
            if (tpl_n >= MAX_TPL) {
                cd.skip = true;
                continue;
            }
            const n = tpl_n;
            var e = &tpls[n];
            @memcpy(e.key[0..cd.key_len], key);
            e.key_len = cd.key_len;
            e.sym_len = (std.fmt.bufPrint(&e.sym, "_mcs_sh_{d}", .{n}) catch unreachable).len;
            e.owner_base = owner_base;
            const name_len = @min(fn_name.len, e.owner_name.len);
            @memcpy(e.owner_name[0..name_len], fn_name[0..name_len]);
            e.owner_name_len = name_len;
            @memcpy(e.map[0..cd.map_len], cd.cur_map[0..cd.map_len]);
            e.map_len = cd.map_len;
            e.inputs = cd.inputs;
            e.outputs = cd.outputs;
            e.block_len = cd.len;
            e.hits = 0;

            // 精确收益判据：把块真的编译成汇编，逐条数出 8051 机器码字节。
            //
            // 判据要回答的是「N=2 时会不会变大」。N=2 的两个站点里，拥有者
            // 零搬运（只多一条 lcall），另一个站点的搬运量取决于它的槽是不是
            // 块专用临时量——注册模板时还不知道，所以按**悲观上界**
            // `(入+出)×3 + 3` 估。再要求净省 16 B 作为安全垫，覆盖 body 定义处
            // 的 `.globl` 与段切换等固定开销。
            //
            // 实测分界：`mul.zig` 本体 36 B / 入4出2 → 门槛 34 B，通过
            // （125 → 93 B）；`div.zig` 本体 35 B / 入6出4 → 门槛 46 B 拦下
            // （共享后持平）；`cordic_sin.zig` 本体 40 B / 入12出4 → 门槛 64 B
            // 拦下（共享后 +16 B）。
            const def = try renderDef(gpa, e, src[cd.start .. cd.start + cd.len]);
            defer gpa.free(def);
            const ins: u32 = @intCast(@popCount(cd.inputs));
            const outs: u32 = @intCast(@popCount(cd.outputs));
            // 槽数上限：站点要搬 10 条以上的块，收益薄，而且共享例程对站点槽的
            // 复用关系会复杂到难以保证正确（CORDIC 的 atan2 就是「4 入 11 出」
            // 这一档出错的：共享后 cat90 / cat45 都返回 0）。宁可不压缩。
            if (ins + outs > MAX_SHARE_SLOTS) {
                cd.skip = true;
                continue;
            }
            const gate: u32 = (ins + outs) * 3 + 16;
            if (dump) {
                std.debug.print(
                    "FACTOR 判据 {s}: 本体 {d} B, 槽 入{d}/出{d}, 门槛 {d} B\n",
                    .{ fn_name, bodyBytes(def), ins, outs, gate },
                );
            }
            if (bodyBytes(def) < gate) {
                cd.skip = true; // tpl_n 不变，槽位留给下一个真正划算的模板
                continue;
            }
            tpl_n += 1;
            t = n;
            is_owner = true;
            try res.defs.appendSlice(gpa, "\n; mcs2 共享算法子程序（重复代码压缩）\n");
            try res.defs.appendSlice(gpa, def);
        }
        cd.tpl = t.?;
        cd.is_owner = is_owner;
        tpls[cd.tpl].hits += 1;
        res.blocks += 1;
        res.folded_ops += cd.len;
    }

    if (res.blocks == 0) return res;

    // 第三遍：站点槽重绑定。
    //
    // 原先非拥有者站点的形状是「`mov 私有槽, S` … `mov 拥有者槽, 私有槽`」，
    // 16 位算子的 4 个参数字节要搬 4 条 `mov dir,dir`（12 B），比 SDCC 多花
    // 一倍的站点开销。若私有槽是**块专用临时量**（块前只被写一次、块后彻底
    // 死掉），把那条定义的目的地直接换成拥有者槽就等价于「搬家」，站点连
    // 一次搬运都不用付——直接消掉这 12 B。
    //
    // 同一站点函数内按绝对槽去重：两个模板的拥有者槽可能落在同一个函数的
    // 同一批 vreg 上（两个块都用同一个参数），重绑两次会互相踩，放弃后者。
    var rewrite: []?Op = try gpa.alloc(?Op, src.len);
    defer gpa.free(rewrite);
    @memset(rewrite, null);
    var used_abs = [_]u64{ 0, 0, 0, 0 };
    for (cands.items) |*cd| {
        if (cd.skip or cd.is_owner) continue;
        const e = &tpls[cd.tpl];
        var k: u8 = 0;
        while (k < cd.map_len) : (k += 1) {
            if (cd.inputs & bit(k) == 0) continue;
            const rb = reboundDef(
                src,
                cd.start,
                cd.start + cd.len,
                cd.cur_map[k],
                &cd.cur_map,
                cd.map_len,
            ) orelse continue;
            const abs = e.owner_base +% e.map[k];
            const word = @as(usize, abs) >> 6;
            const mask = @as(u64, 1) << @intCast(abs & 63);
            if (used_abs[word] & mask != 0) continue;
            used_abs[word] |= mask;
            rewrite[rb.idx] = .{ .mov = .{
                .dst = .{ .sym = slotName(abs) },
                .src = rb.src,
            } };
            cd.rebound |= bit(k);
        }

        // 输出侧同理：块后所有使用都是纯读时，把读取源直接指向拥有者槽，
        // `mov 站点槽, 拥有者槽` 的搬出也一并省掉。
        const end = cd.start + cd.len;
        k = 0;
        while (k < cd.map_len) : (k += 1) {
            if (cd.outputs & bit(k) == 0) continue;
            if (cd.rebound & bit(k) != 0) continue;
            const ob = reboundOut(src, end, cd.cur_map[k], &cd.cur_map, cd.map_len) orelse continue;
            const abs = e.owner_base +% e.map[k];
            const word = @as(usize, abs) >> 6;
            const mask = @as(u64, 1) << @intCast(abs & 63);
            if (used_abs[word] & mask != 0) continue;
            used_abs[word] |= mask;
            const sym = slotName(abs);
            var j: u8 = 0;
            while (j < ob.n) : (j += 1) {
                const nw = rebindOutOp(ob.ops[j], sym) orelse break;
                rewrite[ob.idx[j]] = nw;
            }
            cd.rebound_out |= bit(k);
        }
    }

    // 重建 ops：候选区间换成调用序列。
    var out: std.ArrayListUnmanaged(Op) = .empty;
    errdefer out.deinit(gpa);
    var p: usize = 0;
    var c: usize = 0;
    while (p < src.len) {
        if (c < cands.items.len and cands.items[c].start == p) {
            const cd = cands.items[c];
            c += 1;
            if (cd.skip) {
                // 本函数内重复的模板整组保持内联，原样拷回。
                try out.appendSlice(gpa, src[p .. p + cd.len]);
                p += cd.len;
                continue;
            }
            const e = &tpls[cd.tpl];
            const sym: []const u8 = e.sym[0..e.sym_len];
            // 拥有者自身无需搬运：共享例程用的就是它的槽。
            if (!cd.is_owner) {
                var k: u8 = 0;
                while (k < cd.map_len) : (k += 1) {
                    if (cd.inputs & bit(k) == 0) continue;
                    // 已重绑的输入：值在块前就直接写进了拥有者槽，不必再搬。
                    if (cd.rebound & bit(k) != 0) continue;
                    const abs = e.owner_base +% e.map[k];
                    try out.append(gpa, .{ .mov = .{
                        .dst = .{ .sym = slotName(abs) },
                        .src = .{ .vreg = cd.cur_map[k] },
                    } });
                }
            }
            try out.append(gpa, .{ .lcall = .{ .sym = sym } });
            if (!cd.is_owner) {
                var k: u8 = 0;
                while (k < cd.map_len) : (k += 1) {
                    if (cd.outputs & bit(k) == 0) continue;
                    if (cd.rebound_out & bit(k) != 0) continue;
                    const abs = e.owner_base +% e.map[k];
                    try out.append(gpa, .{ .mov = .{
                        .dst = .{ .vreg = cd.cur_map[k] },
                        .src = .{ .sym = slotName(abs) },
                    } });
                }
            }
            p += cd.len;
            continue;
        }
        try out.append(gpa, rewrite[p] orelse src[p]);
        p += 1;
    }

    ops.deinit(gpa);
    ops.* = out;
    return res;
}

/// 统计输出：模板编号、命中站点数、块大小、拥有者函数。
pub fn dumpStats() void {
    if (!dump or tpl_n == 0) return;
    std.debug.print("== mcs2 重复算法统计（{d} 个模板）==\n", .{tpl_n});
    var i: usize = 0;
    while (i < tpl_n) : (i += 1) {
        const e = &tpls[i];
        std.debug.print("  {s}: 站点 {d}, 块 {d} op, 槽基线 {d}, 拥有者 {s}\n", .{
            e.sym[0..e.sym_len], e.hits, e.block_len, e.owner_base,
            e.owner_name[0..e.owner_name_len],
        });
    }
}

/// 仅供测试：清空会话级注册表。
pub fn resetForTest() void {
    tpl_n = 0;
}
