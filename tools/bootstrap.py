"""Fetch only pinned public dependencies. No game file is read or uploaded."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "zakuro": ("https://github.com/fearkov/zakuro.git", "f38a00889f2c32cce78516b3d67fba8f08f6e5a8"),
    "3dsrecomp": ("https://github.com/fearkov/3dsrecomp.git", "c3f21f94ba50d688025febc8974ff348d471b587"),
}

def setup():
    for name, (url, commit) in PINS.items():
        folder = ROOT / "source" / name
        if not folder.exists():
            subprocess.run(["git", "clone", "--no-checkout", url, str(folder)], check=True)
            subprocess.run(["git", "-C", str(folder), "checkout", "--detach", commit], check=True)
        actual = subprocess.check_output(["git", "-C", str(folder), "rev-parse", "HEAD"], text=True).strip()
        if actual != commit:
            raise RuntimeError(f"{name}: expected pinned commit {commit}; use a separate clean checkout")
    patch = ROOT / "source/ios-host/runtime.patch"
    command = ["git", "-C", str(ROOT / "source/zakuro"), "apply"]
    if subprocess.run(command + ["--reverse", "--check", str(patch)], capture_output=True).returncode:
        subprocess.run(command + ["--check", str(patch)], check=True)
        subprocess.run(command + [str(patch)], check=True)
    print("Pinned dependencies ready; game inputs remain local.")

if __name__ == "__main__":
    setup()
