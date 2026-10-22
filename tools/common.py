"""Local validation and ZIP helpers shared by the packaging tools."""
from pathlib import Path
import hashlib
import struct
import zipfile

GAME_SHA256 = "74208b2bc81882b80e8ba542a0905ca942a955ee0617569ff5a2adef4617325e"
TITLE_ID = "0004000000155A00"

def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()

def game_check(path):
    path = Path(path)
    if sha(path) != GAME_SHA256:
        raise ValueError("Unsupported input revision. See docs/GAME_FILES.zh-CN.md; no file was changed.")
    return GAME_SHA256

def macho(path, kind):
    data = Path(path).read_bytes()
    magic, cpu, _, filetype, count, size, _, _ = struct.unpack_from("<8I", data)
    if (magic, cpu, filetype) != (0xFEEDFACF, 0x100000C, kind):
        raise ValueError("Expected a physical-iOS ARM64 Mach-O of the documented type")
    cursor = 32
    platforms = []
    for _ in range(count):
        command, length = struct.unpack_from("<II", data, cursor)
        if length < 8 or cursor + length > 32 + size:
            raise ValueError("Malformed Mach-O command")
        if command == 0x32:
            platforms.append(struct.unpack_from("<I", data, cursor + 8)[0])
        if command == 0x19:
            initial = struct.unpack_from("<I", data, cursor + 60)[0]
            if initial & 2 and initial & 4:
                raise ValueError("Writable executable segment rejected")
        cursor += length
    if platforms != [2]:
        raise ValueError("Expected iOS device platform, not simulator or desktop")

def unzip(archive, destination):
    destination = Path(destination).resolve()
    with zipfile.ZipFile(archive) as z:
        if z.testzip() is not None:
            raise ValueError("Corrupted ZIP/IPA")
        for item in z.infolist():
            target = (destination / item.filename).resolve()
            if not target.is_relative_to(destination) or (item.external_attr >> 16) & 0o170000 == 0o120000:
                raise ValueError("Unsafe ZIP member")
        z.extractall(destination)

def zip_app(stage, output):
    stage, output = Path(stage), Path(output)
    with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED, compresslevel=4, allowZip64=True) as z:
        for p in sorted(stage.rglob("*")):
            if not p.is_file():
                continue
            name = p.relative_to(stage).as_posix()
            entry = zipfile.ZipInfo.from_file(p, name)
            executable = p.name in ("Rhythm3DS", "Guest", "MoltenVK")
            entry.create_system = 3
            entry.external_attr = (0o100755 if executable else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            with p.open("rb") as source, z.open(entry, "w", force_zip64=True) as target:
                import shutil
                shutil.copyfileobj(source, target, 1024 * 1024)
