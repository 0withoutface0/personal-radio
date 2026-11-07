"""Encrypted account records, with encryption supplied by the host OS."""

import ctypes
import json
import os
from ctypes import wintypes
from pathlib import Path


class Vault:
    def __init__(self, root: Path, seal, open_record):
        self.root = root
        self.seal = seal
        self.open_record = open_record

    def read(self, name):
        path = self.root / f"{name}.sealed"
        if not path.exists():
            return None
        return json.loads(str(self.open_record(path.read_text(encoding="ascii"))))

    def write(self, name, value):
        path = self.root / f"{name}.sealed"
        encrypted = str(self.seal(json.dumps(value, ensure_ascii=True)))
        temporary = path.with_suffix(".tmp")
        try:
            with temporary.open("w", encoding="ascii") as file:
                file.write(encrypted)
                file.flush()
                os.fsync(file.fileno())
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)

    def delete(self, name):
        (self.root / f"{name}.sealed").unlink(missing_ok=True)


def windows_vault(root):
    import base64

    class Blob(ctypes.Structure):
        _fields_ = [("size", wintypes.DWORD), ("data", ctypes.c_void_p)]

    protect = ctypes.windll.crypt32.CryptProtectData
    unprotect = ctypes.windll.crypt32.CryptUnprotectData
    release = ctypes.windll.kernel32.LocalFree
    release.argtypes = [ctypes.c_void_p]
    release.restype = ctypes.c_void_p

    def transform(function, data):
        buffer = ctypes.create_string_buffer(data)
        source = Blob(len(data), ctypes.addressof(buffer))
        target = Blob()
        if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(target)):
            raise OSError("Windows could not access the account vault")
        try:
            return ctypes.string_at(target.data, target.size)
        finally:
            release(target.data)

    return Vault(
        root,
        lambda value: base64.b64encode(transform(protect, value.encode())).decode("ascii"),
        lambda value: transform(unprotect, base64.b64decode(value, validate=True)).decode(),
    )
