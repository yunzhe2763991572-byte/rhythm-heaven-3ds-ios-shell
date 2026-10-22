"""Reject anything except the content-free host, open runtime and notices."""
from pathlib import Path
import argparse
import json
import plistlib
import zipfile
from common import sha

PREFIX = "Payload/Rhythm3DS.app/"
FILES = {
    "Info.plist", "Rhythm3DS", "_CodeSignature/CodeResources",
    "Frameworks/MoltenVK.framework/MoltenVK", "Frameworks/MoltenVK.framework/Info.plist",
    "Frameworks/MoltenVK.framework/_CodeSignature/CodeResources",
}

def audit(path):
    with zipfile.ZipFile(path) as z:
        if z.testzip() is not None:
            raise ValueError("Corrupted shell archive")
        names = z.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate archive member")
        for name in names:
            if name.endswith("/"):
                continue
            if not name.startswith(PREFIX):
                raise ValueError("Unexpected archive prefix")
            short = name[len(PREFIX):]
            notice = short.startswith("Licenses/") and short.endswith(".txt") and ".." not in short and "\\" not in short
            if short not in FILES and not notice:
                raise ValueError("Not a content-free shell; rejected member: " + short)
        for required in ("Info.plist", "Rhythm3DS", "Frameworks/MoltenVK.framework/MoltenVK"):
            if PREFIX + required not in names:
                raise ValueError("Missing shell runtime member")
        info = plistlib.loads(z.read(PREFIX + "Info.plist"))
        if info["CFBundleIdentifier"] != "org.rhythmheaven.3ds.experimental":
            raise ValueError("Unexpected bundle identifier")
    return dict(content_free=True,game_files_present=False,game_derived_framework_present=False,console_fonts_present=False,sha256=sha(path),bytes=Path(path).stat().st_size)

if __name__ == "__main__":
    p=argparse.ArgumentParser()
    p.add_argument("shell", type=Path)
    p.add_argument("--report",type=Path)
    args=p.parse_args()
    report=audit(args.shell)
    text=json.dumps(report,indent=2)+"\n"
    if args.report:
        args.report.write_text(text,encoding="utf-8")
    print(text)
