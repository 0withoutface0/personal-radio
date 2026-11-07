"""Build the wheels missing from the embedded Android dependency indexes."""
import argparse
import csv
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZIP_DEFLATED, ZipFile

SDISTS = {
    "pydantic_core": ("2.50.2", "1b0e8dc3932cf4e9ed5727570325cacc716b9409ffc794a221c0ccc72e8eb775"),
    "pyaes": ("1.6.1", "02c1b1405c38d3c370b085fb952dd8bea3fadcee6411ad99f312cc129c536d8f"),
    "ratelimit": ("2.2.1", "af8a9b64b821529aca09ebaf6d8d279100d766f19e90b5059ac6a718ca6dee42"),
}
ABIS = {
    "arm64-v8a": (
        "aarch64-linux-android", "fae8cfd4d3910b6f978b22279fe820c0c6ba49d0ea20f7b106aa6130f1c8f355"
    ),
    "x86_64": (
        "x86_64-linux-android", "77a6a3325aff0a171c36c11c8c3b2204a53783a3d42c29cff10a5ddecee5bfb6"
    ),
}
CHAQUOPY_TARGET = "3.13.16-0"


def download(url, digest, destination):
    if not destination.exists():
        with urlopen(url, timeout=120) as response:
            payload = response.read()
        if hashlib.sha256(payload).hexdigest() != digest:
            raise ValueError(f"Checksum mismatch for {destination.name}")
        destination.write_bytes(payload)
    if hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
        raise ValueError(f"Checksum mismatch for cached {destination.name}")
    return destination


def normalize_wheel(path):
    # Maturin on Windows can emit backslashes in RECORD. Chaquopy expects
    # the wheel specification's forward slash paths when pruning metadata.
    temporary = path.with_suffix(".tmp")
    with ZipFile(path) as source, ZipFile(temporary, "w", ZIP_DEFLATED) as target:
        for entry in source.infolist():
            name = entry.filename.replace(chr(92), "/")
            data = source.read(entry)
            if name.endswith("/RECORD"):
                output = io.StringIO(newline="")
                writer = csv.writer(output, lineterminator="\n")
                for file, checksum, size in csv.reader(io.StringIO(data.decode())):
                    writer.writerow((file.replace(chr(92), "/"), checksum, size))
                data = output.getvalue().encode()
            target.writestr(name, data)
    temporary.replace(path)


def build_wheels(output, toolchain):
    output.mkdir(parents=True, exist_ok=True)
    work = output.parent / "android-wheel-work"
    work.mkdir(exist_ok=True)
    for project, (version, digest) in SDISTS.items():
        with urlopen(f"https://pypi.org/pypi/{project}/{version}/json", timeout=30) as response:
            release = json.load(response)
        source = next(item for item in release["urls"] if item["packagetype"] == "sdist")
        archive = download(source["url"], digest, work / source["filename"])
        if project == "pydantic_core":
            with tarfile.open(archive) as package:
                package.extractall(work, filter="data")
            pydantic = work / f"{project}-{version}"
        else:
            subprocess.run(["uv", "build", "--wheel", "--out-dir", output, archive], check=True)

    clang = toolchain / ("clang.exe" if os.name == "nt" else "clang")
    if not clang.is_file():
        raise FileNotFoundError(clang)
    for abi, (target, digest) in ABIS.items():
        lib = work / abi
        lib.mkdir(exist_ok=True)
        name = f"target-{CHAQUOPY_TARGET}-{abi}.zip"
        archive = download(
            f"https://repo.maven.apache.org/maven2/com/chaquo/python/target/{CHAQUOPY_TARGET}/{name}",
            digest, work / name,
        )
        with ZipFile(archive) as package:
            library = next(name for name in package.namelist() if name.endswith("/libpython3.13.so"))
            (lib / "libpython3.13.so").write_bytes(package.read(library))
        config = lib / "pyo3-config.txt"
        config.write_text(
            "implementation=CPython\nversion=3.13\nshared=true\nabi3=false\n"
            f"lib_name=python3.13\nlib_dir={lib}\npointer_width=64\n", encoding="utf-8",
        )
        env = os.environ | {
            "PYO3_CONFIG_FILE": str(config),
            "PYO3_CROSS": "1",
            "PYO3_CROSS_PYTHON_VERSION": "3.13",
            "ANDROID_API_LEVEL": "24",
            f"CARGO_TARGET_{target.replace('-', '_').upper()}_LINKER": str(clang),
            "RUSTFLAGS": f"-C link-arg=--target={target}24 -C link-arg=-Wl,-z,max-page-size=16384",
        }
        subprocess.run(
            [sys.executable, "-m", "maturin", "build", "--release", "--locked", "--target", target,
             "--out", output, "--auditwheel", "skip", "-i", sys.executable],
            check=True, cwd=pydantic, env=env,
        )
        abi_tag = abi.replace("-", "_")
        wheel = next(output.glob(f"pydantic_core-*-cp313-cp313-android_24_{abi_tag}.whl"))
        normalize_wheel(wheel)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("ndk_bin", type=Path, help="NDK toolchains/llvm/prebuilt/<host>/bin")
    args = parser.parse_args()
    if not shutil.which("uv"):
        parser.error("uv must be installed to build the two pure Python wheels")
    build_wheels(args.output.resolve(), args.ndk_bin.resolve())
