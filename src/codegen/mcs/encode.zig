//! 面向自举 Zig 后端的 MCS-251 / MCS-51 汇编文本编码。
//!
//! 后端不直接产出目标字节：它产出 ASxxxx 汇编文本，交由 `sdas251`/`sdas8051`
//! 汇编成 `.rel`，再由 `sdld` 链接（见 `PLAN.md`）。因此本模块提供一条指令的
//! *文本* 形式：助记符加上带类型的操作数。
//!
//! 合法操作数形式的规范集合（65 个指令族、269 种形式，含 Source 与 Binary 模式
//! opcode）存放在 `forms.zig`，由 SDCC `sdas251` 的 ISA 矩阵生成。本模块覆盖代码
//! 生成实际需要的操作数形态；若日后增加直接二进制编码器，表就是 opcode 字节的权威。
//!
//! 语法遵循 SDCC 汇编器，例如：
//!
//!     mov  a,r6
//!     mov  r5,#0x5a
//!     mov  dptr,#0x1234
//!     add  wr4,wr10
//!     mov  r3,@wr6+0x1234
//!     cjne a,#0x5a,0x1234
//!     jnb  0x30.5,label

const std = @import("std");
const forms = @import("forms.zig");

pub const Form = forms.Form;

/// 65 个 MCS-251 指令族。顺序与 ISA 矩阵所用的逻辑分组一致（见 `forms.families`）。
pub const Mnemonic = enum {
    add,
    sub,
    addc,
    subb,
    cmp,
    inc,
    dec,
    mul,
    div,
    da,
    orl,
    anl,
    xrl,
    clr,
    cpl,
    rl,
    rlc,
    rr,
    rrc,
    sra,
    srl,
    sll,
    swap,
    mov,
    movh,
    movs,
    movz,
    movc,
    movx,
    xch,
    xchd,
    push,
    pop,
    setb,
    acall,
    ecall,
    lcall,
    ret,
    eret,
    reti,
    ajmp,
    ejmp,
    ljmp,
    sjmp,
    jmp,
    jc,
    jnc,
    jz,
    jnz,
    je,
    jne,
    jg,
    jle,
    jsl,
    jsle,
    jsg,
    jsge,
    jbc,
    jb,
    jnb,
    cjne,
    djnz,
    trap,
    nop,
    esc,

    pub fn name(m: Mnemonic) []const u8 {
        return @tagName(m);
    }
};

/// 硬件寄存器或寄存器组。
///
/// `r` 为 R0-R15；`wr` 是偶对齐的字寄存器，按*索引*寻址（索引 2 即 WR4，
/// 索引 5 即 WR10）；`dr` 是 4 字节对齐的双字寄存器，按索引寻址（索引 3 即 DR12）。
pub const Register = union(enum) {
    a,
    ab,
    b,
    c,
    cy,
    dptr,
    dph,
    dpl,
    dpx,
    dpxl,
    sp,
    spx,
    psw,
    r: u4,
    wr: u4,
    dr: u4,

    pub fn format(reg: Register, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (reg) {
            .a => try w.writeAll("a"),
            .ab => try w.writeAll("ab"),
            .b => try w.writeAll("b"),
            .c, .cy => try w.writeAll("cy"),
            .dptr => try w.writeAll("dptr"),
            .dph => try w.writeAll("dph"),
            .dpl => try w.writeAll("dpl"),
            .dpx => try w.writeAll("dpx"),
            .dpxl => try w.writeAll("dpxl"),
            .sp => try w.writeAll("sp"),
            .spx => try w.writeAll("spx"),
            .psw => try w.writeAll("psw"),
            .r => |n| w.print("r{d}", .{n}) catch return error.WriteFailed,
            .wr => |idx| w.print("wr{d}", .{@as(u32, idx) * 2}) catch return error.WriteFailed,
            .dr => |idx| w.print("dr{d}", .{@as(u32, idx) * 4}) catch return error.WriteFailed,
        }
    }
};

/// 直接地址：数字常量、符号引用或局部数字标签。
pub const Address = union(enum) {
    value: u32,
    symbol: []const u8,
    /// `base+offset` 形式的符号位移（如 `?frk0+5`）。
    symbol_off: struct {
        base: []const u8,
        off: i32,
    },
    /// 局部数字标签，输出为 `L{n}`。
    local_label: u32,

    pub fn format(a: Address, w: *std.Io.Writer, min_hex_digits: u8) std.Io.Writer.Error!void {
        switch (a) {
            .value => |v| switch (min_hex_digits) {
                2 => w.print("0x{x:0>2}", .{v}) catch return error.WriteFailed,
                4 => w.print("0x{x:0>4}", .{v}) catch return error.WriteFailed,
                else => w.print("0x{x}", .{v}) catch return error.WriteFailed,
            },
            .symbol => |s| try w.writeAll(s),
            .symbol_off => |so| {
                try w.writeAll(so.base);
                if (so.off > 0) {
                    w.print("+{d}", .{so.off}) catch return error.WriteFailed;
                } else if (so.off < 0) {
                    w.print("-{d}", .{-so.off}) catch return error.WriteFailed;
                }
            },
            .local_label => |n| w.print("L{d}", .{n}) catch return error.WriteFailed,
        }
    }
};

/// 指定位宽的立即数。
pub const Immediate = struct {
    value: i32,
    bits: u8,
};

/// ASxxxx 语法中的一条指令操作数。
pub const Operand = union(enum) {
    reg: Register,
    /// 8 位直接地址（`dir8`）。
    dir8: Address,
    /// 16 位直接地址（`dir16`）。
    dir16: Address,
    /// 24 位直接地址（`dir24`）。
    dir24: Address,
    /// `#data` 立即数。
    imm: Immediate,
    /// `#symbol` 立即数地址（如 `mov dptr,#_gv`）。
    imm_symbol: Address,
    /// `#(symbol >> 8)`：24 位地址的中间字节（`addc a,#(_sym >> 8)`）。
    imm_symbol_mid: Address,
    /// `#(symbol >> 16)`：24 位数据指针的高字节（`mov dpxl,#(_gv >> 16)`）。
    imm_symbol_hi: Address,
    /// `@Ri`。
    at_ri: u1,
    /// `@DPTR`。
    at_dptr,
    /// `@A+DPTR`（MOVC/JMP）。
    at_a_dptr,
    /// `@A+PC`（MOVC）。
    at_a_pc,
    /// `@WRj`，索引为字寄存器索引。
    at_wr: u4,
    /// `@DRk`，索引为双字寄存器索引。
    at_dr: u4,
    /// `@WRj+dis16` 或 `@DRk+dis24`（由 base 决定）。
    index: struct {
        base: Register,
        disp: i32,
    },
    /// 位操作数 `addr.bit`。
    bit: struct {
        addr: Address,
        bit: u3,
    },
    /// 取反的位操作数 `/addr.bit`（ANL/ORL CY）。
    not_bit: struct {
        addr: Address,
        bit: u3,
    },
    /// 跳转、调用或分支的代码空间目标。
    code: Address,

    pub fn format(op: Operand, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (op) {
            .reg => |r| try r.format(w),
            .dir8 => |a| try a.format(w, 2),
            .dir16 => |a| try a.format(w, 4),
            .dir24 => |a| try a.format(w, 6),
            .imm => |imm| try formatImmediate(w, imm),
            .imm_symbol => |a| {
                try w.writeByte('#');
                try a.format(w, 6);
            },
            .imm_symbol_mid => |a| {
                try w.writeAll("#(");
                try a.format(w, 6);
                try w.writeAll(" >> 8)");
            },
            .imm_symbol_hi => |a| {
                try w.writeAll("#(");
                try a.format(w, 6);
                try w.writeAll(" >> 16)");
            },
            .at_ri => |n| w.print("@r{d}", .{n}) catch return error.WriteFailed,
            .at_dptr => try w.writeAll("@dptr"),
            .at_a_dptr => try w.writeAll("@a+dptr"),
            .at_a_pc => try w.writeAll("@a+pc"),
            .at_wr => |idx| w.print("@wr{d}", .{@as(u32, idx) * 2}) catch return error.WriteFailed,
            .at_dr => |idx| w.print("@dr{d}", .{@as(u32, idx) * 4}) catch return error.WriteFailed,
            .index => |ix| {
                try w.writeByte('@');
                try ix.base.format(w);
                try formatDisplacement(w, ix.disp);
            },
            .bit => |b| {
                try b.addr.format(w, 2);
                w.print(".{d}", .{b.bit}) catch return error.WriteFailed;
            },
            .not_bit => |b| {
                try w.writeByte('/');
                try b.addr.format(w, 2);
                w.print(".{d}", .{b.bit}) catch return error.WriteFailed;
            },
            .code => |a| try a.format(w, 6),
        }
    }
};

fn formatImmediate(w: *std.Io.Writer, imm: Immediate) std.Io.Writer.Error!void {
    try w.writeByte('#');
    if (imm.value < 0) {
        // 与 ISA 矩阵示例一致，负数用十进制表示（如 `#-3`）。
        w.print("-{d}", .{-imm.value}) catch return error.WriteFailed;
        return;
    }
    const mask: u32 = if (imm.bits >= 32) 0xffff_ffff else (@as(u32, 1) << @intCast(imm.bits)) - 1;
    const v: u32 = @as(u32, @intCast(imm.value)) & mask;
    switch (imm.bits) {
        8 => w.print("0x{x:0>2}", .{v}) catch return error.WriteFailed,
        16 => w.print("0x{x:0>4}", .{v}) catch return error.WriteFailed,
        24 => w.print("0x{x:0>6}", .{v}) catch return error.WriteFailed,
        else => w.print("0x{x}", .{v}) catch return error.WriteFailed,
    }
}

fn formatDisplacement(w: *std.Io.Writer, disp: i32) std.Io.Writer.Error!void {
    if (disp == 0) return;
    if (disp < 0) {
        w.print("-0x{x}", .{@as(u32, @intCast(-disp))}) catch return error.WriteFailed;
    } else {
        w.print("+0x{x}", .{@as(u32, @intCast(disp))}) catch return error.WriteFailed;
    }
}

/// 输出完整的一行指令（不含缩进与换行）：小写助记符，随后是以逗号分隔的操作数。
pub fn formatInst(
    w: *std.Io.Writer,
    mnemonic: Mnemonic,
    operands: []const Operand,
) std.Io.Writer.Error!void {
    try w.writeAll(mnemonic.name());
    if (operands.len != 0) {
        try w.writeByte(' ');
        for (operands, 0..) |op, i| {
            if (i != 0) try w.writeByte(',');
            try op.format(w);
        }
    }
}

/// 返回 `assembly` 列等于给定文本的规范形式。用于测试与诊断，不用于代码生成。
pub fn findFormByAssembly(text: []const u8) ?Form {
    for (forms.forms) |f| {
        if (std.mem.eql(u8, f.assembly, text)) return f;
    }
    return null;
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectFormat(expected: []const u8, mnemonic: Mnemonic, operands: []const Operand) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try formatInst(&aw.writer, mnemonic, operands);
    try testing.expectEqualStrings(expected, aw.written());
}

fn expectRegister(expected: []const u8, reg: Register) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try reg.format(&aw.writer);
    try testing.expectEqualStrings(expected, aw.written());
}

test "寄存器操作数格式" {
    try expectRegister("a", Register{ .a = {} });
    try expectRegister("r6", Register{ .r = 6 });
    try expectRegister("wr10", Register{ .wr = 5 });
    try expectRegister("dr12", Register{ .dr = 3 });
    try expectRegister("cy", Register{ .cy = {} });
}

test "代表性指令的格式" {
    try expectFormat("nop", .nop, &.{});
    try expectFormat("ret", .ret, &.{});
    try expectFormat("mul ab", .mul, &.{.{ .reg = .ab }});
    try expectFormat("inc dptr", .inc, &.{.{ .reg = .dptr }});
    try expectFormat("mov a,r6", .mov, &.{ .{ .reg = .a }, .{ .reg = .{ .r = 6 } } });
    try expectFormat("mov r5,#0x5a", .mov, &.{
        .{ .reg = .{ .r = 5 } },
        .{ .imm = .{ .value = 0x5a, .bits = 8 } },
    });
    try expectFormat("mov dptr,#0x1234", .mov, &.{
        .{ .reg = .dptr },
        .{ .imm = .{ .value = 0x1234, .bits = 16 } },
    });
    try expectFormat("add wr4,wr10", .add, &.{
        .{ .reg = .{ .wr = 2 } },
        .{ .reg = .{ .wr = 5 } },
    });
    try expectFormat("mov r10,@wr6+0x1234", .mov, &.{
        .{ .reg = .{ .r = 10 } },
        .{ .index = .{ .base = .{ .wr = 3 }, .disp = 0x1234 } },
    });
    try expectFormat("mov @dr16,r3", .mov, &.{
        .{ .at_dr = 4 },
        .{ .reg = .{ .r = 3 } },
    });
    try expectFormat("cjne a,#0x5a,0x1234", .cjne, &.{
        .{ .reg = .a },
        .{ .imm = .{ .value = 0x5a, .bits = 8 } },
        .{ .code = .{ .value = 0x1234 } },
    });
    try expectFormat("jnb 0x30.5,label", .jnb, &.{
        .{ .bit = .{ .addr = .{ .value = 0x30 }, .bit = 5 } },
        .{ .code = .{ .symbol = "label" } },
    });
    try expectFormat("anl cy,/0x30.5", .anl, &.{
        .{ .reg = .cy },
        .{ .not_bit = .{ .addr = .{ .value = 0x30 }, .bit = 5 } },
    });
    try expectFormat("movc a,@a+dptr", .movc, &.{ .{ .reg = .a }, .at_a_dptr });
}

test "立即数位宽与负值" {
    try expectFormat("push #0x1234", .push, &.{
        .{ .imm = .{ .value = 0x1234, .bits = 16 } },
    });
    try expectFormat("mov dr12,#-3", .mov, &.{
        .{ .reg = .{ .dr = 3 } },
        .{ .imm = .{ .value = -3, .bits = 16 } },
    });
    try expectFormat("push #0x5a", .push, &.{
        .{ .imm = .{ .value = 0x5a, .bits = 8 } },
    });
}

test "直接地址" {
    try expectFormat("mov a,0x30", .mov, &.{ .{ .reg = .a }, .{ .dir8 = .{ .value = 0x30 } } });
    try expectFormat("mov a,0x0001", .mov, &.{ .{ .reg = .a }, .{ .dir16 = .{ .value = 1 } } });
    try expectFormat("mov a,SYMBOL", .mov, &.{ .{ .reg = .a }, .{ .dir16 = .{ .symbol = "SYMBOL" } } });
    try expectFormat("sjmp L7", .sjmp, &.{.{ .code = .{ .local_label = 7 } }});
}

test "ISA 矩阵完整性" {
    // 65 个指令族、269 种合法形式（见 sdas/as251/tests/instruction-families.txt）。
    try testing.expectEqual(@as(usize, 65), forms.families.len);
    try testing.expectEqual(@as(usize, 269), forms.forms.len);

    // 每个指令族都必须对应一个 `Mnemonic` 枚举值。
    for (forms.families) |fam| {
        try testing.expect(std.meta.stringToEnum(Mnemonic, fam) != null);
    }
    try testing.expectEqual(@as(usize, 65), forms.families.len);

    for (forms.forms) |f| {
        var found = false;
        for (forms.families) |fam| {
            if (std.mem.eql(u8, fam, f.mnemonic)) found = true;
        }
        try testing.expect(found);
        // 每种形式都有具体的汇编示例。
        try testing.expect(f.assembly.len != 0);
        // opcode 数组非空：即使是 `esc`，也是单字节 0xa5。
        try testing.expect(f.source_bytes.len != 0);
        try testing.expect(f.binary_bytes.len != 0);
    }
}

test "按汇编文本查找形式" {
    try testing.expect(findFormByAssembly("mov a,r6") != null);
    try testing.expect(findFormByAssembly("this is not an instruction") == null);
}
