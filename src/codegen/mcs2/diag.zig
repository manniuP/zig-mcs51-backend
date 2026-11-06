//! 编译期改写建议。
//!
//! 后端的「拒绝」不能只讲道理：错误信息里要给出**能直接粘贴的 Zig 代码**，
//! 并且用上真实的导出函数名、参数类型与返回类型。这里只负责拼文本，
//! 不依赖 Zcu / AIR，便于单独测试与复用。
const std = @import("std");

pub const Kind = enum {
    /// 非尾递归：改成尾递归（累加器参数）或循环。
    tail_rec,
    /// 多字节 / 有符号乘法的溢出检查尚未实现。
    mul_safe,
    /// 数据地址当整数（@intFromPtr(&buf[0])）。
    data_addr,
    /// const 常量表的多维下标。
    const_multi_dim,
    /// switch 判定值 > 8 位。
    switch_wide,
    /// 间接调用参数合计 > 4 字节。
    ind_call_args,
    /// 单个参数 > 4 字节。
    param_over4,
};

const Buf = std.ArrayListUnmanaged(u8);

fn add(out: *Buf, gpa: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(gpa, s);
}

fn addf(out: *Buf, gpa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(gpa, fmt, args);
    defer gpa.free(s);
    try out.appendSlice(gpa, s);
}

/// 优先用源码里的真实参数名；拿不到才退回 a0/a1。buf 只在本次调用期间有效。
fn argName(pnames: ?[]const []const u8, i: usize, buf: *[16]u8) []const u8 {
    if (pnames) |ns| return ns[i];
    return std.fmt.bufPrint(buf, "a{d}", .{i}) catch unreachable;
}

/// `n: u8, m: u16` 形式的形参声明。
fn paramDecl(gpa: std.mem.Allocator, params: []const []const u8, pnames: ?[]const []const u8) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);
    var nbuf: [16]u8 = undefined;
    for (params, 0..) |p, i| {
        if (i > 0) try add(&out, gpa, ", ");
        try addf(&out, gpa, "{s}: {s}", .{ argName(pnames, i, &nbuf), p });
    }
    return out.toOwnedSlice(gpa);
}

/// `n, m` 形式的实参列表。
fn paramArgs(gpa: std.mem.Allocator, params: []const []const u8, pnames: ?[]const []const u8) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);
    var nbuf: [16]u8 = undefined;
    for (params, 0..) |_, i| {
        if (i > 0) try add(&out, gpa, ", ");
        try addf(&out, gpa, "{s}", .{argName(pnames, i, &nbuf)});
    }
    return out.toOwnedSlice(gpa);
}

/// 从源码里找 `fn <name>(...)`，抽出真实参数名。找不到或数量不符返回 null。
/// 返回的字符串直接指向源码缓冲（由 Zcu 持有），调用方只需释放外层数组。
pub fn paramNamesFromSource(
    gpa: std.mem.Allocator,
    src: []const u8,
    name: []const u8,
    count: usize,
) !?[]const []const u8 {
    if (count == 0) return null;
    const needle = try std.fmt.allocPrint(gpa, "fn {s}(", .{name});
    defer gpa.free(needle);
    const open = std.mem.indexOf(u8, src, needle) orelse return null;
    const start = open + needle.len;
    const close = std.mem.indexOfScalarPos(u8, src, start, ')') orelse return null;
    const list = std.mem.trim(u8, src[start..close], " \t\r\n");
    const names = try gpa.alloc([]const u8, count);
    errdefer gpa.free(names);
    var it = std.mem.splitScalar(u8, list, ',');
    var i: usize = 0;
    while (it.next()) |raw| {
        if (i >= count) break;
        const seg = std.mem.trim(u8, raw, " \t\r\n");
        const colon = std.mem.indexOfScalar(u8, seg, ':') orelse return null;
        const nm = std.mem.trim(u8, seg[0..colon], " \t\r\n");
        if (nm.len == 0) return null;
        for (nm) |c| {
            const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
                (c >= '0' and c <= '9') or c == '_';
            if (!ok) return null;
        }
        names[i] = nm;
        i += 1;
    }
    if (i != count) {
        gpa.free(names);
        return null;
    }
    return names;
}

/// M1：从 AIR 还原出来的现场信息。三处都是真实的源码片段，
/// 推不出来就留空，对应位置退回占位符。
pub const Extra = struct {
    /// 整条 return 表达式的源码，例如 `f(n - 1) * 2`。
    expr: []const u8 = "",
    /// 递归调用**之后**的运算，例如 `* 2`（形如 `<运算符> <操作数>`）。
    post: []const u8 = "",
    /// 递归调用的实参源码，例如 `n - 1`。
    args_src: []const u8 = "",
};

/// 生成完整建议文本。调用方负责释放返回值。
pub fn render(
    gpa: std.mem.Allocator,
    kind: Kind,
    name: []const u8,
    params: []const []const u8,
    pnames: ?[]const []const u8,
    ret: []const u8,
    extra: ?Extra,
) ![]u8 {
    var out: Buf = .empty;
    errdefer out.deinit(gpa);

    const decl = try paramDecl(gpa, params, pnames);
    defer gpa.free(decl);
    const args = try paramArgs(gpa, params, pnames);
    defer gpa.free(args);
    var nbuf: [16]u8 = undefined;
    const first: []const u8 = if (params.len > 0) argName(pnames, 0, &nbuf) else "0";

    switch (kind) {
        .tail_rec => {
            try add(&out, gpa,
                "非尾递归不受支持：参数区与局部槽是静态分配的，内层调用会覆盖外层的值，结果错且不报错。\n");
            if (extra) |x| {
                if (x.expr.len != 0) {
                    try add(&out, gpa, "从 AIR 还原，这个函数实际写的是：\n    return ");
                    try add(&out, gpa, x.expr);
                    try add(&out, gpa, ";\n");
                    if (x.post.len != 0) {
                        try addf(&out, gpa,
                            "调用之后还要做「{s}」，所以结尾的 ljmp 跳不回自己。\n", .{x.post});
                    }
                    try add(&out, gpa, "\n");
                }
            }
            try add(&out, gpa,
                "把「递归调用之后才做的运算」搬进累加器参数，让调用出现在 return 位置（mcs2 会把它编成循环）：\n\n");
            try addf(&out, gpa, "export fn {s}({s}) {s} {{\n", .{ name, decl, ret });
            if (params.len > 0) {
                try addf(&out, gpa, "    return {s}__tail({s}, 0);\n", .{ name, args });
            } else {
                try addf(&out, gpa, "    return {s}__tail(0);\n", .{name});
            }
            try add(&out, gpa, "}\n");
            try addf(&out, gpa, "fn {s}__tail(", .{name});
            if (params.len > 0) {
                try addf(&out, gpa, "{s}, ", .{decl});
            }
            try addf(&out, gpa, "acc: {s}) {s} {{\n", .{ ret, ret });
            try add(&out, gpa, "    if (/* 原基准条件 */) return acc;\n    return ");
            try addf(&out, gpa, "{s}__tail(", .{name});
            if (extra) |x| {
                if (x.args_src.len != 0) {
                    try add(&out, gpa, x.args_src);
                } else {
                    try add(&out, gpa, "/* 原递归实参 */");
                }
                try add(&out, gpa, ", acc");
                if (x.post.len != 0) {
                    // 递归调用之后的单一运算可以直接结合到累加器上：
                    // f(n)=f(n-1) ⊕ X  ⟺  g(n,acc)=g(n-1, acc ⊕ X)，与 ⊕ 是否
                    // 满足结合律无关（逐层降下来本就是同一运算的串接）。
                    try addf(&out, gpa, " {s}", .{x.post});
                } else {
                    try add(&out, gpa, " /* 再 ⊕ 原调用后的运算 */");
                }
            } else {
                try addf(&out, gpa, "/* 原递归实参 */, acc /* 再 ⊕ 原调用后的运算 */", .{});
            }
            try add(&out, gpa, ");\n}\n\n");
            try add(&out, gpa, "或者直接写成循环（代码更短，不用多一个函数）：\n\n");
            try addf(&out, gpa, "export fn {s}({s}) {s} {{\n", .{ name, decl, ret });
            try addf(&out, gpa, "    var acc: {s} = 0;\n", .{ret});
            try addf(&out, gpa, "    var cur = {s};\n", .{first});
            try add(&out, gpa,
                "    while (!(/* 原基准条件 */)) : (cur -= 1) {\n" ++
                "        acc +%= /* 原调用后的运算 */;\n" ++
                "    }\n" ++
                "    return acc + /* 原基准返回值 */;\n" ++
                "}\n");
        },
        .mul_safe => {
            try add(&out, gpa,
                "ReleaseSafe 下多字节 / 有符号乘法的溢出检查尚未实现；直接回绕会静默算错。\n" ++
                "按需要的语义二选一：\n\n" ++
                "// ① 明确要回绕：用 *%，安全档不插检查\n" ++
                "const r = a *% b;\n\n" ++
                "// ② 要自己处理溢出：拿到溢出位，命中就停机（与后端 panic 路径一致）\n" ++
                "const ov = @mulWithOverflow(a, b);\n" ++
                "if (ov[1] != 0) {\n" ++
                "    while (true) {}\n" ++
                "}\n" ++
                "const r2 = ov[0];\n");
        },
        .data_addr => {
            try add(&out, gpa,
                "只支持把「函数地址」转成整数；数据地址（&buf[0]）暂不支持。\n" ++
                "把缓冲区地址存表里，用编译期固定地址或全局数组名即可：\n\n" ++
                "// ① 固定地址（DMA / 环形队列常用）\n" ++
                "const BUF_ADDR: u16 = 0x8000;\n" ++
                "const p: [*]volatile u8 = @ptrFromInt(BUF_ADDR);\n" ++
                "p[0] = 0x12;\n\n" ++
                "// ② 只是想按下标访问全局数组：直接写名字，不必取地址\n" ++
                "var buf: [16]u8 = undefined;   // XRAM 掉电即失，运行时自己填\n" ++
                "fn at(i: u8) u8 { return buf[i]; }\n");
        },
        .const_multi_dim => {
            try add(&out, gpa,
                "const 表（代码段 .db + movc）只支持一维下标。把二维展平成一维，用「行 × 列数 + 列」算下标：\n\n" ++
                "const COLS: usize = 4;\n" ++
                "const tbl = [_]u8{\n" ++
                "    // 按行顺序把原来的二维初值铺开\n" ++
                "};\n" ++
                "fn at(row: usize, col: usize) u8 {\n" ++
                "    return tbl[row * COLS + col];\n" ++
                "}\n");
        },
        .switch_wide => {
            try add(&out, gpa,
                "switch 判定值只支持 8 位（256 种命令足够）；>8 位请拆成「字节表 + 函数指针表」分派：\n\n" ++
                "const Cmd = enum(u8) { read, write };\n" ++
                "fn h_read(v: u8) u8  { return v; }\n" ++
                "fn h_write(v: u8) u8 { return v +% 1; }\n" ++
                "const handlers = [_]fn (u8) u8{ h_read, h_write };\n\n" ++
                "fn dispatch(cmd: u16) u8 {\n" ++
                "    const op: u8  = @truncate(cmd >> 8);\n" ++
                "    const arg: u8 = @truncate(cmd);\n" ++
                "    if (op >= handlers.len) return 0;   // catch-all，防越界\n" ++
                "    return handlers[op](arg);\n" ++
                "}\n");
        },
        .ind_call_args => {
            try add(&out, gpa,
                "间接调用（函数指针）拿不到被调方的 _名_PARM_n 静态参数区，实参合计必须 ≤4 字节。\n" ++
                "把多参数压进一个指针，或改成直调：\n\n" ++
                "const Args = extern struct { a: u8, b: u8, c: u8, d: u8, e: u8 };\n" ++
                "fn f(p: *const Args) u8 { return p.a; }   // 指针只占 2 字节\n" ++
                "const table = [_]fn (*const Args) u8{ f };\n" ++
                "fn call(i: u8, p: *const Args) u8 { return table[i](p); }\n");
        },
        .param_over4 => {
            try add(&out, gpa,
                "单个参数超过 4 字节（结构体直接传值）尚未支持。改成指针传参：\n\n" ++
                "const Args = extern struct { x: u32, y: u8 };\n" ++
                "fn f(p: *const Args) u8 { return @truncate(p.x); }\n" ++
                "fn caller() u8 {\n" ++
                "    const a: Args = .{ .x = 1, .y = 2 };\n" ++
                "    return f(&a);\n" ++
                "}\n");
        },
    }
    return out.toOwnedSlice(gpa);
}
