"""Fetch a project-local Windows Icarus toolchain from the MSYS2 package site.

Run explicitly; the regression runner never downloads software. Requires Python
and zstandard. Package URLs and verified SHA256 hashes are saved in the cache.
No registry or system PATH changes are made.
"""
import hashlib
import io
import json
from pathlib import Path
import os
import subprocess
import tarfile
import urllib.request

import zstandard

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / ".tools" / "iverilog"
LOCK = ROOT / "scripts" / "iverilog_msys2.lock.json"


def fetch(url):
    if os.name == "nt":
        # Use the Windows certificate store, retaining normal TLS verification.
        return subprocess.check_output(["curl.exe", "--fail", "--location",
                                        "--silent", "--show-error",
                                        "--max-time", "60", url])
    with urllib.request.urlopen(url, timeout=45) as response:
        return response.read()


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    manifest = []
    for entry in json.loads(LOCK.read_text(encoding="utf-8")):
        url, digest = entry["url"], entry["sha256"]
        archive = CACHE / url.rsplit("/", 1)[1]
        data = archive.read_bytes() if archive.exists() else fetch(url)
        if hashlib.sha256(data).hexdigest() != digest:
            raise RuntimeError("SHA256 mismatch: " + url)
        archive.write_bytes(data)
        raw = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(data))
        with tarfile.open(fileobj=raw, mode="r|") as package_tar:
            for member in package_tar:
                if not member.name.startswith("mingw64/"):
                    continue
                target = (CACHE / member.name).resolve()
                if not target.is_relative_to(CACHE.resolve()):
                    raise RuntimeError("Unsafe archive path")
                # Copy regular files only; executable paths are ordinary files.
                if member.isfile():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(package_tar.extractfile(member).read())
        manifest.append(entry)
        print("Verified and extracted " + archive.name, flush=True)
        (CACHE / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Toolchain: " + str(CACHE / "mingw64" / "bin"))


if __name__ == "__main__":
    main()
