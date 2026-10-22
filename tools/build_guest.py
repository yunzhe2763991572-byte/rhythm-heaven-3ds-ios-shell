"""Compile generated game C locally. No network or game data upload."""
from pathlib import Path
import argparse
import concurrent.futures
import hashlib
import json
import os
import plistlib
import subprocess
from common import macho, sha

ROOT = Path(__file__).resolve().parents[1]
EXPORTS = ["recomp_abi", "recomp_generation", "recomp_entry_count", "recomp_entries", "recomp_module_count", "recomp_modules", "recomp_origins"]

def build(source, output, llvm_bin, jobs=4):
    source, output, llvm_bin = Path(source).resolve(), Path(output).resolve(), Path(llvm_bin).resolve()
    compiler = llvm_bin / ("clang.exe" if os.name == "nt" else "clang")
    linker = llvm_bin / ("ld.lld.exe" if os.name == "nt" else "ld.lld")
    if not compiler.is_file() or not linker.is_file():
        raise ValueError("LLVM must include clang and the Darwin-capable LLD linker")
    units = sorted(source.glob("*.c"), key=lambda p: -p.stat().st_size)
    if not units or not (source / "recomp.h").is_file():
        raise ValueError("No generated C units/recomp.h found")
    output.mkdir(parents=True, exist_ok=True)
    flags = ["--target=arm64-apple-ios16.0", "-ffreestanding", "-isystem", str(ROOT / "tools/ios-c-headers"), "-I", str(source), "-O1", "-ffp-contract=off", "-fno-math-errno", "-w"]
    header = (source / "recomp.h").read_bytes()
    def unit(p):
        obj = output / p.with_suffix(".o").name
        stamp = obj.with_suffix(".sha256")
        key = hashlib.sha256(p.read_bytes() + header + json.dumps(flags).encode()).hexdigest()
        if not (obj.is_file() and stamp.is_file() and stamp.read_text() == key):
            result = subprocess.run([str(compiler), *flags, "-c", str(p), "-o", str(obj)], capture_output=True)
            if result.returncode:
                raise RuntimeError(p.name + ": " + result.stderr.decode(errors="replace")[-2000:])
            stamp.write_text(key)
        return obj
    with concurrent.futures.ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = [pool.submit(unit, p) for p in units]
        for done, f in enumerate(concurrent.futures.as_completed(futures), 1):
            f.result()
            if done % 12 == 0 or done == len(units):
                print(f"Compiled {done}/{len(units)} local iOS units", flush=True)
    framework = output / "Guest.framework"
    if framework.exists():
        raise ValueError("Framework already exists; use a new output directory")
    framework.mkdir()
    args = ["-dylib", "-arch", "arm64", "-platform_version", "ios", "16.0", "16.0", "-install_name", "@rpath/Guest.framework/Guest", "-dead_strip", "-adhoc_codesign", "-o", str(framework / "Guest")]
    for symbol in EXPORTS:
        args += ["-exported_symbol", "_" + symbol]
    args += [str(output / p.with_suffix(".o").name) for p in units] + [str(ROOT / "tools/ios-libSystem.tbd")]
    response = output / "link.rsp"
    response.write_text("\n".join('"' + a.replace("\\", "/") + '"' for a in args), encoding="utf-8")
    subprocess.run([str(linker), "-flavor", "darwin", "@" + str(response)], check=True)
    macho(framework / "Guest", 6)
    info = dict(CFBundleExecutable="Guest", CFBundleIdentifier="org.rhythmheaven.3ds.guest", CFBundleName="Guest", CFBundlePackageType="FMWK", CFBundleShortVersionString="1.0", CFBundleVersion="1", MinimumOSVersion="16.0", CFBundleSupportedPlatforms=["iPhoneOS"])
    (framework / "Info.plist").write_bytes(plistlib.dumps(info))
    (output / "guest-build.json").write_text(json.dumps(dict(units=len(units),sha256=sha(framework/"Guest"),game_uploaded=False),indent=2)+"\n")
    return framework

if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--source", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--llvm-bin", required=True, type=Path)
    p.add_argument("--jobs", type=int, default=4)
    a = p.parse_args()
    if not 1 <= a.jobs <= 16:
        p.error("jobs must be between 1 and 16")
    print(build(a.source,a.output,a.llvm_bin,a.jobs))
