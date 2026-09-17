//! MCS-51 (Intel 8051 / STC8 family) target description.
//! Stub: feature set and CPU models to be filled in from STC manuals.

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
    const len = @typeInfo(Feature).@"enum".fields.len;
    std.debug.assert(len <= CpuFeature.Set.needed_bit_count);
    var result: [len]CpuFeature = undefined;
    result[@intFromEnum(Feature.near_data)] = .{
        .llvm_name = null,
        .description = "8-bit near data / idata pointers",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.pdata)] = .{
        .llvm_name = null,
        .description = "8-bit paged external data pointers",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.xdata)] = .{
        .llvm_name = null,
        .description = "16-bit external data pointers",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.stack_auto)] = .{
        .llvm_name = null,
        .description = "Reentrant stack convention shared with SDCC --stack-auto",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.hw_mul)] = .{
        .llvm_name = null,
        .description = "Hardware multiply unit",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.hw_div)] = .{
        .llvm_name = null,
        .description = "Hardware divide unit",
        .dependencies = featureSet(&[_]Feature{}),
    };
    const ti = @typeInfo(Feature);
    for (&result, 0..) |*elem, i| {
        elem.index = i;
        elem.name = ti.@"enum".fields[i].name;
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
