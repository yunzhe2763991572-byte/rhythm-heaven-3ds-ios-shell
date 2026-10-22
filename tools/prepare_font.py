"""Download a pinned OFL font and produce the local static weight used by the host."""
from pathlib import Path
import argparse
import hashlib
import json
import urllib.request

COMMIT = "66a36c8c94b1a5d992ee4e7f392fccfe4945767c"
FONT_SHA = "c2f3b4d463500a2ddcd3849cded1fceeb9fd6d1c32e6cbecd568453ba50fc68f"

def prepare(folder):
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    base = "https://raw.githubusercontent.com/google/fonts/" + COMMIT + "/ofl/notosansjp/"
    original = folder / "NotoSansJP-variable.ttf"
    if not original.exists():
        urllib.request.urlretrieve(base + "NotoSansJP%5Bwght%5D.ttf", original)
    with original.open("rb") as f:
        if hashlib.file_digest(f,"sha256").hexdigest() != FONT_SHA:
            raise ValueError("Pinned open font SHA256 mismatch")
    license_file = folder / "OFL.txt"
    if not license_file.exists():
        urllib.request.urlretrieve(base + "OFL.txt", license_file)
    if "SIL OPEN FONT LICENSE" not in license_file.read_text(encoding="utf-8"):
        raise ValueError("Expected OFL license")
    font = instantiateVariableFont(TTFont(original), {"wght":500}, inplace=False)
    names = {1:"RH3DS Open JP",2:"Medium",4:"RH3DS Open JP Medium",6:"RH3DSOpenJP-Medium",16:"RH3DS Open JP",17:"Medium"}
    for record in font["name"].names:
        if record.nameID in names:
            record.string = names[record.nameID].encode(record.getEncoding())
    output = folder / "NotoSansJP.ttf"
    font.save(output)
    with output.open("rb") as f:
        sha = hashlib.file_digest(f,"sha256").hexdigest()
    report = dict(source="google/fonts",commit=COMMIT,license="SIL OFL 1.1",modified_name="RH3DS Open JP Medium",weight=500,sha256=sha)
    (folder / "font-provenance.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    return folder

if __name__ == "__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--output", type=Path, default=Path("build/open-font"))
    print(prepare(p.parse_args().output))
