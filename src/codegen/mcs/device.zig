//! 设备存储表（由 `tools/mcs_device.py --emit compiler-json` 生成）的后端视图。
//!
//! 通过环境变量 `MCS_DEVICE` 指向该 JSON（路径）；未设置时 `loaded = false`，
//! 放置策略保持旧默认（全局 → xdata），不影响现有构建。
//!
//! 放置策略（`decide`）：显式 `linksection` 优先；否则按设备表自动放置——
//! 大小 ≤2 字节且设备有 data 空间 → data，其余 → 设备默认数据空间（多数字号 xdata）。

const std = @import("std");

pub const Place = enum { data, idata, edata, xdata, exdata };

/// 解析 `linksection` 标签：空格/逗号分隔，点前缀可省。
/// - 放置：`data`/`idata`/`edata`/`xdata`/`exdata`（兼容 `hot`=data、`warm`=idata、`cold`=xdata）
/// - 优化等级：`O0`..`O5`（0=最快/最占空间，5=最慢/最省空间）；未标注为 null（走默认 O3）
/// 优化等级，命名与 GCC 对齐：`O0`–`O3` 为优化力度（偏速度），`Os` 偏体积，`Ofast` 最快。
/// 旧 `O4`/`O5`、`cold` 视为 `Os`。
pub const Level = enum { o0, o1, o2, o3, ofast, os };

pub fn levelName(l: Level) []const u8 {
    return switch (l) {
        .o0 => "O0",
        .o1 => "O1",
        .o2 => "O2",
        .o3 => "O3",
        .ofast => "Ofast",
        .os => "Os",
    };
}

/// 解析 `linksection` 标签：空格/逗号分隔，点前缀可省。
/// - 放置：`data`/`idata`/`edata`/`xdata`/`exdata`（兼容 `hot`=data、`warm`=idata；`cold`=xdata+Os）
/// - 优化等级：`O0`..`O3`/`Ofast`/`Os`（旧 `O4`/`O5`→`Os`）；未标注为 null（默认 `O3`）
pub const Section = struct { place: ?Place = null, level: ?Level = null };

pub fn parseSection(sec: []const u8) Section {
    var out = Section{};
    var it = std.mem.tokenizeAny(u8, sec, " ,;");
    while (it.next()) |tok| {
        const t = std.mem.trimStart(u8, tok, ".");
        if (t.len == 2 and (t[0] == 'O' or t[0] == 'o') and t[1] >= '0' and t[1] <= '3') {
            out.level = switch (t[1]) {
                '0' => .o0,
                '1' => .o1,
                '2' => .o2,
                else => .o3,
            };
        } else if (std.ascii.eqlIgnoreCase(t, "os") or
            std.ascii.eqlIgnoreCase(t, "o4") or std.ascii.eqlIgnoreCase(t, "o5"))
        {
            out.level = .os;
        } else if (std.ascii.eqlIgnoreCase(t, "ofast")) {
            out.level = .ofast;
        } else if (std.mem.eql(u8, t, "data") or std.mem.eql(u8, t, "hot")) {
            out.place = .data;
        } else if (std.mem.eql(u8, t, "idata") or std.mem.eql(u8, t, "warm")) {
            out.place = .idata;
        } else if (std.mem.eql(u8, t, "edata")) {
            out.place = .edata;
        } else if (std.mem.eql(u8, t, "cold")) {
            out.place = .xdata;
            out.level = .os;
        } else if (std.mem.eql(u8, t, "xdata")) {
            out.place = .xdata;
        } else if (std.mem.eql(u8, t, "exdata")) {
            out.place = .exdata;
        }
    }
    return out;
}

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
    if (std.mem.eql(u8, s, "edata")) return .edata;
    if (std.mem.eql(u8, s, "exdata")) return .exdata;
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
pub fn decide(dev: *const Device, arch: std.Target.Cpu.Arch, sec: ?[]const u8, size: u32) Place {
    if (sec) |s| {
        if (parseSection(s).place) |p| return p;
    }
    // 8 位 MCS-51：C 侧 `--model-large` 的 extern 全局落在 xdata；Zig 侧定义（`export var`）
    // 必须同为 xdata，否则 C/Zig 各按不同存储访问、互操作失败。故 8 位不自动放 data。
    if (arch == .mcs51) return .xdata;
    if (dev.loaded) {
        if (size <= 2 and dev.data_size > 0) return .data;
        return dev.default_data;
    }
    return .xdata;
}
