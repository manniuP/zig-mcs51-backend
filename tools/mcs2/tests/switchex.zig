//! 真 `switch`：语句形态（多 case / 范围 / else）与 enum 判定。

const Cmd = enum(u8) { start = 1, stop = 2, reset = 3, other = 9 };

// 普通 case + else：cmd=2 → 0x22，其它 → 0xEE
export fn sw1(cmd: u8) u8 {
    var r: u8 = 0xEE;
    switch (cmd) {
        1 => r = 0x11,
        2 => r = 0x22,
        3 => r = 0x33,
        else => {},
    }
    return r;
}

// 范围 case：3..=5 命中 → 0x55
export fn sw2(cmd: u8) u8 {
    var r: u8 = 0;
    switch (cmd) {
        1 => r = 0x11,
        3...5 => r = 0x55,
        8 => r = 0x88,
        else => r = 0xFF,
    }
    return r;
}

// enum 判定（enum 参数还不能进 export fn，这里用 u8 转）
export fn sw3(cmd: u8) u8 {
    const e: Cmd = @enumFromInt(cmd);
    var r: u8 = 0;
    switch (e) {
        .start => r = 0x01,
        .stop => r = 0x02,
        .reset => r = 0x03,
        .other => r = 0x09,
    }
    return r;
}