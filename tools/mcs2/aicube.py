"""从 AiCube-ISP 窗口读出它当前装载的 .ihx 路径与串口号。

为什么需要它：AiCube 的自动下载监视的是**界面底部路径框里那个文件**，
不是固定文件名。以前跑 `realcheck.py --auto COM14` 会因为默认写的
`real_live_ai8051u_115200.ihx` 没人监视而静默不烧（串口收不到数据，
看起来像固件有问题）。这里用 WM_GETTEXT 只读地把路径问出来。

只读，不发送任何改变界面状态的命令（不点按钮、不改勾选项）。
之前盲点坐标曾把人家的「下次使用 HID 接口下载」勾错，不重复那种事。

命令行：
    python aicube.py            # 打印装载路径与串口
"""
import ctypes
from ctypes import wintypes

WM_GETTEXT = 0x000D
WM_GETTEXTLENGTH = 0x000E

_u32 = ctypes.WinDLL("user32", use_last_error=True)
_u32.SendMessageW.restype = ctypes.c_long
_u32.SendMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
_u32.GetClassNameW.restype = ctypes.c_int
_u32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_u32.GetWindowTextW.restype = ctypes.c_int
_u32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_u32.EnumWindows.restype = wintypes.BOOL
_u32.EnumChildWindows.restype = wintypes.BOOL

_ENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)


def _text(hwnd: int) -> str:
    n = _u32.SendMessageW(hwnd, WM_GETTEXTLENGTH, 0, 0)
    if n <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(n + 1)
    _u32.SendMessageW(hwnd, WM_GETTEXT, n + 1, ctypes.addressof(buf))
    return buf.value


def _cls(hwnd: int) -> str:
    buf = ctypes.create_unicode_buffer(256)
    _u32.GetClassNameW(hwnd, buf, 256)
    return buf.value


def probe() -> dict[str, str]:
    """返回 {"ihx": 路径, "port": 串口} 里能读到的项；AiCube 没开则空字典。"""
    found: dict[str, str] = {}
    tops: list[tuple[int, str]] = []

    def on_top(h, _lp):
        buf = ctypes.create_unicode_buffer(512)
        _u32.GetWindowTextW(h, buf, 512)
        if "AiCube" in buf.value or "STC" in buf.value:
            tops.append((h, buf.value))
        return True

    _u32.EnumWindows(_ENUMPROC(on_top), 0)

    for h, _title in tops:
        def on_child(c, _lp):
            cls = _cls(c)
            t = _text(c).strip()
            if not t:
                return True
            if cls == "Edit" and (".ihx" in t.lower() or ".hex" in t.lower()):
                found.setdefault("ihx", t)
            elif cls == "ComboBox" and t.upper().startswith("COM"):
                found.setdefault("port", t)
            return True

        _u32.EnumChildWindows(h, _ENUMPROC(on_child), 0)
    return found


def loaded_ihx() -> str | None:
    return probe().get("ihx")


if __name__ == "__main__":
    p = probe()
    if not p:
        print("没找到 AiCube 窗口（或它没在运行）")
    for k, v in p.items():
        print(f"{k}: {v}")
