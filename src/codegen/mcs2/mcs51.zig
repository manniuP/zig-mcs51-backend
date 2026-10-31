//! MCS51 汇编发射（最小切片）。
//!
//! 当前策略：
//!   - 虚拟寄存器一律 DSEG 直接地址（`_mcs_vN`）；ABI 寄存器是直接地址；
//!   - 算术经 A，右操作数直接用 `dir8`（`add a,dir8` 合法）；
//!   - 不做寄存器分配、不做帧布局、不做调用。
//!
//! 统一管线（selftest 通道与编译器通道共用，杜绝两套文本路径漂移）：
//!   `lower(f)` → 条目流 → `optimize`（窥孔，`peephole.enabled`）→
//!   `render` → 汇编文本。
//!
//! 这是可执行的最小合同，不是最终质量。

const std = @import("std");
const mir = @import("mir.zig");
const debug = @import("debug.zig");
const peephole = @import("peephole.zig");

const Byte = mir.Byte;

/// 条目流元素：窥孔操作的最小结构。
/// `line.jump` 非空表示这是跳转指令，文本 = `{text} L{jump}`。
pub const Item = union(enum) {
    label: u32,
    line: struct {
        text: []const u8,
        jump: ?u32,
    },
    raw: []const u8,
};

/// Byte 的汇编文本：vreg = `_mcs_vN`，dir = `0xNN`。
fn byteText(gpa: std.mem.Allocator, b: Byte) ![]const u8 {
    return switch (b) {
        .vreg => |n| std.fmt.allocPrint(gpa, "_mcs_v{d}", .{n}),
        // 0x00-0x07 = bank0 的工作寄存器：渲染成 rN 才能拿到 1 字节编码
        // （mov a,r6 是 1B，mov a,0x06 是 2B）。DSEG 从 0x30 起，不会与数据冲突。
        .dir => |a| if (a < 8)
            std.fmt.allocPrint(gpa, "r{d}", .{a})
        else
            std.fmt.allocPrint(gpa, "0x{X:0>2}", .{a}),
        .sym => |s| s,
        .imm => |v| std.fmt.allocPrint(gpa, "#0x{X:0>2}", .{v}),
    };
}

/// 操作数文本是不是工作寄存器（r0-r7）。
fn isRegText(s: []const u8) bool {
    if (s.len != 2) return false;
    if (s[0] != 'r' and s[0] != 'R') return false;
    return s[1] >= '0' and s[1] <= '7';
}

/// Op 序列 → 条目流（不做窥孔）。
/// `with_header`：true = 含 DSEG 声明 + `.globl` + 函数标签（selftest 通道）；
/// false = 编译器通道（Asx 链接层已发 `.globl` 与标签，这里只发
/// DSEG 声明 + CSEG 切回 + 函数体，避免双重定义）。
/// DPTR 当前内容：固定地址，或「基址 + 下标」。相邻同址访问可以省掉重建。
const DptrState = union(enum) {
    fixed: u16,
    idx: struct { base: u16, idx: Byte },
};

fn sameByte(a: Byte, b: Byte) bool {
    return switch (a) {
        .vreg => |x| switch (b) {
            .vreg => |y| x == y,
            else => false,
        },
        .dir => |x| switch (b) {
            .dir => |y| x == y,
            else => false,
        },
        .imm => |x| switch (b) {
            .imm => |y| x == y,
            else => false,
        },
        .sym => |x| switch (b) {
            .sym => |y| std.mem.eql(u8, x, y),
            else => false,
        },
    };
}

fn sameDptr(st: ?DptrState, want: DptrState) bool {
    const s = st orelse return false;
    return switch (s) {
        .fixed => |a| switch (want) {
            .fixed => |b| a == b,
            else => false,
        },
        .idx => |a| switch (want) {
            .idx => |b| a.base == b.base and sameByte(a.idx, b.idx),
            else => false,
        },
    };
}

fn touchesDplDph(b: Byte) bool {
    return switch (b) {
        .dir => |d| d == 0x82 or d == 0x83,
        else => false,
    };
}

fn writesVreg(b: Byte, v: u8) bool {
    return switch (b) {
        .vreg => |x| x == v,
        else => false,
    };
}

/// 每条指令之后 DPTR 是否还有效（null = 失效）。
fn dptrAfter(op: mir.Op, prev: ?DptrState) ?DptrState {
    // 下标 vreg 被改写 → 失效
    const idx_v: ?u8 = blk: {
        const s = prev orelse break :blk null;
        break :blk switch (s) {
            .idx => |i| switch (i.idx) {
                .vreg => |v| v,
                else => null,
            },
            else => null,
        };
    };
    if (idx_v) |v| {
        const wrote = switch (op) {
            .imm => |x| writesVreg(x.dst, v),
            .mov => |x| writesVreg(x.dst, v),
            .add => |x| writesVreg(x.dst, v),
            .sub => |x| writesVreg(x.dst, v),
            .and_ => |x| writesVreg(x.dst, v),
            .or_ => |x| writesVreg(x.dst, v),
            .xor_ => |x| writesVreg(x.dst, v),
            .load_dir => |x| writesVreg(x.dst, v),
            .load_xdata => |x| writesVreg(x.dst, v),
            .load_xdata_idx => |x| writesVreg(x.dst, v),
            .dec => |x| x == v,
            .dec_br_nz => |x| writesVreg(x.dst, v),
            else => false,
        };
        if (wrote) return null;
    }

    return switch (op) {
        .load_xdata => |x| .{ .fixed = x.addr },
        .store_xdata => |x| .{ .fixed = x.addr },
        .load_xdata_idx => |x| .{ .idx = .{ .base = x.base, .idx = x.idx } },
        .store_xdata_idx => |x| .{ .idx = .{ .base = x.base, .idx = x.idx } },
        .imm => |x| if (touchesDplDph(x.dst)) null else prev,
        .mov => |x| if (touchesDplDph(x.dst)) null else prev,
        .add => |x| if (touchesDplDph(x.dst)) null else prev,
        .sub => |x| if (touchesDplDph(x.dst)) null else prev,
        .and_ => |x| if (touchesDplDph(x.dst)) null else prev,
        .or_ => |x| if (touchesDplDph(x.dst)) null else prev,
        .xor_ => |x| if (touchesDplDph(x.dst)) null else prev,
        .load_dir => |x| if (touchesDplDph(x.dst)) null else prev,
        .store_dir => |x| if (x.addr == 0x82 or x.addr == 0x83) null else prev,
        .push => |x| if (touchesDplDph(x.src)) null else prev,
        .pop => |x| if (touchesDplDph(x.dst)) null else prev,
        .dec => prev,
        .label, .br, .br_ifnz, .br_ifz, .cmp_br, .dec_br_nz, .ret, .reti, .halt => null,
    };
}

pub fn lower(f: mir.Function, gpa: std.mem.Allocator, with_header: bool) !std.ArrayListUnmanaged(Item) {
    var items: std.ArrayListUnmanaged(Item) = .empty;
    errdefer items.deinit(gpa);
    // DPTR 复用：只在 xdata 访问时建地址，相邻同址访问跳过重建。
    var dptr: ?DptrState = null;

    try items.appendSlice(gpa, &.{
        .{ .raw = "; mcs2 slice" },
        .{ .raw = try std.fmt.allocPrint(gpa, "; profile: {s}, pointer bytes: {d}", .{
            @tagName(f.profile), mir.pointerBytes(f.profile),
        }) },
        .{ .raw = "; 由 src/codegen/mcs2/mcs51.zig 生成，非完整后端" },
        .{ .raw = "" },
    });

    // 最小切片只允许 51 profile；251 需要自己的发射器。
    if (f.profile != .mcs51_sdcc) {
        @panic("mcs2: mcs51.zig 只接受 mcs51_sdcc profile");
    }

    // 虚拟寄存器先一律落 DSEG；正式后端必须由放置/分配决定。
    // 边界 ABI 的静态参数区符号（_name_PARM_n）也声明在这里（SDCC 同款）。
    try items.append(gpa, .{ .raw = "    .area DSEG (DATA)" });
    var i: u8 = 0;
    while (i < f.nregs) : (i += 1) {
        try items.append(gpa, .{ .raw = try std.fmt.allocPrint(
            gpa,
            "_mcs_v{d}: .ds 1",
            .{f.vreg_base + i},
        ) });
    }
    for (f.parms) |psym| {
        try items.append(gpa, .{ .raw = try std.fmt.allocPrint(
            gpa,
            "    .globl {s}",
            .{psym},
        ) });
        try items.append(gpa, .{ .raw = try std.fmt.allocPrint(
            gpa,
            "{s}: .ds 1",
            .{psym},
        ) });
    }

    try items.append(gpa, .{ .raw = "" });
    try items.append(gpa, .{ .raw = "    .area CSEG (CODE)" });
    if (with_header) {
        try items.append(gpa, .{ .raw = try std.fmt.allocPrint(gpa, "    .globl _{s}", .{f.name}) });
        try items.append(gpa, .{ .raw = try std.fmt.allocPrint(gpa, "_{s}:", .{f.name}) });
    }

    // vreg → 全局编号（同模块多函数 DSEG 不撞名）。
    const byteOf = struct {
        fn map(b: Byte, base: u8) Byte {
            return switch (b) {
                .vreg => |n| .{ .vreg = base + n },
                else => b,
            };
        }
    }.map;

    for (f.ops) |op| {
        const m_op: mir.Op = switch (op) {
            .imm => |x| .{ .imm = .{ .dst = byteOf(x.dst, f.vreg_base), .value = x.value } },
            .add => |x| .{ .add = .{ .dst = byteOf(x.dst, f.vreg_base), .lhs = byteOf(x.lhs, f.vreg_base), .rhs = byteOf(x.rhs, f.vreg_base) } },
            .sub => |x| .{ .sub = .{ .dst = byteOf(x.dst, f.vreg_base), .lhs = byteOf(x.lhs, f.vreg_base), .rhs = byteOf(x.rhs, f.vreg_base) } },
            .dec => |r| .{ .dec = f.vreg_base + r },
            .load_dir => |x| .{ .load_dir = .{ .dst = byteOf(x.dst, f.vreg_base), .addr = x.addr } },
            .store_dir => |x| .{ .store_dir = .{ .addr = x.addr, .src = byteOf(x.src, f.vreg_base) } },
            .store_xdata => |x| .{ .store_xdata = .{ .addr = x.addr, .src = byteOf(x.src, f.vreg_base) } },
            .mov => |x| .{ .mov = .{ .dst = byteOf(x.dst, f.vreg_base), .src = byteOf(x.src, f.vreg_base) } },
            .br_ifnz => |x| .{ .br_ifnz = .{ .cond = byteOf(x.cond, f.vreg_base), .target = x.target } },
            .br_ifz => |x| .{ .br_ifz = .{ .cond = byteOf(x.cond, f.vreg_base), .target = x.target } },
            .dec_br_nz => |x| .{ .dec_br_nz = .{ .dst = byteOf(x.dst, f.vreg_base), .target = x.target } },
            .cmp_br => |x| .{ .cmp_br = .{
                .lhs = byteOf(x.lhs, f.vreg_base),
                .rhs = byteOf(x.rhs, f.vreg_base),
                .cc = x.cc,
                .target = x.target,
            } },
            .push => |x| .{ .push = .{ .src = byteOf(x.src, f.vreg_base) } },
            .pop => |x| .{ .pop = .{ .dst = byteOf(x.dst, f.vreg_base) } },
            .load_xdata => |x| .{ .load_xdata = .{ .dst = byteOf(x.dst, f.vreg_base), .addr = x.addr } },
            .load_xdata_idx => |x| .{ .load_xdata_idx = .{
                .dst = byteOf(x.dst, f.vreg_base),
                .base = x.base,
                .idx = byteOf(x.idx, f.vreg_base),
            } },
            .store_xdata_idx => |x| .{ .store_xdata_idx = .{
                .base = x.base,
                .idx = byteOf(x.idx, f.vreg_base),
                .src = byteOf(x.src, f.vreg_base),
            } },
            .and_ => |x| .{ .and_ = .{ .dst = byteOf(x.dst, f.vreg_base), .lhs = byteOf(x.lhs, f.vreg_base), .rhs = byteOf(x.rhs, f.vreg_base) } },
            .or_ => |x| .{ .or_ = .{ .dst = byteOf(x.dst, f.vreg_base), .lhs = byteOf(x.lhs, f.vreg_base), .rhs = byteOf(x.rhs, f.vreg_base) } },
            .xor_ => |x| .{ .xor_ = .{ .dst = byteOf(x.dst, f.vreg_base), .lhs = byteOf(x.lhs, f.vreg_base), .rhs = byteOf(x.rhs, f.vreg_base) } },
            .label, .br, .ret, .reti, .halt => op,
        };
        // 这次 xdata 访问想要的 DPTR 内容；与当前一致就不重建。
        const want_dptr: ?DptrState = switch (m_op) {
            .load_xdata => |x| .{ .fixed = x.addr },
            .store_xdata => |x| .{ .fixed = x.addr },
            .load_xdata_idx => |x| .{ .idx = .{ .base = x.base, .idx = x.idx } },
            .store_xdata_idx => |x| .{ .idx = .{ .base = x.base, .idx = x.idx } },
            else => null,
        };
        const reuse_dptr = if (want_dptr) |w| sameDptr(dptr, w) else false;

        switch (m_op) {
            .imm => |x| {
                const d = try byteText(gpa, x.dst);
                switch (x.dst) {
                    // 直址立即数一条搞定（mov dir,#imm），比经 A 中转短 1 字节。
                    .dir => try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                        gpa,
                        "    mov {s},#0x{X:0>2}",
                        .{ d, x.value },
                    ), .jump = null } }),
                    else => {
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                            gpa,
                            "    mov a,#0x{X:0>2}",
                            .{x.value},
                        ), .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                            gpa,
                            "    mov {s},a",
                            .{d},
                        ), .jump = null } });
                    },
                }
            },
            .add => |x| {
                const l = try byteText(gpa, x.lhs);
                const r = try byteText(gpa, x.rhs);
                const d = try byteText(gpa, x.dst);
                // 自增 1：`inc dir` 一条（2B），省掉经 A 中转的两条（M2.12）。
                if (sameByte(x.dst, x.lhs)) {
                    switch (x.rhs) {
                        .imm => |v| if (v == 1) {
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    inc {s}", .{d}), .jump = null } });
                            dptr = dptrAfter(m_op, dptr);
                            continue;
                        },
                        else => {},
                    }
                }
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    add a,{s}", .{r}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .sub => |x| {
                const l = try byteText(gpa, x.lhs);
                const r = try byteText(gpa, x.rhs);
                const d = try byteText(gpa, x.dst);
                // 自减 1：`dec dir` 一条（2B）。
                if (sameByte(x.dst, x.lhs)) {
                    switch (x.rhs) {
                        .imm => |v| if (v == 1) {
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    dec {s}", .{d}), .jump = null } });
                            dptr = dptrAfter(m_op, dptr);
                            continue;
                        },
                        else => {},
                    }
                }
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = "    clr c", .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    subb a,{s}", .{r}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .mov => |x| {
                const d = try byteText(gpa, x.dst);
                const s = try byteText(gpa, x.src);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    mov {s},{s}",
                    .{ d, s },
                ), .jump = null } });
            },
            .dec => |r| {
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    dec _mcs_v{d}",
                    .{f.vreg_base + r},
                ), .jump = null } });
            },
            .load_xdata => |x| {
                const d = try byteText(gpa, x.dst);
                if (!reuse_dptr) {
                    try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov dptr,#0x{X:0>4}", .{x.addr}), .jump = null } });
                }
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = "    movx a,@dptr", .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .push => |x| {
                const s = try byteText(gpa, x.src);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    push {s}",
                    .{s},
                ), .jump = null } });
            },
            .pop => |x| {
                const d = try byteText(gpa, x.dst);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    pop {s}",
                    .{d},
                ), .jump = null } });
            },
            .reti => try items.append(gpa, .{ .line = .{ .text = "    reti", .jump = null } }),
            .load_dir => |x| {
                const d = try byteText(gpa, x.dst);
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,0x{X:0>2}", .{x.addr}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .store_dir => |x| {
                const s = try byteText(gpa, x.src);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    mov 0x{X:0>2},{s}",
                    .{ x.addr, s },
                ), .jump = null } });
            },
            .store_xdata => |x| {
                const s = try byteText(gpa, x.src);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{s}), .jump = null } });
                if (!reuse_dptr) {
                    try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov dptr,#0x{X:0>4}", .{x.addr}), .jump = null } });
                }
                try items.append(gpa, .{ .line = .{ .text = "    movx @dptr,a", .jump = null } });
            },
            .load_xdata_idx => |x| {
                const d = try byteText(gpa, x.dst);
                const it = try byteText(gpa, x.idx);
                if (!reuse_dptr) try emitDptrIndex(gpa, &items, x.base, it);
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = "    movx a,@dptr", .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .store_xdata_idx => |x| {
                const s = try byteText(gpa, x.src);
                const it = try byteText(gpa, x.idx);
                if (!reuse_dptr) try emitDptrIndex(gpa, &items, x.base, it);
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{s}), .jump = null } },
                    .{ .line = .{ .text = "    movx @dptr,a", .jump = null } },
                });
            },
            .and_ => |x| {
                const l = try byteText(gpa, x.lhs);
                const rr = try byteText(gpa, x.rhs);
                const d = try byteText(gpa, x.dst);
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    anl a,{s}", .{rr}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .or_ => |x| {
                const l = try byteText(gpa, x.lhs);
                const rr = try byteText(gpa, x.rhs);
                const d = try byteText(gpa, x.dst);
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    orl a,{s}", .{rr}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .xor_ => |x| {
                const l = try byteText(gpa, x.lhs);
                const rr = try byteText(gpa, x.rhs);
                const d = try byteText(gpa, x.dst);
                try items.appendSlice(gpa, &.{
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    xrl a,{s}", .{rr}), .jump = null } },
                    .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov {s},a", .{d}), .jump = null } },
                });
            },
            .label => |n| try items.append(gpa, .{ .label = n }),
            // 默认发长跳，布局后由 relaxJumps() 收缩（M2.3）。
            .br => |t| try items.append(gpa, .{ .line = .{ .text = "ljmp", .jump = t } }),
            .br_ifnz => |x| {
                // 8051 的 JZ/JNZ 只测 A；sdas8051 也不接受 `cjne 直址,#imm,rel`
                // （实测 Invalid Addressing Mode），所以仍走 mov a,src + jnz。
                const c = try byteText(gpa, x.cond);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    mov a,{s}",
                    .{c},
                ), .jump = null } });
                try items.append(gpa, .{ .line = .{ .text = "jnz", .jump = x.target } });
            },
            .br_ifz => |x| {
                const c = try byteText(gpa, x.cond);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    mov a,{s}",
                    .{c},
                ), .jump = null } });
                try items.append(gpa, .{ .line = .{ .text = "jz", .jump = x.target } });
            },
            .cmp_br => |x| {
                const l = try byteText(gpa, x.lhs);
                const r = try byteText(gpa, x.rhs);
                switch (x.cc) {
                    .lt, .ge => {
                        try items.append(gpa, .{ .line = .{ .text = "    clr c", .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    subb a,{s}", .{r}), .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = if (x.cc == .lt) "jc" else "jnc", .jump = x.target } });
                    },
                    .le, .gt => {
                        // b ? a 的借位即 a>b 的否定，交换操作数更省。
                        try items.append(gpa, .{ .line = .{ .text = "    clr c", .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{r}), .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    subb a,{s}", .{l}), .jump = null } });
                        try items.append(gpa, .{ .line = .{ .text = if (x.cc == .gt) "jc" else "jnc", .jump = x.target } });
                    },
                    .eq, .ne => {
                        // 不等且右侧是立即数：`cjne dir,#imm,rel` 单条（3B）。
                        const rhs_imm: ?u8 = switch (x.rhs) {
                            .imm => |v| v,
                            else => null,
                        };
                        if (x.cc == .ne and rhs_imm != null and rhs_imm.? != 0) {
                            // mov a,lhs; cjne a,#imm,rel（5B）比 mov+xrl+jnz（6B）省 1B
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } });
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                                gpa,
                                "    cjne a,#0x{X:0>2},",
                                .{rhs_imm.?},
                            ), .jump = x.target } });
                        } else if (x.cc == .ne and rhs_imm == null) {
                            // 与直址比较：mov a,lhs; cjne a,rhs,rel 同样省 1B
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } });
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                                gpa,
                                "    cjne a,{s},",
                                .{r},
                            ), .jump = x.target } });
                        } else {
                        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    mov a,{s}", .{l}), .jump = null } });
                        // 与 0 比较：A 本身就是要测的值，xrl 可省（xrl a,#0 不改 A）。
                        const cmp_zero = switch (x.rhs) {
                            .imm => |v| v == 0,
                            else => false,
                        };
                        if (!cmp_zero) {
                            try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(gpa, "    xrl a,{s}", .{r}), .jump = null } });
                        }
                        try items.append(gpa, .{ .line = .{ .text = if (x.cc == .eq) "jz" else "jnz", .jump = x.target } });
                        }
                    },
                }
            },
            .dec_br_nz => |x| {
                const d = try byteText(gpa, x.dst);
                try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
                    gpa,
                    "    djnz {s},",
                    .{d},
                ), .jump = x.target } });
            },
            .ret => try items.append(gpa, .{ .line = .{ .text = "    ret", .jump = null } }),
            .halt => {
                // `sjmp .`：跳转到自身死循环。目标不是局部标签（jump=null），
                // 窥孔的穿线/死块规则都不会碰它。
                try items.append(gpa, .{ .line = .{ .text = "    sjmp .", .jump = null } });
            },
        }
        dptr = dptrAfter(m_op, dptr);
    }

    compactJumpToNext(&items);

    try relaxJumps(gpa, &items);

    return items;
}


/// dptr = base + idx（16 位常量基址 + 8 位运行期下标）。
/// lo == 0 时不可能进位，直接 `mov dpl,idx`；否则用 add/addc 传播进位。
fn emitDptrIndex(
    gpa: std.mem.Allocator,
    items: *std.ArrayListUnmanaged(Item),
    base: u16,
    idx_text: []const u8,
) !void {
    const lo: u8 = @truncate(base);
    const hi: u8 = @truncate(base >> 8);
    if (lo == 0) {
        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
            gpa,
            "    mov dpl,{s}",
            .{idx_text},
        ), .jump = null } });
        try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
            gpa,
            "    mov dph,#0x{X:0>2}",
            .{hi},
        ), .jump = null } });
        return;
    }
    try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
        gpa,
        "    mov a,{s}",
        .{idx_text},
    ), .jump = null } });
    try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
        gpa,
        "    add a,#0x{X:0>2}",
        .{lo},
    ), .jump = null } });
    try items.append(gpa, .{ .line = .{ .text = "    mov dpl,a", .jump = null } });
    try items.append(gpa, .{ .line = .{ .text = try std.fmt.allocPrint(
        gpa,
        "    mov a,#0x{X:0>2}",
        .{hi},
    ), .jump = null } });
    try items.append(gpa, .{ .line = .{ .text = "    addc a,#0x00", .jump = null } });
    try items.append(gpa, .{ .line = .{ .text = "    mov dph,a", .jump = null } });
}

/// 指令字节数（M2.3 松弛用）。只覆盖本后端会发出的形态；
/// 未知指令按 3 字节保守估算（宁可高估，不低估）。
fn instrBytes(text: []const u8) usize {
    const t = std.mem.trimStart(u8, text, " \t");
    if (std.mem.startsWith(u8, t, "sjmp")) return 2;
    if (std.mem.startsWith(u8, t, "ljmp")) return 3;
    if (std.mem.startsWith(u8, t, "lcall")) return 3;
    if (std.mem.startsWith(u8, t, "j")) return 2; // jz/jnz/jc/jnc/jb/jnb
    if (std.mem.startsWith(u8, t, "ret")) return 1;
    if (std.mem.startsWith(u8, t, "nop")) return 1;
    if (std.mem.startsWith(u8, t, "clr")) return 2; // clr a / clr c 实为 1，取保守值
    if (std.mem.startsWith(u8, t, "movx")) return 1;
    if (std.mem.startsWith(u8, t, "mov")) {
        // mov a,#imm / mov a,dir / mov dir,a / mov dir,#imm / mov dir,dir / mov rN,...
        const comma = std.mem.indexOfScalar(u8, t, ',') orelse return 3;
        const dst = t[4..comma];
        const src = t[comma + 1 ..];
        const dst_is_a = std.mem.eql(u8, dst, "a");
        const src_is_a = std.mem.eql(u8, src, "a");
        const dst_reg = isRegText(dst);
        const src_reg = isRegText(src);
        if (src.len > 0 and src[0] == '#') {
            if (dst_is_a) return 2;
            if (dst_reg) return 2; // mov rN,#imm
            return 3;
        }
        if (dst_is_a or src_is_a) {
            // mov a,rN / mov rN,a 都是 1 字节
            if ((dst_is_a and src_reg) or (src_is_a and dst_reg)) return 1;
            return 2;
        }
        if (std.mem.startsWith(u8, src, "dptr")) return 3;
        return 3;
    }
    if (std.mem.startsWith(u8, t, "push") or std.mem.startsWith(u8, t, "pop")) return 2;
    if (std.mem.startsWith(u8, t, "djnz")) {
        // djnz rN,rel = 2 字节；djnz dir,rel = 3 字节
        const comma = std.mem.indexOfScalar(u8, t, ',') orelse return 3;
        const op = std.mem.trim(u8, t[4..comma], " ");
        return if (isRegText(op)) 2 else 3;
    }
    if (std.mem.startsWith(u8, t, "inc") or std.mem.startsWith(u8, t, "dec")) {
        const op = std.mem.trim(u8, t[3..], " ");
        return if (isRegText(op)) 1 else 2;
    }
    if (std.mem.startsWith(u8, t, "add") or std.mem.startsWith(u8, t, "subb") or
        std.mem.startsWith(u8, t, "xrl") or std.mem.startsWith(u8, t, "anl") or std.mem.startsWith(u8, t, "orl"))
    {
        // add a,rN 之类是 1 字节
        const comma = std.mem.indexOfScalar(u8, t, ',') orelse return 2;
        const op = std.mem.trim(u8, t[comma + 1 ..], " ");
        return if (isRegText(op)) 1 else 2;
    }
    return 3;
}


/// M2.2：删掉「跳到紧邻的下一个标签」的跳转（布局期 fallthrough 优化）。
/// 只处理 sjmp/ljmp 且目标就是下一条 label 的情形。
fn compactJumpToNext(items: *std.ArrayListUnmanaged(Item)) void {
    var w: usize = 0;
    var r: usize = 0;
    while (r < items.items.len) : (r += 1) {
        const it = items.items[r];
        var drop = false;
        switch (it) {
            .line => |l| {
                const t = std.mem.trimStart(u8, l.text, " \t");
                const is_jump = std.mem.startsWith(u8, t, "sjmp") or std.mem.startsWith(u8, t, "ljmp");
                if (is_jump) {
                    if (l.jump) |target| {
                        if (r + 1 < items.items.len) {
                            switch (items.items[r + 1]) {
                                .label => |n| if (n == target) {
                                    drop = true;
                                },
                                else => {},
                            }
                        }
                    }
                }
            },
            else => {},
        }
        if (!drop) {
            items.items[w] = it;
            w += 1;
        }
    }
    items.shrinkRetainingCapacity(w);
}

/// 条件跳转取反（长距离展开用）。
fn invertCond(t: []const u8) ?[]const u8 {
    const pairs = [_][2][]const u8{
        .{ "jz", "jnz" },  .{ "jnz", "jz" },
        .{ "jc", "jnc" },  .{ "jnc", "jc" },
        .{ "jb", "jnb" },  .{ "jnb", "jb" },
    };
    for (pairs) |pr| if (std.mem.eql(u8, t, pr[0])) return pr[1];
    return null;
}

/// M2.3 跳转松弛：
///   1) 条件跳转超出 ±128 → 展开成「反条件跳过 + ljmp」（结构变更，重算一轮）；
///   2) 无条件跳转在 ljmp(3B)/sjmp(2B) 间迭代收敛。
fn relaxJumps(gpa: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item)) !void {
    var round: usize = 0;
    while (round < 16) : (round += 1) {
        // 1) 算地址
        var label_off = std.AutoHashMapUnmanaged(u32, usize){};
        defer label_off.deinit(gpa);
        var cur: usize = 0;
        for (items.items) |item| switch (item) {
            .label => |n| try label_off.put(gpa, n, cur),
            .line => |l| cur += instrBytes(l.text),
            .raw => |t| cur += t.len,
        };

        // 2) 条件跳转越界 → 展开（结构变更）
        var max_label: u32 = 0;
        for (items.items) |item| switch (item) {
            .label => |n| max_label = @max(max_label, n),
            else => {},
        };
        var expanded = false;
        {
            var out: std.ArrayListUnmanaged(Item) = .empty;
            errdefer out.deinit(gpa);
            var off: usize = 0;
            for (items.items) |item| switch (item) {
                .label => |n| {
                    try out.append(gpa, .{ .label = n });
                },
                .raw => |t| {
                    try out.append(gpa, .{ .raw = t });
                    off += t.len;
                },
                .line => |l| {
                    const t = std.mem.trimStart(u8, l.text, " \t");
                    const size = instrBytes(l.text);
                    var emit_item = true;
                    if (invertCond(t)) |inv| {
                        if (l.jump) |target| if (label_off.get(target)) |toff| {
                            const delta: isize = @as(isize, @intCast(toff)) - @as(isize, @intCast(off + size));
                            if (delta < -128 or delta > 127) {
                                max_label += 1;
                                const skip = max_label;
                                try out.append(gpa, .{ .line = .{ .text = inv, .jump = skip } });
                                try out.append(gpa, .{ .line = .{ .text = "ljmp", .jump = target } });
                                try out.append(gpa, .{ .label = skip });
                                expanded = true;
                                emit_item = false;
                            }
                        };
                    }
                    if (emit_item) try out.append(gpa, .{ .line = l });
                    off += size;
                },
            };
            if (expanded) {
                items.deinit(gpa);
                items.* = out;
                continue;
            }
            out.deinit(gpa);
        }

        // 3) 无条件跳转收缩/放宽
        var changed = false;
        var off: usize = 0;
        for (items.items) |*item| switch (item.*) {
            .label => {},
            .raw => |t| off += t.len,
            .line => |*l| {
                const t = std.mem.trimStart(u8, l.text, " \t");
                const is_s = std.mem.startsWith(u8, t, "sjmp");
                const is_l = std.mem.startsWith(u8, t, "ljmp");
                if ((is_s or is_l) and l.jump != null) {
                    const size: usize = if (is_s) 2 else 3;
                    if (label_off.get(l.jump.?)) |target| {
                        const delta: isize = @as(isize, @intCast(target)) - @as(isize, @intCast(off + size));
                        const fits = delta >= -128 and delta <= 127;
                        if (fits and is_l) {
                            l.text = "sjmp";
                            changed = true;
                        } else if (!fits and is_s) {
                            l.text = "ljmp";
                            changed = true;
                        }
                    }
                }
                off += instrBytes(l.text);
            },
        };
        if (!changed) break;
    }
}

/// 窥孔（条目流上）。`peephole.enabled/diag` 控制开关与统计。
pub fn optimize(gpa: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item)) void {
    if (peephole.enabled) {
        peephole.run(gpa, items, peephole.diag);
    }
}

/// 一站式：Op 序列 → 条目流 → 窥孔 → 汇编文本。
/// 中间量走 arena，只把最终文本交给调用方；selftest 与编译器通道共用。
pub fn compile(f: mir.Function, gpa: std.mem.Allocator) ![]u8 {
    return compileEx(f, gpa, true);
}

pub fn compileEx(f: mir.Function, gpa: std.mem.Allocator, with_header: bool) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();
    var items = try lower(f, aa, with_header);
    optimize(aa, &items);
    compactJumpToNext(&items);
    return render(gpa, items.items);
}

/// 条目流 → 汇编文本（调用方持有内存）。
pub fn render(gpa: std.mem.Allocator, items: []const Item) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (items) |item| switch (item) {
        .label => |n| {
            const s = try std.fmt.allocPrint(gpa, "L{d}:\n", .{n});
            try out.appendSlice(gpa, s);
            gpa.free(s);
        },
        .raw => |text| {
            try out.appendSlice(gpa, text);
            try out.appendSlice(gpa, "\n");
        },
        .line => |l| {
            const s = if (l.jump) |t|
                try std.fmt.allocPrint(gpa, "    {s} L{d}\n", .{ l.text, t })
            else
                try std.fmt.allocPrint(gpa, "{s}\n", .{l.text});
            try out.appendSlice(gpa, s);
            gpa.free(s);
        },
    };
    return out.toOwnedSlice(gpa);
}

/// 不生成调试信息的入口（selftest 通道：输出到 stderr）。
pub fn emit(f: mir.Function) void {
    emitWithDebug(f, null) catch unreachable;
}

/// 生成汇编，并可把调试信息交给调用方提供的 sink。
///
/// 当前 `debug.zig` 只有接口与测试桩；SDCC `.cdb` 编码器**尚未实现**。
/// 该签名先固定下来，避免后续为了接调试信息再改所有发射路径。
pub fn emitWithDebug(f: mir.Function, sink: ?debug.Sink) !void {
    const gpa = std.heap.page_allocator; // 工具进程：一次发射、随进程回收
    const text = try compile(f, gpa);
    defer gpa.free(text);
    std.debug.print("{s}", .{text});

    // 只登记函数符号；行号/地址布局尚未实现。
    // 未来 `.cdb` 编码器从同一份 DebugInfo 读取，而不是解析汇编文本。
    if (sink) |s| {
        const symbols = [_]debug.Symbol{
            .{ .name = f.name, .kind = .function },
        };
        const info = debug.DebugInfo{ .symbols = &symbols };
        try s.emit(&info);
    }
}

test "emit compiles for mcs51 profile" {
    // 仅验证数据类型/switch 可编译；文本输出由 tools/mcs2/verify.py 验证。
    const f = mir.selftest();
    try std.testing.expectEqual(mir.Profile.mcs51_sdcc, f.profile);
}

test "emit accepts a debug sink" {
    var called: usize = 0;
    const Ctx = struct {
        fn bump(ctx: *anyopaque, _: *const debug.DebugInfo) anyerror!void {
            const p: *usize = @ptrCast(@alignCast(ctx));
            p.* += 1;
        }
    };
    // 不真正输出汇编，只验证 sink 接口能到达。
    const sink = debug.Sink{ .context = @ptrCast(&called), .emit_fn = Ctx.bump };
    try emitWithDebug(mir.selftest(), sink);
    try std.testing.expectEqual(@as(usize, 1), called);
}

test "lower renders ABI add without prologue" {
    // add(a,b)：参数在 DPL/DPH 原地参与运算，结果单消费者 ret 直接写 DPL。
    const ops = [_]mir.Op{
        .{ .add = .{ .dst = mir.v(0), .lhs = .{ .dir = mir.abi.dpl }, .rhs = .{ .dir = mir.abi.dph } } },
        .{ .store_dir = .{ .addr = mir.abi.dpl, .src = mir.v(0) } },
        .{ .ret = {} },
    };
    const f: mir.Function = .{ .name = "add", .profile = .mcs51_sdcc, .nregs = 1, .ops = &ops };
    const gpa = std.testing.allocator;
    const text = try compile(f, gpa);
    defer gpa.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "    mov a,0x82") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    add a,0x83") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "    ret") != null);
}
