//! MCS-251 (Intel 80251 / STC32 family) target description.
//! Stub: feature set and CPU models to be filled in from STC manuals.

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
    const len = @typeInfo(Feature).@"enum".fields.len;
    std.debug.assert(len <= CpuFeature.Set.needed_bit_count);
    var result: [len]CpuFeature = undefined;
    result[@intFromEnum(Feature.flat24)] = .{
        .llvm_name = null,
        .description = "24-bit flat generic pointers",
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
    result[@intFromEnum(Feature.edata)] = .{
        .llvm_name = null,
        .description = "Page-zero edata / direct storage",
        .dependencies = featureSet(&[_]Feature{}),
    };
    result[@intFromEnum(Feature.xdata)] = .{
        .llvm_name = null,
        .description = "Flat XSEG data address space",
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
