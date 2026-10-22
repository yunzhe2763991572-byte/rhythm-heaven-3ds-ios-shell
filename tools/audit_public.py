"""Audit exactly the Git-tracked public source set, not ignored local inputs."""
from pathlib import Path
import re
import subprocess

ROOT=Path(__file__).resolve().parents[1]
ROOT_FILES={"README.md","LICENSE","THIRD_PARTY_NOTICES.md",".gitignore",".gitattributes","rust-toolchain.toml","requirements.txt"}
EXTENSIONS={".py",".m",".h",".rs",".toml",".lock",".patch",".md",".txt",".yml",".tbd"}
PREFIXES=("tools/","docs/","LICENSES/",".github/workflows/","source/ios-host/","source/mobile-bridge/","source/aot-generator/")

def audit():
    raw=subprocess.check_output(["git","-C",str(ROOT),"ls-files","-z"])
    files=[x.decode("utf-8") for x in raw.split(b"\0") if x]
    if not files:
        raise ValueError("No tracked files to audit")
    for name in files:
        p=ROOT/name
        if p.is_symlink() or not p.is_file():
            raise ValueError("Unexpected link or missing tracked file: "+name)
        if name not in ROOT_FILES and not (name.startswith(PREFIXES) and p.suffix in EXTENSIONS):
            raise ValueError("Not in public source allowlist: "+name)
        data=p.read_bytes()
        if len(data)>1000000 or b"\0" in data or data.startswith((b"PK\x03\x04",b"MZ",b"\xcf\xfa\xed\xfe")):
            raise ValueError("Binary/large payload rejected: "+name)
        text=data.decode("utf-8")
        if re.search(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]{0,24}PRIVATE KEY-----",text):
            raise ValueError("Possible credential in: "+name)
        if re.search(r"[A-Za-z]:[/\\]Users[/\\][^\s]+",text):
            raise ValueError("Personal home path rejected: "+name)
    print(f"Public audit passed: {len(files)} text source/document files; no game inputs or binaries tracked.")

if __name__=="__main__":
    audit()
