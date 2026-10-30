//! MCS-51（Intel 8051 / STC8 系列）目标描述。
//! 当前为占位：特性集与 CPU 型号待按 STC 手册补全。

const std = @import("../std.zig");
const CpuFeature = std.Target.Cpu.Feature;
const CpuModel = std.Target.Cpu.Model;

pub const Feature = enum {
    near_data,
    pdata,
    xdata,
    stack_auto,
    hw_mul,
    hw_div,
};

pub const featureSet = CpuFeature.FeatureSetFns(Feature).featureSet;
pub const featureSetHas = CpuFeature.FeatureSetFns(Feature).featureSetHas;
pub const featureSetHasAny = CpuFeature.FeatureSetFns(Feature).featureSetHasAny;
pub const featureSetHasAll = CpuFeature.FeatureSetFns(Feature).featureSetHasAll;

pub const all_features = blk: {
    const len = @typeInfo(Feature).@"enum".field_names.len;
    std.debug.assert(len <= CpuFeature.Set.needed_bit_count);
    var result: [len]CpuFeature = undefined;
    result[@intFromEnum(Feature.near_data)] = .{
        .llvm_name = null,
        .description = "8 位近数据 / idata 指针",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.pdata)] = .{
        .llvm_name = null,
        .description = "8 位分页外部数据指针",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.xdata)] = .{
        .llvm_name = null,
        .description = "16 位外部数据指针",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.stack_auto)] = .{
        .llvm_name = null,
        .description = "与 SDCC --stack-auto 一致的可重入栈约定",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.hw_mul)] = .{
        .llvm_name = null,
        .description = "硬件乘法单元",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.hw_div)] = .{
        .llvm_name = null,
        .description = "硬件除法单元",
        .dependencies = featureSet(&[_]Feature{}),
    };
    const names = @typeInfo(Feature).@"enum".field_names;
    for (&result, 0..) |*elem, i| {
        elem.index = i;
        elem.name = names[i];
    }
    break :blk result;
};

pub const cpu = struct {
    pub const generic: CpuModel = .{
        .name = "generic",
        .llvm_name = null,
        .features = featureSet(&[_]Feature{
            .near_data,
            .pdata,
            .xdata,
            .stack_auto,
        }),
    };

    pub const stc8h8k64u: CpuModel = .{
        .name = "stc8h8k64u",
        .llvm_name = null,
        .features = featureSet(&[_]Feature{
            .near_data,
            .pdata,
            .xdata,
            .stack_auto,
            .hw_mul,
            .hw_div,
        }),
    };
};
