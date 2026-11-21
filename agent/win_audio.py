"""Windows 扬声器静音（CoreAudio / IAudioEndpointVolume）。

**只在独立子进程里跑**（`uu-agent --mute-helper on|off`）：
手写 vtable 调用一旦索引写错就是访问违例，直接段错误。
放在子进程里，最坏情况只是这一个动作失败，agent 主进程和远控链路不受影响。

输出一行 JSON 给父进程：`{"ok":true,"muted":true}`。
"""
from __future__ import annotations

import ctypes
import json
import sys
from ctypes import POINTER, Structure, byref, c_ubyte, c_ulong, c_ushort, c_void_p, WINFUNCTYPE


class GUID(Structure):
    _fields_ = [
        ("Data1", c_ulong),
        ("Data2", c_ushort),
        ("Data3", c_ushort),
        ("Data4", c_ubyte * 8),
    ]


def _guid(d1: int, d2: int, d3: int, rest: tuple[int, ...]) -> GUID:
    return GUID(d1, d2, d3, (c_ubyte * 8)(*rest))


CLSID_MMDeviceEnumerator = _guid(0xBCDE0395, 0xE52F, 0x467C,
                                 (0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E))
IID_IMMDeviceEnumerator = _guid(0xA95664D2, 0x9614, 0x4F35,
                                (0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6))
IID_IAudioEndpointVolume = _guid(0x5CDF2C82, 0x841E, 0x4546,
                                 (0x97, 0x22, 0x0C, 0xF7, 0x40, 0x78, 0x22, 0x9A))

# vtable 索引（IUnknown 占 0-2）
_VT_RELEASE = 2
_VT_GET_DEFAULT_ENDPOINT = 4      # IMMDeviceEnumerator
_VT_ACTIVATE = 3                  # IMMDevice
_VT_SET_MUTE = 14                 # IAudioEndpointVolume
_VT_GET_MUTE = 15                 # IAudioEndpointVolume


def _call(obj: c_void_p, index: int, restype, argtypes: tuple, *args):
    vtbl = ctypes.cast(ctypes.cast(obj, POINTER(POINTER(c_void_p)))[0],
                       POINTER(c_void_p))
    fn = WINFUNCTYPE(restype, c_void_p, *argtypes)(vtbl[index])
    return fn(obj, *args)


def _release(obj: c_void_p) -> None:
    try:
        _call(obj, _VT_RELEASE, ctypes.c_ulong, ())
    except Exception:
        pass


def main(argv: list[str]) -> int:
    want = None
    if argv and argv[0] in ("on", "off"):
        want = argv[0] == "on"
    if sys.platform != "win32":
        print(json.dumps({"ok": False, "err": "非 Windows 平台"}))
        return 1

    ole32 = ctypes.oledll.ole32
    enumerator = c_void_p()
    device = c_void_p()
    volume = c_void_p()
    try:
        ole32.CoInitialize(None)
        ole32.CoCreateInstance(byref(CLSID_MMDeviceEnumerator), None, 1,
                               byref(IID_IMMDeviceEnumerator), byref(enumerator))
        # eRender=0（输出设备）, eConsole=0（默认设备）
        _call(enumerator, _VT_GET_DEFAULT_ENDPOINT, ctypes.c_long,
              (ctypes.c_int, ctypes.c_int, POINTER(c_void_p)),
              0, 0, byref(device))
        _call(device, _VT_ACTIVATE, ctypes.c_long,
              (POINTER(GUID), ctypes.c_ulong, c_void_p, POINTER(c_void_p)),
              byref(IID_IAudioEndpointVolume), 1, None, byref(volume))

        if want is None:
            cur = ctypes.c_int(-1)
            _call(volume, _VT_GET_MUTE, ctypes.c_long, (POINTER(ctypes.c_int),), byref(cur))
            print(json.dumps({"ok": True, "muted": bool(cur.value)}))
            return 0

        _call(volume, _VT_SET_MUTE, ctypes.c_long,
              (ctypes.c_int, c_void_p), 1 if want else 0, None)
        # 回读校验：写完读不回来就说明调用没落到设备上，别谎报成功
        cur = ctypes.c_int(-1)
        _call(volume, _VT_GET_MUTE, ctypes.c_long, (POINTER(ctypes.c_int),), byref(cur))
        got = bool(cur.value)
        ok = (got == want)
        print(json.dumps({"ok": ok, "muted": got,
                          "err": "" if ok else "设置后回读不一致"}))
        return 0 if ok else 3
    except Exception as e:  # noqa: BLE001
        print(json.dumps({"ok": False, "err": f"{type(e).__name__}: {e}"}))
        return 1
    finally:
        for obj in (volume, device, enumerator):
            if obj:
                _release(obj)
        try:
            ole32.CoUninitialize()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
