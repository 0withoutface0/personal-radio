"""Duplex overlapped I/O for mpv's Windows named pipe (no synchronous read/write deadlock)."""

import ctypes
from ctypes import wintypes


class Overlapped(ctypes.Structure):
    _fields_ = [
        ("Internal", ctypes.c_size_t),
        ("InternalHigh", ctypes.c_size_t),
        ("Offset", wintypes.DWORD),
        ("OffsetHigh", wintypes.DWORD),
        ("hEvent", wintypes.HANDLE),
    ]


class WindowsPipe:
    def __init__(self, path):
        api = self.api = ctypes.WinDLL("kernel32", use_last_error=True)
        api.CreateFileW.argtypes = [
            wintypes.LPCWSTR,
            wintypes.DWORD,
            wintypes.DWORD,
            ctypes.c_void_p,
            wintypes.DWORD,
            wintypes.DWORD,
            wintypes.HANDLE,
        ]
        api.CreateFileW.restype = wintypes.HANDLE
        api.CreateEventW.argtypes = [
            ctypes.c_void_p,
            wintypes.BOOL,
            wintypes.BOOL,
            wintypes.LPCWSTR,
        ]
        api.CreateEventW.restype = wintypes.HANDLE
        for name in ("ReadFile", "WriteFile"):
            getattr(api, name).argtypes = [
                wintypes.HANDLE,
                ctypes.c_void_p,
                wintypes.DWORD,
                ctypes.POINTER(wintypes.DWORD),
                ctypes.POINTER(Overlapped),
            ]
            getattr(api, name).restype = wintypes.BOOL
        api.GetOverlappedResult.argtypes = [
            wintypes.HANDLE,
            ctypes.POINTER(Overlapped),
            ctypes.POINTER(wintypes.DWORD),
            wintypes.BOOL,
        ]
        api.GetOverlappedResult.restype = wintypes.BOOL
        api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        api.WaitForSingleObject.restype = wintypes.DWORD
        api.CancelIoEx.argtypes = [wintypes.HANDLE, ctypes.POINTER(Overlapped)]
        api.CloseHandle.argtypes = [wintypes.HANDLE]
        # GENERIC_READ | GENERIC_WRITE, OPEN_EXISTING, FILE_FLAG_OVERLAPPED.
        self.handle = api.CreateFileW(path, 0xC0000000, 0, None, 3, 0x40000000, None)
        if self.handle == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        self.closed = False

    def transfer(self, write, payload=None):
        buffer = (
            ctypes.create_string_buffer(payload) if write else ctypes.create_string_buffer(65536)
        )
        size = len(payload) if write else 65536
        event = self.api.CreateEventW(None, True, False, None)
        if not event:
            raise ctypes.WinError(ctypes.get_last_error())
        overlapped = Overlapped(hEvent=event)
        transferred = wintypes.DWORD()
        try:
            function = self.api.WriteFile if write else self.api.ReadFile
            result = function(
                self.handle, buffer, size, ctypes.byref(transferred), ctypes.byref(overlapped)
            )
            if not result:
                code = ctypes.get_last_error()
                if code != 997:  # ERROR_IO_PENDING
                    raise ctypes.WinError(code)
                # Each direction has its own event and OVERLAPPED structure.
                wait = self.api.WaitForSingleObject(event, 5000 if write else 0xFFFFFFFF)
                if wait != 0:
                    self.api.CancelIoEx(self.handle, ctypes.byref(overlapped))
                    self.api.GetOverlappedResult(
                        self.handle, ctypes.byref(overlapped), ctypes.byref(transferred), True
                    )
                    raise OSError("Named pipe operation timed out")
            if not self.api.GetOverlappedResult(
                self.handle, ctypes.byref(overlapped), ctypes.byref(transferred), True
            ):
                raise ctypes.WinError(ctypes.get_last_error())
            return transferred.value if write else buffer.raw[: transferred.value]
        finally:
            self.api.CloseHandle(event)

    def write(self, payload):
        while payload:
            sent = self.transfer(True, payload)
            if not sent:
                raise OSError("Named pipe closed during write")
            payload = payload[sent:]

    def __iter__(self):
        buffered = b""
        while not self.closed:
            data = self.transfer(False)
            if not data:
                return
            buffered += data
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                yield line

    def close(self):
        if not self.closed:
            self.closed = True
            self.api.CancelIoEx(self.handle, None)
            self.api.CloseHandle(self.handle)
