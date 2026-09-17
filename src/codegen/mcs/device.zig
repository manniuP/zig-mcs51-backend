//! 设备存储表（由 `tools/mcs_device.py --emit compiler-json` 生成）的后端视图。
//!
//! 通过环境变量 `MCS_DEVICE` 指向该 JSON（路径）；未设置时 `loaded = false`，
//! 放置策略保持旧默认（全局 → xdata），不影响现有构建。
//!
//! 放置策略（`decide`）：显式 `linksection` 优先；否则按设备表自动放置——
//! 大小 ≤2 字节且设备有 data 空间 → data，其余 → 设备默认数据空间（多数字号 xdata）。

const std = @import("std");

pub const Place = enum { data, idata, xdata };

pub const Device = struct {
    loaded: bool = false,
    code_base: u64 = 0,
    code_size: u64 = 0,
    data_size: u64 = 0,
    idata_size: u64 = 0,
    edata_size: u64 = 0,
    xdata_size: u64 = 0,
    default_data: Place = .xdata,
};

var cached = Device{};
var loaded_once = false;

pub fn get(environ_map: *const std.process.Environ.Map) *const Device {
    if (!loaded_once) {
        loaded_once = true;
        cached = load(environ_map);
    }
    return &cached;
}

fn placeFromName(s: []const u8) Place {
    if (std.mem.eql(u8, s, "data")) return .data;
    if (std.mem.eql(u8, s, "idata")) return .idata;
    return .xdata;
}

fn intField(v: std.json.Value) u64 {
    return switch (v) {
        .integer => |i| if (i >= 0) @intCast(i) else 0,
        else => 0,
    };
}

fn spaceSize(o: anytype, key: []const u8) u64 {
    const v = o.get(key) orelse return 0;
    return switch (v) {
        .object => |inner| if (inner.get("size")) |s| intField(s) else 0,
        else => 0,
    };
}

fn load(environ_map: *const std.process.Environ.Map) Device {
    var dev = Device{};
    // `MCS_DEVICE` 直接内联 JSON 文本（由 tools/mcs_device.py --emit compiler-json 生成）。
    const text = environ_map.get("MCS_DEVICE") orelse return dev;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, text, .{}) catch return dev;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return dev,
    };
    dev.loaded = true;
    if (root.get("default_data")) |d| switch (d) {
        .string => |s| dev.default_data = placeFromName(s),
        else => {},
    };
    if (root.get("code")) |c| switch (c) {
        .object => |o| {
            if (o.get("base")) |b| dev.code_base = intField(b);
            if (o.get("size")) |s| dev.code_size = intField(s);
        },
        else => {},
    };
    if (root.get("spaces")) |sp| switch (sp) {
        .object => |o| {
            dev.data_size = spaceSize(o, "data");
            dev.idata_size = spaceSize(o, "idata");
            dev.edata_size = spaceSize(o, "edata");
            dev.xdata_size = spaceSize(o, "xdata");
        },
        else => {},
    };
    return dev;
}

/// 决定一个全局数据符号的放置空间。`linksection` 为 `.data`/`.hot`/`.idata` 时优先；
/// 其余（含 `.cold`，其分区在 `Asx` 里另作 COLDX）走自动放置。
pub fn decide(dev: *const Device, sec: ?[]const u8, size: u32) Place {
    if (sec) |s| {
        if (std.mem.eql(u8, s, ".data") or std.mem.eql(u8, s, ".hot")) return .data;
        if (std.mem.eql(u8, s, ".idata")) return .idata;
    }
    if (dev.loaded) {
        if (size <= 2 and dev.data_size > 0) return .data;
        return dev.default_data;
    }
    return .xdata;
}
