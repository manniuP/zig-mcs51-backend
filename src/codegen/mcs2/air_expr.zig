//! M0：AIR 表达式 → Zig 源码文本渲染器。
//!
//! 只依赖 std，便于单独 `zig test`。本层只负责「给定已解析好的操作数后怎么拼代码」；
//! `Air.Inst.Tag → Tag` 的映射与遍历指令、解析载荷留到 M1。
//! 未知形态或缺操作数一律返回 null，调用方据此回退改写骨架，绝不猜测代码。
const std = @import("std");

pub const Tag = enum {
    arg,
    integer,
    load,
    add,
    add_safe,
    add_wrap,
    sub,
    sub_safe,
    sub_wrap,
    mul,
    mul_safe,
    mul_wrap,
    div_trunc,
    rem,
    bit_and,
    bit_or,
    xor,
    shl,
    shr,
    cmp_lt,
    cmp_lte,
    cmp_gt,
    cmp_gte,
    cmp_eq,
    cmp_neq,
    int_cast,
    trunc,
    not_,
    call,
    /// 白名单之外的形态：必须返回 null。
    unknown,
};

/// 已渲染好的子表达式：lhs/rhs 是二元运算两侧，operand 是一元运算的操作数。
pub const Expr = struct {
    lhs: []const u8 = "",
    rhs: []const u8 = "",
    operand: []const u8 = "",
    /// 参数名 / 变量名 / 函数名。
    name: []const u8 = "",
    /// 整数字面量。
    value: ?u64 = null,
    /// 调用的实参（已渲染）。
    args: []const []const u8 = &.{},
};

fn fmt(gpa: std.mem.Allocator, comptime f: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(gpa, f, args);
}

fn bin(gpa: std.mem.Allocator, op: []const u8, e: Expr) !?[]u8 {
    if (e.lhs.len == 0 or e.rhs.len == 0) return null;
    return try fmt(gpa, "{s} {s} {s}", .{ e.lhs, op, e.rhs });
}

fn unary(gpa: std.mem.Allocator, comptime f: []const u8, e: Expr) !?[]u8 {
    if (e.operand.len == 0) return null;
    return try fmt(gpa, f, .{e.operand});
}

/// 返回新分配的字符串（调用方释放）；不可渲染时返回 null。
pub fn render(gpa: std.mem.Allocator, tag: Tag, e: Expr) !?[]u8 {
    return switch (tag) {
        .arg, .load => if (e.name.len == 0) null else try fmt(gpa, "{s}", .{e.name}),
        .integer => if (e.value) |v| try fmt(gpa, "{d}", .{v}) else null,

        // 安全档渲染成普通运算符（保持原码语义）；只有 *_wrap 才带 % 回绕。
        .add, .add_safe => try bin(gpa, "+", e),
        .add_wrap => try bin(gpa, "+%", e),
        .sub, .sub_safe => try bin(gpa, "-", e),
        .sub_wrap => try bin(gpa, "-%", e),
        .mul, .mul_safe => try bin(gpa, "*", e),
        .mul_wrap => try bin(gpa, "*%", e),
        .div_trunc => try bin(gpa, "/", e),
        .rem => try bin(gpa, "%", e),
        .bit_and => try bin(gpa, "&", e),
        .bit_or => try bin(gpa, "|", e),
        .xor => try bin(gpa, "^", e),
        .shl => try bin(gpa, "<<", e),
        .shr => try bin(gpa, ">>", e),
        .cmp_lt => try bin(gpa, "<", e),
        .cmp_lte => try bin(gpa, "<=", e),
        .cmp_gt => try bin(gpa, ">", e),
        .cmp_gte => try bin(gpa, ">=", e),
        .cmp_eq => try bin(gpa, "==", e),
        .cmp_neq => try bin(gpa, "!=", e),

        .int_cast => try unary(gpa, "@intCast({s})", e),
        .trunc => try unary(gpa, "@truncate({s})", e),
        .not_ => try unary(gpa, "~{s}", e),

        .call => blk: {
            if (e.name.len == 0) break :blk null;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, e.name);
            try out.append(gpa, '(');
            for (e.args, 0..) |a, i| {
                if (i > 0) try out.appendSlice(gpa, ", ");
                try out.appendSlice(gpa, a);
            }
            try out.append(gpa, ')');
            break :blk try out.toOwnedSlice(gpa);
        },

        .unknown => null,
    };
}

test "二元运算：安全档与回绕档" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { tag: Tag, lhs: []const u8, rhs: []const u8, want: []const u8 }{
        .{ .tag = .add, .lhs = "n", .rhs = "1", .want = "n + 1" },
        .{ .tag = .add_safe, .lhs = "n", .rhs = "1", .want = "n + 1" },
        .{ .tag = .add_wrap, .lhs = "n", .rhs = "1", .want = "n +% 1" },
        .{ .tag = .sub_safe, .lhs = "n", .rhs = "1", .want = "n - 1" },
        .{ .tag = .sub_wrap, .lhs = "n", .rhs = "1", .want = "n -% 1" },
        .{ .tag = .mul_wrap, .lhs = "n", .rhs = "2", .want = "n *% 2" },
        .{ .tag = .cmp_lte, .lhs = "n", .rhs = "1", .want = "n <= 1" },
        .{ .tag = .cmp_eq, .lhs = "a", .rhs = "b", .want = "a == b" },
        .{ .tag = .bit_or, .lhs = "a", .rhs = "b", .want = "a | b" },
    };
    for (cases) |c| {
        const s = (try render(gpa, c.tag, .{ .lhs = c.lhs, .rhs = c.rhs })).?;
        defer gpa.free(s);
        try std.testing.expectEqualStrings(c.want, s);
    }
}

test "原子与一元" {
    const gpa = std.testing.allocator;
    const a = (try render(gpa, .arg, .{ .name = "n" })).?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("n", a);

    const c = (try render(gpa, .integer, .{ .value = 42 })).?;
    defer gpa.free(c);
    try std.testing.expectEqualStrings("42", c);

    const t = (try render(gpa, .trunc, .{ .operand = "x" })).?;
    defer gpa.free(t);
    try std.testing.expectEqualStrings("@truncate(x)", t);

    const n = (try render(gpa, .not_, .{ .operand = "x" })).?;
    defer gpa.free(n);
    try std.testing.expectEqualStrings("~x", n);
}

test "调用" {
    const gpa = std.testing.allocator;
    const s = (try render(gpa, .call, .{
        .name = "f__tail",
        .args = &.{ "n - 1", "acc + 1" },
    })).?;
    defer gpa.free(s);
    try std.testing.expectEqualStrings("f__tail(n - 1, acc + 1)", s);
}

test "未知形态或缺操作数一律返回 null" {
    const gpa = std.testing.allocator;
    try std.testing.expect((try render(gpa, .unknown, .{})) == null);
    try std.testing.expect((try render(gpa, .add, .{ .lhs = "n" })) == null);
    try std.testing.expect((try render(gpa, .arg, .{})) == null);
    try std.testing.expect((try render(gpa, .integer, .{})) == null);
    try std.testing.expect((try render(gpa, .call, .{})) == null);
    try std.testing.expect((try render(gpa, .trunc, .{})) == null);
}
