#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
download_tdlib.py - Downloads prebuilt libtdjson.so for Android
================================================================
Source: https://github.com/up9cloud/android-libtdjson
        Provides jniLibs.tar.gz with all ABI .so files.

Run from project root:
    python scripts/download_tdlib.py
"""

import os
import sys
import tarfile
import urllib.request
import shutil

# Force UTF-8 on Windows to avoid cp1252 encode errors
if sys.platform == "win32":
    import io
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")

# ── Config ────────────────────────────────────────────────────────────────────

# up9cloud/android-libtdjson v1.8.52 (latest as of 2025-06)
DOWNLOAD_URL = "https://github.com/up9cloud/android-libtdjson/releases/download/v1.8.52/jniLibs.tar.gz"

JNILIBS_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "android", "app", "src", "main", "jniLibs"
)

ABIS = ["arm64-v8a", "armeabi-v7a", "x86_64"]

# ── Helpers ───────────────────────────────────────────────────────────────────

def all_present():
    for abi in ABIS:
        path = os.path.join(JNILIBS_DIR, abi, "libtdjson.so")
        if not os.path.exists(path) or os.path.getsize(path) < 100_000:
            return False
    return True


def download(url, dest):
    print(f"  Downloading {os.path.basename(dest)}...")
    print(f"  URL: {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=300) as resp, open(dest, "wb") as f:
        total = int(resp.headers.get("Content-Length", 0))
        downloaded = 0
        chunk = 65536
        while True:
            data = resp.read(chunk)
            if not data:
                break
            f.write(data)
            downloaded += len(data)
            if total > 0:
                pct = downloaded * 100 // total
                print(f"\r  Progress: {pct}% ({downloaded // 1024} / {total // 1024} KB)  ", end="", flush=True)
    print()
    size = os.path.getsize(dest)
    print(f"  Downloaded: {size // 1024:,} KB")
    return size > 100_000


def extract_tar(tar_path, dest_root):
    """Extract jniLibs.tar.gz -> dest_root. Handles paths like jniLibs/arm64-v8a/libtdjson.so"""
    print(f"  Extracting {os.path.basename(tar_path)}...")
    count = 0
    with tarfile.open(tar_path, "r:gz") as tar:
        for member in tar.getmembers():
            # Skip directories and non-regular files
            if not member.isfile():
                continue
            name = member.name
            parts = name.replace("\\", "/").split("/")
            # Find the ABI part and extract .so files
            for abi in ABIS:
                if abi in parts:
                    idx = parts.index(abi)
                    rel = os.path.join(*parts[idx:])
                    dest = os.path.join(dest_root, rel)
                    os.makedirs(os.path.dirname(dest), exist_ok=True)
                    f = tar.extractfile(member)
                    if f is None:
                        break
                    with f as src, open(dest, "wb") as dst:
                        shutil.copyfileobj(src, dst)
                    size = os.path.getsize(dest)
                    print(f"  Extracted: {rel}  ({size // 1024:,} KB)")
                    count += 1
                    break
    return count > 0


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    print("\n=== Downloading TDLib native libs (up9cloud/android-libtdjson v1.8.52) ===\n")

    if all_present():
        print("All libtdjson.so files already present - skipping download.\n")
        print("To force re-download, delete android/app/src/main/jniLibs and re-run.")
        return

    os.makedirs(JNILIBS_DIR, exist_ok=True)
    tar_path = os.path.join(JNILIBS_DIR, "jniLibs.tar.gz")

    try:
        ok = download(DOWNLOAD_URL, tar_path)
        if not ok:
            print("\n[ERROR] Download failed or file too small.")
            sys.exit(1)

        ok = extract_tar(tar_path, JNILIBS_DIR)
        if not ok:
            print("\n[ERROR] Extraction failed - no ABI folders found in archive.")
            sys.exit(1)

    finally:
        try:
            os.remove(tar_path)
        except Exception:
            pass

    # Verify
    print("\n--- Verification ---")
    all_ok = True
    for abi in ABIS:
        path = os.path.join(JNILIBS_DIR, abi, "libtdjson.so")
        if os.path.exists(path) and os.path.getsize(path) > 100_000:
            print(f"  [OK] {abi}/libtdjson.so  ({os.path.getsize(path) // 1024:,} KB)")
        else:
            print(f"  [MISSING] {abi}/libtdjson.so")
            all_ok = False

    if all_ok:
        print("\n=== All done! Native libs ready. ===")
        print("\nNext steps:")
        print("  flutter build apk --debug")
    else:
        print("\n[WARNING] Some ABI libs are missing.")
        print("Check the archive contents manually at:")
        print(f"  {DOWNLOAD_URL}")


if __name__ == "__main__":
    main()
