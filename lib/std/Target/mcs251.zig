//! MCS-251（Intel 80251 / STC32 系列）目标描述。
//! 当前为占位：特性集与 CPU 型号待按 STC 手册补全。

const std = @import("../std.zig");
const CpuFeature = std.Target.Cpu.Feature;
const CpuModel = std.Target.Cpu.Model;

pub const Feature = enum {
    flat24,
    stack_auto,
    hw_mul,
    hw_div,
    edata,
    xdata,
};

pub const featureSet = CpuFeature.FeatureSetFns(Feature).featureSet;
pub const featureSetHas = CpuFeature.FeatureSetFns(Feature).featureSetHas;
pub const featureSetHasAny = CpuFeature.FeatureSetFns(Feature).featureSetHasAny;
pub const featureSetHasAll = CpuFeature.FeatureSetFns(Feature).featureSetHasAll;

pub const all_features = blk: {
    const len = @typeInfo(Feature).@"enum".field_names.len;
    std.debug.assert(len <= CpuFeature.Set.needed_bit_count);
    var result: [len]CpuFeature = undefined;
    result[@intFromEnum(Feature.flat24)] = .{
        .llvm_name = null,
        .description = "24 位平坦通用指针",
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
    result[@intFromEnum(Feature.edata)] = .{
        .llvm_name = null,
        .description = "页零 edata / 直接存储",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.xdata)] = .{
        .llvm_name = null,
        .description = "平坦 XSEG 数据地址空间",
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
            .flat24,
            .stack_auto,
            .edata,
            .xdata,
        }),
    };

    pub const stc32g12k128: CpuModel = .{
        .name = "stc32g12k128",
        .llvm_name = null,
        .features = featureSet(&[_]Feature{
            .flat24,
            .stack_auto,
            .hw_mul,
            .hw_div,
            .edata,
            .xdata,
        }),
    };

    pub const ai8051u: CpuModel = .{
        .name = "ai8051u",
        .llvm_name = null,
        .features = featureSet(&[_]Feature{
            .flat24,
            .stack_auto,
            .hw_mul,
            .hw_div,
            .edata,
            .xdata,
        }),
    };
};
