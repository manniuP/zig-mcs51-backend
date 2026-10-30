//! mcs2 的 MIR 条目流窥孔（从旧后端 `compiler-017/src/codegen/mcs/peephole.zig`
//! 移植，适配本切片的条目模型；语义与保守条款保持一致）。
//!
//! 与旧版的差异：
//!   - 条目是 `emit.Item`（标签 / 指令文本+可选跳转目标 / 原样文本），
//!     跳转目标直接存在条目里，不再解析 `encode.Address`；
//!   - 「无条件跳转」= 文本以 `sjmp` 开头（本切片唯一的无条件转移；
//!     尚无 ret/reti，isTransfer 目前只认 sjmp）；
//!   - 默认开启（新树无兼容包袱），`MCS2_NO_PEEPHOLE=1` 可关闭用于对拍。
//!
//! 规则（与旧版相同，docs/进展-2026-10-29-MIR窥孔框架落地.md）：
//!   R1 跳转穿线：跳转目标 L 处紧跟无条件跳转到 L2 → 改写目标为 L2；
//!   R2 死块删除：标签引用为 0 + 块内仅一条无条件跳转（或空）
//!              + 前驱是无条件转移（直达性生死线）→ 删除。
//! 保守条款：raw 屏障、同名标签重复定义、块内有真实指令——全部放弃。

const std = @import("std");
const emit_mod = @import("mcs51.zig");

const Item = emit_mod.Item;

const max_rounds = 8;

/// 开关（模块级，工具进程直接改）：默认开启；对拍时置 false。
/// 用 `pub var` 而不是环境变量：0.17 无 libc 构建下读当前进程环境的
/// API 尚不稳定，selftest 的 main 用命令行参数置位。
pub var enabled: bool = true;
/// 命中统计打印。
pub var diag: bool = false;

const Stats = struct {
    thread: usize = 0,
    dead_label: usize = 0,
    dead_jump: usize = 0,
    rounds: usize = 0,
};

fn isUncondSjmp(item: Item) bool {
    return switch (item) {
        // 只认文本前缀：`jnz` 是条件跳，绝不能因为带 jump 字段就算无条件。
        .line => |l| std.mem.startsWith(
            u8,
            std.mem.trimStart(u8, l.text, " \t"),
            "sjmp",
        ),
        else => false,
    };
}

fn isTransfer(item: Item) bool {
    // 本切片唯一的控制流终结指令是 sjmp（含 `sjmp .`）。
    return isUncondSjmp(item);
}

fn threadJumps(items: []Item, stats: *Stats) bool {
    var changed = false;
    for (items) |*item| switch (item.*) {
        .line => |*l| {
            const target = l.jump orelse continue;
            // 找标签定义（唯一才动）
            var def_pos: ?usize = null;
            for (items, 0..) |*it2, i| switch (it2.*) {
                .label => |n| if (n == target) {
                    if (def_pos != null) {
                        def_pos = null;
                        break;
                    }
                    def_pos = i;
                },
                else => {},
            };
            const pos = def_pos orelse continue;
            // 标签后跳过连锁标签；遇 raw 或结尾 → 放弃
            var j = pos + 1;
            while (j < items.len) : (j += 1) switch (items[j]) {
                .label => {},
                else => break,
            };
            if (j >= items.len) continue;
            if (!isUncondSjmp(items[j])) continue; // 非无条件跳（含 raw）→ 放弃
            const next_target = items[j].line.jump.?;
            if (next_target == target) continue; // 自环
            // 只改 jump 字段；文本由发射层按 jump 重新生成，不会漂移。
            l.jump = next_target;
            changed = true;
            stats.thread += 1;
        },
        else => {},
    };
    return changed;
}

fn removeDeadBlocks(gpa: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item), stats: *Stats) bool {
    const slice = items.items;

    // 1) 标签引用计数（jump 字段）
    var refs = std.AutoHashMapUnmanaged(u32, usize).empty;
    defer refs.deinit(gpa);
    for (slice) |item| switch (item) {
        .line => |l| if (l.jump) |t| {
            const gop = refs.getOrPut(gpa, t) catch return false;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        },
        else => {},
    };

    // 2) 找可删块
    var to_remove = std.AutoHashMapUnmanaged(usize, void).empty;
    defer to_remove.deinit(gpa);
    var i: usize = 0;
    while (i < slice.len) : (i += 1) {
        const label = switch (slice[i]) {
            .label => |n| n,
            else => continue,
        };
        if ((refs.get(label) orelse 0) != 0) continue;
        var j = i + 1;
        while (j < slice.len) : (j += 1) switch (slice[j]) {
            .line => {},
            else => break,
        };
        const block = slice[i + 1 .. j];
        var delete_jump = false;
        if (block.len == 0) {
            // 空块：只删标签
        } else if (block.len == 1 and j < slice.len) {
            if (isUncondSjmp(block[0])) {
                delete_jump = true;
            } else continue;
        } else {
            continue;
        }
        // 直达性：紧前驱（跳过标签、待删项，遇 raw 放弃）必须是无条件转移
        var p = i;
        var pred_ok = false;
        while (p > 0) {
            p -= 1;
            if (to_remove.contains(p)) continue;
            switch (slice[p]) {
                .label => continue,
                .raw => break,
                .line => {
                    pred_ok = isTransfer(slice[p]);
                    break;
                },
            }
        }
        if (!pred_ok) continue;
        to_remove.put(gpa, i, {}) catch return false;
        stats.dead_label += 1;
        if (delete_jump) {
            to_remove.put(gpa, i + 1, {}) catch return false;
            stats.dead_jump += 1;
        }
    }
    if (to_remove.count() == 0) return false;

    // 3) 原地压实
    var kept: usize = 0;
    for (slice, 0..) |item, idx| {
        if (to_remove.contains(idx)) continue;
        items.items[kept] = item;
        kept += 1;
    }
    items.shrinkRetainingCapacity(kept);
    return true;
}

/// 入口。`items` 原地改写；`diag` 为真时打印命中统计。
pub fn run(gpa: std.mem.Allocator, items: *std.ArrayListUnmanaged(Item), print_diag: bool) void {
    var stats: Stats = .{};
    var round: usize = 0;
    while (round < max_rounds) : (round += 1) {
        const t = threadJumps(items.items, &stats);
        const d = removeDeadBlocks(gpa, items, &stats);
        if (!(t or d)) break;
    }
    stats.rounds = round + 1;
    if (print_diag) {
        std.debug.print("; mcs2-peephole: thread={d} dead_label={d} dead_jump={d} rounds={d}\n", .{
            stats.thread, stats.dead_label, stats.dead_jump, stats.rounds,
        });
    }
}

test "R1 threads a jump through an unconditional jump" {
    var items = std.ArrayListUnmanaged(Item).empty;
    defer items.deinit(std.testing.allocator);
    // 跳到 L1，L1: sjmp L2 —— R1 应把目标改写为 L2
    try items.append(std.testing.allocator, .{ .line = .{ .text = "jnz L1", .jump = 1 } });
    try items.append(std.testing.allocator, .{ .label = 1 });
    try items.append(std.testing.allocator, .{ .line = .{ .text = "sjmp L2", .jump = 2 } });
    try items.append(std.testing.allocator, .{ .label = 2 });
    run(std.testing.allocator, &items, false);
    try std.testing.expectEqual(@as(u32, 2), items.items[0].line.jump.?);
    // R2 应删掉 L1 + sjmp（L1 引用归零，前驱 jnz 不是转移 → 只能删空块？）
    // 注意：这里前驱是 jnz（条件跳，非转移），L1 块不可直达判定失败，
    // 所以 L1+sjmp 保留 —— 这是保守条款的正确行为。
    try std.testing.expectEqual(@as(usize, 4), items.items.len);
}

test "R2 removes an unreachable jump block after sjmp" {
    var items = std.ArrayListUnmanaged(Item).empty;
    defer items.deinit(std.testing.allocator);
    try items.append(std.testing.allocator, .{ .line = .{ .text = "sjmp L9", .jump = 9 } });
    try items.append(std.testing.allocator, .{ .label = 3 });
    try items.append(std.testing.allocator, .{ .line = .{ .text = "sjmp L4", .jump = 4 } });
    try items.append(std.testing.allocator, .{ .label = 4 });
    try items.append(std.testing.allocator, .{ .line = .{ .text = "nop", .jump = null } });
    run(std.testing.allocator, &items, false);
    // L3 引用为 0、前驱是 sjmp（转移）→ L3+sjmp L4 删除；L4 空标签同轮保留
    // （其前驱 sjmp L4 本轮被删，保守留给下一轮；本例 L4 之后是数据指令，
    //  直达性不成立，L4 长期保留是正确行为）
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
    try std.testing.expectEqual(@as(u32, 9), items.items[0].line.jump.?);
    try std.testing.expectEqual(@as(u32, 4), items.items[1].label);
}

test "R2 keeps a fall-through-reachable empty label" {
    var items = std.ArrayListUnmanaged(Item).empty;
    defer items.deinit(std.testing.allocator);
    try items.append(std.testing.allocator, .{ .line = .{ .text = "mov a,#1", .jump = null } });
    try items.append(std.testing.allocator, .{ .label = 5 });
    try items.append(std.testing.allocator, .{ .line = .{ .text = "sjmp L6", .jump = 6 } });
    run(std.testing.allocator, &items, false);
    // 前驱是数据指令（非转移）→ 顺序可达，绝不删除
    try std.testing.expectEqual(@as(usize, 3), items.items.len);
}
