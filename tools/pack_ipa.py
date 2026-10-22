"""Combine a public shell with private local inputs. Never uploads any file."""
from pathlib import Path
import argparse
import json
import plistlib
import shutil
import zipfile
from audit_shell import audit
from common import game_check, macho, sha, unzip, zip_app

def pack(shell, game, guest, font, output):
    shell,game,guest,font,output=map(lambda p:Path(p).resolve(),(shell,game,guest,font,output))
    if output.exists():
        raise ValueError("Use a new output directory; existing files are preserved")
    before=game_check(game)
    shell_audit=audit(shell)
    macho(guest/"Guest",6)
    provenance=json.loads((font/"font-provenance.json").read_text(encoding="utf-8"))
    if provenance["sha256"]!=sha(font/"NotoSansJP.ttf") or provenance["license"]!="SIL OFL 1.1":
        raise ValueError("Open font provenance mismatch")
    if "SIL OPEN FONT LICENSE" not in (font/"OFL.txt").read_text(encoding="utf-8"):
        raise ValueError("Missing open font license")
    output.mkdir(parents=True)
    stage=output/"stage"
    unzip(shell,stage)
    app=stage/"Payload/Rhythm3DS.app"
    # Personal signing will regenerate these after local assembly.
    signature=app/"_CodeSignature"
    if signature.exists():
        for p in signature.iterdir():
            if not p.is_file():
                raise ValueError("Unexpected nested signature directory")
            p.unlink()
        signature.rmdir()
    macho(app/"Rhythm3DS",2)
    macho(app/"Frameworks/MoltenVK.framework/MoltenVK",6)
    target=app/"Frameworks/Guest.framework"
    target.mkdir()
    for name in ("Guest","Info.plist"):
        shutil.copy2(guest/name,target/name)
    (app/"Game").mkdir()
    shutil.copy2(game,app/"Game/Program.cia")
    (app/"Fonts").mkdir()
    for name in ("NotoSansJP.ttf","OFL.txt","font-provenance.json"):
        shutil.copy2(font/name,app/"Fonts"/name)
    info=plistlib.loads((app/"Info.plist").read_bytes())
    ipa=output/"RhythmHeaven3DS-local.ipa"
    zip_app(stage,ipa)
    with zipfile.ZipFile(ipa) as z:
        if z.testzip() is not None:
            raise ValueError("Packaged IPA failed CRC check")
        with z.open("Payload/Rhythm3DS.app/Game/Program.cia") as f:
            import hashlib
            if hashlib.file_digest(f,"sha256").hexdigest()!=before:
                raise ValueError("Packaged game hash mismatch")
        for name in ("Rhythm3DS","Frameworks/Guest.framework/Guest","Frameworks/MoltenVK.framework/MoltenVK"):
            if (z.getinfo("Payload/Rhythm3DS.app/"+name).external_attr>>16)&0o111!=0o111:
                raise ValueError("Executable mode missing")
    if sha(game)!=before:
        raise ValueError("Original input changed unexpectedly")
    report=dict(ipa=ipa.name,sha256=sha(ipa),bytes=ipa.stat().st_size,input_sha256=before,guest_sha256=sha(guest/"Guest"),shell_sha256=shell_audit["sha256"],version=info["CFBundleShortVersionString"],build=info["CFBundleVersion"],game_uploaded=False,requires_personal_resigning=True,device_tested=False)
    (output/"local-build.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,indent=2))
    return ipa

if __name__ == "__main__":
    p=argparse.ArgumentParser()
    for name in ("shell","game","guest","font","output"):
        p.add_argument("--"+name,required=True,type=Path)
    args=p.parse_args()
    pack(args.shell,args.game,args.guest,args.font,args.output)
